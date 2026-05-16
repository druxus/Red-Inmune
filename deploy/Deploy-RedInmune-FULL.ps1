# ============================================================
#  Deploy-RedInmune-FULL.ps1
#  Automatización COMPLETA de La Red Inmune
#  Diego Bermudo
#

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

function Write-Step { param($m) Write-Host "`n[►] $m" -ForegroundColor Cyan }
function Write-OK   { param($m) Write-Host "    [✓] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    [!] $m" -ForegroundColor Yellow }
function Write-Fail { param($m) Write-Host "    [✗] $m" -ForegroundColor Red }
function Write-Wait { param($m) Write-Host "    [⏳] $m" -ForegroundColor Magenta }

function Wait-Resource {
    param([string]$Descripcion, [scriptblock]$Condicion, [int]$MaxSegundos = 600, [int]$Intervalo = 15)
    Write-Wait "$Descripcion"
    $elapsed = 0
    while ($elapsed -lt $MaxSegundos) {
        if (& $Condicion) { Write-OK "$Descripcion — listo."; return $true }
        Start-Sleep $Intervalo
        $elapsed += $Intervalo
        Write-Wait "  ...esperando ($elapsed s / $MaxSegundos s)"
    }
    Write-Fail "$Descripcion — timeout tras $MaxSegundos s"
    return $false
}

# ============================================================
#  CONFIGURACIÓN — RELLENA ESTOS VALORES
# ============================================================

$AWS_ACCESS_KEY_ID     = "YOUR_AWS_ACCESS_KEY_ID"
$AWS_SECRET_ACCESS_KEY = "YOUR_AWS_SECRET_ACCESS_KEY"
$AWS_SESSION_TOKEN     = "YOUR_AWS_SESSION_TOKEN"
$ALERT_EMAIL           = "your-email@example.com"
$RDS_PASSWORD          = "YOUR_RDS_PASSWORD"

# ============================================================
#  VALIDACIÓN
# ============================================================

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       La Red Inmune · Automated Deployment           ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan

$ok = $true
if ($AWS_ACCESS_KEY_ID     -eq "PEGA_TU_ACCESS_KEY_ID")     { Write-Fail "Falta AWS_ACCESS_KEY_ID";     $ok = $false }
if ($AWS_SECRET_ACCESS_KEY -eq "PEGA_TU_SECRET_ACCESS_KEY") { Write-Fail "Falta AWS_SECRET_ACCESS_KEY"; $ok = $false }
if ($AWS_SESSION_TOKEN     -eq "PEGA_TU_SESSION_TOKEN")      { Write-Fail "Falta AWS_SESSION_TOKEN";     $ok = $false }
if ($ALERT_EMAIL           -eq "PEGA_TU_EMAIL@ejemplo.com")  { Write-Fail "Falta ALERT_EMAIL";           $ok = $false }
if (-not $ok) { Write-Host "`nEdita el bloque CONFIGURACIÓN y vuelve a ejecutar." -ForegroundColor Red; exit 1 }
Write-OK "Configuración validada"

# ============================================================
#  PASO 1 — CREDENCIALES AWS
# ============================================================

Write-Step "1/14 · Configurando credenciales AWS..."

aws configure set aws_access_key_id     $AWS_ACCESS_KEY_ID
aws configure set aws_secret_access_key $AWS_SECRET_ACCESS_KEY
aws configure set aws_session_token     $AWS_SESSION_TOKEN
aws configure set region                us-east-1
aws configure set output                json

$identity = aws sts get-caller-identity --output json 2>$null | ConvertFrom-Json
if (-not $identity.Account) { Write-Fail "Credenciales inválidas."; exit 1 }
$ACCOUNT_ID = $identity.Account
Write-OK "Cuenta: $ACCOUNT_ID"
Write-OK "ARN:    $($identity.Arn)"

# ============================================================
#  PASO 2 — VPC
# ============================================================

Write-Step "2/14 · Creando VPC inmune-net-vpc..."

$VPC_ID = aws ec2 describe-vpcs --filters 'Name=tag:Name,Values=inmune-net-vpc' --query 'Vpcs[0].VpcId' --output text 2>$null
if ($VPC_ID -eq "None" -or $VPC_ID -eq "") {
    $VPC_ID = aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text
    aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=inmune-net-vpc
    aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
    aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
    Write-OK "VPC creada: $VPC_ID"
} else { Write-OK "VPC ya existe: $VPC_ID" }

# ============================================================
#  PASO 3 — SUBREDES
# ============================================================

Write-Step "3/14 · Creando subredes..."

function Get-OrCreate-Subnet {
    param([string]$Nombre, [string]$CIDR, [string]$AZ, [bool]$Publica)
    # Buscar primero por tag Name
    $id = aws ec2 describe-subnets --filters "Name=tag:Name,Values=$Nombre" "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].SubnetId' --output text 2>$null
    if ($id -eq "None" -or $id -eq "") {
        # Fallback: buscar por CIDR (por si existe sin tag correcto)
        $id = aws ec2 describe-subnets --filters "Name=cidrBlock,Values=$CIDR" "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].SubnetId' --output text 2>$null
    }
    if ($id -eq "None" -or $id -eq "") {
        $id = aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $CIDR --availability-zone $AZ --query 'Subnet.SubnetId' --output text
        Write-OK "Subred creada: $Nombre ($id)"
    } else { Write-OK "Subred ya existe: $Nombre ($id)" }
    # Tags siempre (idempotente)
    aws ec2 create-tags --resources $id --tags "Key=Name,Value=$Nombre" 2>$null | Out-Null
    if ($Publica) {
        aws ec2 modify-subnet-attribute --subnet-id $id --map-public-ip-on-launch
    } else {
        aws ec2 create-tags --resources $id --tags "Key=kubernetes.io/cluster/red-inmune,Value=shared" 2>$null | Out-Null
    }
    return $id
}

$SUB_PUB_1A = Get-OrCreate-Subnet "inmune-subnet-publica-1a" "10.0.1.0/24" "us-east-1a" $true
$SUB_PUB_1B = Get-OrCreate-Subnet "inmune-subnet-publica-1b" "10.0.3.0/24" "us-east-1b" $true
$SUB_APP_1A = Get-OrCreate-Subnet "inmune-subnet-app-1a"     "10.0.2.0/24" "us-east-1a" $false
$SUB_APP_1B = Get-OrCreate-Subnet "inmune-subnet-app-1b"     "10.0.4.0/24" "us-east-1b" $false

# ============================================================
#  PASO 4 — INTERNET GATEWAY
# ============================================================

Write-Step "4/14 · Creando Internet Gateway..."

$IGW_ID = aws ec2 describe-internet-gateways --filters 'Name=tag:Name,Values=inmune-igw' --query 'InternetGateways[0].InternetGatewayId' --output text 2>$null
if ($IGW_ID -eq "None" -or $IGW_ID -eq "") {
    $IGW_ID = aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text
    aws ec2 create-tags --resources $IGW_ID --tags Key=Name,Value=inmune-igw
    aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
    Write-OK "IGW creado: $IGW_ID"
} else {
    $attached = aws ec2 describe-internet-gateways --internet-gateway-ids $IGW_ID --query 'InternetGateways[0].Attachments[0].VpcId' --output text 2>$null
    if ($attached -ne $VPC_ID) { aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID 2>$null }
    Write-OK "IGW ya existe: $IGW_ID"
}

# ============================================================
#  PASO 5 — ELASTIC IP + NAT GATEWAY
# ============================================================

Write-Step "5/14 · Creando Elastic IP y NAT Gateway..."

$EIP_ALLOC = aws ec2 describe-addresses --filters 'Name=tag:Name,Values=inmune-eip' --query 'Addresses[0].AllocationId' --output text 2>$null
if ($EIP_ALLOC -eq "None" -or $EIP_ALLOC -eq "") {
    $eipResult = aws ec2 allocate-address --domain vpc --output json | ConvertFrom-Json
    $EIP_ALLOC = $eipResult.AllocationId
    aws ec2 create-tags --resources $EIP_ALLOC --tags Key=Name,Value=inmune-eip
    Write-OK "Elastic IP creada: $EIP_ALLOC"
} else { Write-OK "Elastic IP ya existe: $EIP_ALLOC" }

$NAT_ID = aws ec2 describe-nat-gateways --filter 'Name=tag:Name,Values=inmune-nat-gw' 'Name=state,Values=available,pending' --query 'NatGateways[0].NatGatewayId' --output text 2>$null
if ($NAT_ID -eq "None" -or $NAT_ID -eq "") {
    $NAT_ID = aws ec2 create-nat-gateway --subnet-id $SUB_PUB_1A --allocation-id $EIP_ALLOC --query 'NatGateway.NatGatewayId' --output text
    aws ec2 create-tags --resources $NAT_ID --tags Key=Name,Value=inmune-nat-gw
    Write-OK "NAT Gateway creado: $NAT_ID"
} else { Write-OK "NAT Gateway ya existe: $NAT_ID" }

Wait-Resource "NAT Gateway disponible" {
    (aws ec2 describe-nat-gateways --nat-gateway-ids $NAT_ID --query 'NatGateways[0].State' --output text 2>$null) -eq "available"
} -MaxSegundos 180 -Intervalo 15

# ============================================================
#  PASO 6 — TABLAS DE RUTAS
# ============================================================

Write-Step "6/14 · Configurando tablas de rutas..."

function Get-OrCreate-RouteTable {
    param([string]$Nombre)
    $id = aws ec2 describe-route-tables --filters "Name=tag:Name,Values=$Nombre" "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[0].RouteTableId' --output text 2>$null
    if ($id -eq "None" -or $id -eq "") {
        $id = aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text
        aws ec2 create-tags --resources $id --tags "Key=Name,Value=$Nombre"
        Write-OK "Route table creada: $Nombre ($id)"
    } else { Write-OK "Route table ya existe: $Nombre ($id)" }
    return $id
}

$RT_PUB  = Get-OrCreate-RouteTable "inmune-rt-publica"
$RT_PRIV = Get-OrCreate-RouteTable "inmune-rt-privada"

aws ec2 create-route --route-table-id $RT_PUB  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID 2>$null | Out-Null
aws ec2 create-route --route-table-id $RT_PRIV --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_ID 2>$null | Out-Null

foreach ($sub in @($SUB_PUB_1A, $SUB_PUB_1B)) { aws ec2 associate-route-table --route-table-id $RT_PUB  --subnet-id $sub 2>$null | Out-Null }
foreach ($sub in @($SUB_APP_1A, $SUB_APP_1B)) { aws ec2 associate-route-table --route-table-id $RT_PRIV --subnet-id $sub 2>$null | Out-Null }
Write-OK "Tablas de rutas configuradas."

# ============================================================
#  PASO 7 — CLUSTER EKS
# ============================================================

Write-Step "7/14 · Creando cluster EKS red-inmune (15-20 min)..."

$clusterStatus = aws eks describe-cluster --name red-inmune --query 'cluster.status' --output text 2>$null
if ($clusterStatus -eq "ACTIVE") {
    Write-OK "Cluster EKS ya existe y está ACTIVE."
} else {
    @"
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: red-inmune
  region: us-east-1
  version: "1.31"
iam:
  serviceRoleARN: arn:aws:iam::${ACCOUNT_ID}:role/LabRole
vpc:
  subnets:
    private:
      us-east-1a: { id: $SUB_APP_1A }
      us-east-1b: { id: $SUB_APP_1B }
    public:
      us-east-1a: { id: $SUB_PUB_1A }
      us-east-1b: { id: $SUB_PUB_1B }
managedNodeGroups:
  - name: inmune-workers
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 2
    maxSize: 4
    privateNetworking: true
    iam:
      instanceRoleARN: arn:aws:iam::${ACCOUNT_ID}:role/LabRole
"@ | Out-File -FilePath cluster.yaml -Encoding utf8
    Write-Wait "Ejecutando eksctl... 15-20 minutos, no cierres la ventana."
    eksctl create cluster -f cluster.yaml
    if ($LASTEXITCODE -ne 0) { Write-Fail "Error al crear el cluster EKS."; exit 1 }
}

aws eks update-kubeconfig --name red-inmune --region us-east-1
kubectl get nodes
if ($LASTEXITCODE -ne 0) { Write-Fail "No se puede conectar al cluster."; exit 1 }
Write-OK "Cluster EKS listo."

kubectl create namespace inmune-cuarentena --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace falco             --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring        --dry-run=client -o yaml | kubectl apply -f -
Write-OK "Namespaces creados."

# ============================================================
#  PASO 8 — SECURITY GROUPS PARA RDS (ACTUALIZADO)
# ============================================================

Write-Step "8/14 · Localizando Security Group de los nodos..."

# Buscamos el grupo que contenga el nombre base que aparece en tu foto
# Usamos comodines para ignorar los números finales que puedan cambiar
$NODE_SG = aws ec2 describe-security-groups `
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=eks-cluster-sg-red-inmune*" `
    --query 'SecurityGroups[0].GroupId' --output text 2>$null

# Verificación de seguridad
if ($NODE_SG -eq "None" -or $NODE_SG -eq "") {
    Write-Fail "No se encontró el SG de los nodos con el patrón eks-cluster-sg-red-inmune*"
    # Intento de rescate por descripción si el nombre falla
    $NODE_SG = aws ec2 describe-security-groups `
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=description,Values=*EKS*red-inmune*" `
        --query 'SecurityGroups[0].GroupId' --output text 2>$null
}

Write-OK "SG nodos identificado: $NODE_SG"

# --- Creación del SG para la base de datos ---
$RDS_SG = aws ec2 describe-security-groups `
    --filters "Name=tag:Name,Values=inmune-rds-sg" "Name=vpc-id,Values=$VPC_ID" `
    --query 'SecurityGroups[0].GroupId' --output text 2>$null

if ($RDS_SG -eq "None" -or $RDS_SG -eq "") {
    $RDS_SG = aws ec2 create-security-group `
        --group-name inmune-rds-sg `
        --description "SG para permitir trafico desde los nodos a RDS" `
        --vpc-id $VPC_ID `
        --query 'GroupId' --output text
    aws ec2 create-tags --resources $RDS_SG --tags Key=Name,Value=inmune-rds-sg
    
    # Autorizamos el tráfico desde el SG que encontramos arriba
    if ($NODE_SG -ne "None" -and $NODE_SG -ne "") {
        aws ec2 authorize-security-group-ingress --group-id $RDS_SG --protocol tcp --port 5432 --source-group $NODE_SG 2>$null | Out-Null
        Write-OK "Regla de entrada añadida: Nodos -> RDS (Puerto 5432)"
    }
} else { Write-OK "Security Group RDS ya existe: $RDS_SG" }


# ============================================================
#  PASO 9 — RDS SUBNET GROUP + INSTANCIA RDS
# ============================================================

Write-Step "9/14 · Creando RDS (Subnet Group + instancia PostgreSQL)..."

$sgroupExists = aws rds describe-db-subnet-groups --db-subnet-group-name inmune-rds-subnet-group --query 'DBSubnetGroups[0].DBSubnetGroupName' --output text 2>$null
if ($sgroupExists -ne "inmune-rds-subnet-group") {
    aws rds create-db-subnet-group `
        --db-subnet-group-name inmune-rds-subnet-group `
        --db-subnet-group-description "Subredes privadas para RDS inmune" `
        --subnet-ids $SUB_APP_1A $SUB_APP_1B | Out-Null
    Write-OK "DB Subnet Group creado."
} else { Write-OK "DB Subnet Group ya existe." }

$rdsStatus = aws rds describe-db-instances --db-instance-identifier inmune-postgres --query 'DBInstances[0].DBInstanceStatus' --output text 2>$null
if ($rdsStatus -eq "available") {
    Write-OK "RDS ya existe y está disponible."
    $RDS_ENDPOINT = aws rds describe-db-instances --db-instance-identifier inmune-postgres --query 'DBInstances[0].Endpoint.Address' --output text
} else {
    aws rds create-db-instance `
        --db-instance-identifier inmune-postgres `
        --db-instance-class db.t3.micro `
        --engine postgres `
        --engine-version 15 `
        --master-username inmune `
        --master-user-password $RDS_PASSWORD `
        --allocated-storage 20 `
        --storage-type gp2 `
        --db-name red_inmune `
        --vpc-security-group-ids $RDS_SG `
        --db-subnet-group-name inmune-rds-subnet-group `
        --no-publicly-accessible `
        --no-multi-az `
        --backup-retention-period 0 `
        --no-deletion-protection | Out-Null
    Write-OK "RDS lanzada. Esperando disponibilidad (5-10 min)..."
    Wait-Resource "RDS disponible" {
        (aws rds describe-db-instances --db-instance-identifier inmune-postgres --query 'DBInstances[0].DBInstanceStatus' --output text 2>$null) -eq "available"
    } -MaxSegundos 720 -Intervalo 20
    $RDS_ENDPOINT = aws rds describe-db-instances --db-instance-identifier inmune-postgres --query 'DBInstances[0].Endpoint.Address' --output text
}
Write-OK "RDS Endpoint: $RDS_ENDPOINT"

# ============================================================
#  PASO 10 — TABLA DE INCIDENTES EN RDS
# ============================================================

Write-Step "10/14 · Inicializando tabla de incidentes en RDS..."

kubectl run psql-init --image=postgres:15-alpine --restart=Never --rm -it -- `
    psql "host=$RDS_ENDPOINT user=inmune password=$RDS_PASSWORD dbname=red_inmune sslmode=require" -c `
    "CREATE TABLE IF NOT EXISTS incidentes (id SERIAL PRIMARY KEY, fecha TIMESTAMPTZ DEFAULT NOW(), regla TEXT NOT NULL, pod TEXT NOT NULL, namespace TEXT NOT NULL, detalles TEXT, estado TEXT DEFAULT 'Detectado');"
Write-OK "Tabla incidentes lista."

# ============================================================
#  PASO 11 — SNS + SECRETS MANAGER
# ============================================================

Write-Step "11/14 · Creando SNS Topic, suscripción y Secrets Manager..."

$SNS_ARN = aws sns list-topics --query "Topics[?contains(TopicArn,'inmune-security-alerts')].TopicArn | [0]" --output text 2>$null
if ($SNS_ARN -eq "None" -or $SNS_ARN -eq "") {
    $SNS_ARN = aws sns create-topic --name inmune-security-alerts --query 'TopicArn' --output text
    Write-OK "SNS Topic creado: $SNS_ARN"
} else { Write-OK "SNS Topic ya existe: $SNS_ARN" }

$subStatus = aws sns list-subscriptions-by-topic --topic-arn $SNS_ARN --query "Subscriptions[?Endpoint=='$ALERT_EMAIL'].SubscriptionArn | [0]" --output text 2>$null
if ($subStatus -eq "None" -or $subStatus -eq "") {
    aws sns subscribe --topic-arn $SNS_ARN --protocol email --notification-endpoint $ALERT_EMAIL | Out-Null
    Write-Warn "Suscripción email creada. CONFIRMA el email de AWS antes de los ataques."
} else { Write-OK "Suscripción email ya existe." }

$pgJson = "{`"dsn`": `"host=$RDS_ENDPOINT user=inmune password=$RDS_PASSWORD dbname=red_inmune`"}"
$secretPgExists = aws secretsmanager describe-secret --secret-id inmune/postgres --query 'Name' --output text 2>$null
if ($secretPgExists -ne "inmune/postgres") {
    aws secretsmanager create-secret --name inmune/postgres --secret-string $pgJson | Out-Null
    Write-OK "Secreto inmune/postgres creado."
} else {
    aws secretsmanager put-secret-value --secret-id inmune/postgres --secret-string $pgJson | Out-Null
    Write-OK "Secreto inmune/postgres actualizado."
}

$snsJson = "{`"topic_arn`": `"$SNS_ARN`"}"
$secretSnsExists = aws secretsmanager describe-secret --secret-id inmune/sns --query 'Name' --output text 2>$null
if ($secretSnsExists -ne "inmune/sns") {
    aws secretsmanager create-secret --name inmune/sns --secret-string $snsJson | Out-Null
    Write-OK "Secreto inmune/sns creado."
} else {
    aws secretsmanager put-secret-value --secret-id inmune/sns --secret-string $snsJson | Out-Null
    Write-OK "Secreto inmune/sns actualizado."
}

# ============================================================
#  PASO 12 — NGINX + HPA + METRICS SERVER + NETPOL + RBAC
# ============================================================

Write-Step "12/14 · Desplegando nginx, HPA, NetworkPolicies y RBAC..."

@"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-inmune
spec:
  replicas: 3
  selector:
    matchLabels: { app: nginx-inmune, tier: production }
  template:
    metadata:
      labels: { app: nginx-inmune, tier: production }
    spec:
      containers:
      - name: nginx
        image: nginx:1.25-alpine
        ports: [ {containerPort: 80} ]
        resources:
          requests: { cpu: 100m, memory: 128Mi }
          limits:   { cpu: 300m, memory: 256Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-inmune-svc
spec:
  selector: { app: nginx-inmune }
  ports: [ {port: 80, targetPort: 80} ]
  type: ClusterIP
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: nginx-inmune-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-inmune
  minReplicas: 3
  maxReplicas: 8
  metrics:
  - type: Resource
    resource:
      name: cpu
      target: { type: Utilization, averageUtilization: 70 }
"@ | Out-File -FilePath nginx.yaml -Encoding utf8
kubectl apply -f nginx.yaml
Write-OK "nginx-inmune + HPA aplicados."

kubectl delete deployment metrics-server -n kube-system --ignore-not-found 2>$null
kubectl delete service   metrics-server -n kube-system --ignore-not-found 2>$null
kubectl delete apiservice v1beta1.metrics.k8s.io       --ignore-not-found 2>$null
Start-Sleep 10
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP"}
]'
kubectl rollout status deployment metrics-server -n kube-system --timeout=120s
Write-OK "metrics-server listo."

@"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cuarentena-isolation
  namespace: inmune-cuarentena
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cuarentena-in-default
  namespace: default
spec:
  podSelector:
    matchLabels: { cuarentena: "true" }
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-production
  namespace: default
spec:
  podSelector:
    matchLabels: { tier: production }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector:
            matchLabels: { tier: production }
  egress:
    - to:
        - podSelector:
            matchLabels: { tier: production }
"@ | Out-File -FilePath netpol.yaml -Encoding utf8
kubectl apply -f netpol.yaml
Write-OK "NetworkPolicies aplicadas."

@"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: inmune-agente-sa
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: inmune-agente-role
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get","list","watch","create","update","patch","delete"]
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get","list","watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: inmune-agente-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: inmune-agente-role
subjects:
- kind: ServiceAccount
  name: inmune-agente-sa
  namespace: default
"@ | Out-File -FilePath rbac.yaml -Encoding utf8
kubectl apply -f rbac.yaml
Write-OK "RBAC aplicado."

# ============================================================
#  PASO 13 — INMUNE-AGENTE
# ============================================================

Write-Step "13/14 · Desplegando inmune-agente..."

$agentePy = @'
"""
inmune-agente.py - La Red Inmune (Versión Definitiva)
Diego Bermudo
"""

import json
import os
import subprocess
import tempfile
import threading
import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
from http.server import BaseHTTPRequestHandler, HTTPServer

import boto3
import psycopg2

# =========================================================
# CONFIGURACIÓN
# =========================================================

CUARENTENA_NS = 'inmune-cuarentena'
PRODUCTION_NS = 'default'
PORT          = 8080

# Solo estas reglas disparan acción
REGLAS_CRITICAS = {
    'Terminal shell in container',
    'Read sensitive file untrusted',
    'Netcat Remote Code Execution in Container',
    'Create Symlink Over Sensitive Files',
    'Search Private Keys or Passwords',
}

# Estas reglas se descartan en silencio — sin log, sin DB, sin cuarentena
REGLAS_IGNORADAS = {
    'Contact K8S API Server From Container',
}

EXCLUIDOS_NS  = {'kube-system', 'falco', 'monitoring'}
EXCLUIDOS_POD = {'inmune-agente'}

PG_DSN  = ''
SNS_ARN = ''

# Lock para evitar procesar el mismo pod dos veces en paralelo
_pods_en_proceso: set = set()
_lock_pods = threading.Lock()

# =========================================================
# LOGGING — solo lo que importa
# =========================================================

R  = '\033[0m'
B  = '\033[1m'
DM = '\033[2m'
RJ = '\033[91m'
AM = '\033[93m'
VD = '\033[92m'
AZ = '\033[94m'
MG = '\033[95m'
LN = '─' * 60

def _ts():
    return datetime.now(ZoneInfo('Europe/Madrid')).strftime('%H:%M:%S')

def log_ataque(regla, pod, ns):
    print(
        f'\n{LN}\n'
        f'{B}{RJ}  ATAQUE DETECTADO{R}\n'
        f'  {DM}Hora   {R}{_ts()}\n'
        f'  {DM}Regla  {R}{B}{regla}{R}\n'
        f'  {DM}Pod    {R}{pod}\n'
        f'  {DM}NS     {R}{ns}',
        flush=True
    )

def log_accion(msg):
    print(f'  {AM}▶ {msg}{R}', flush=True)

def log_ok(msg):
    print(f'  {VD}✔ {msg}{R}\n{LN}', flush=True)

def log_error(origen, msg):
    print(f'  {MG}✘ [{origen}] {msg}{R}', flush=True)

def log_info(msg):
    print(f'{DM}[{_ts()}] {msg}{R}', flush=True)

# =========================================================
# AWS SECRETS
# =========================================================

def leer_secreto(nombre):
    cliente = boto3.client('secretsmanager', region_name='us-east-1')
    secreto = cliente.get_secret_value(SecretId=nombre)
    return json.loads(secreto['SecretString'])

# =========================================================
# BASE DE DATOS
# =========================================================

def guardar_incidente(regla, pod, ns, detalles, estado):
    try:
        with psycopg2.connect(PG_DSN) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    'INSERT INTO incidentes '
                    '(regla, pod, namespace, detalles, estado) '
                    'VALUES (%s,%s,%s,%s,%s)',
                    (regla, pod, ns, detalles[:4000], estado)
                )
    except Exception as e:
        log_error('DB', str(e))

# =========================================================
# SNS
# =========================================================

def enviar_email(regla, pod, ns, estado):
    if not SNS_ARN:
        return
    try:
        boto3.client('sns', region_name='us-east-1').publish(
            TopicArn=SNS_ARN,
            Subject=f'[Red Inmune] {estado}: {regla[:60]}',
            Message=(
                f'Regla: {regla}\n'
                f'Pod: {pod}\n'
                f'Namespace: {ns}\n'
                f'Estado: {estado}\n'
                f'Fecha: {datetime.utcnow().isoformat()}'
            )
        )
    except Exception as e:
        log_error('SNS', str(e))

# =========================================================
# KUBECTL
# =========================================================

def kubectl(args):
    try:
        r = subprocess.run(
            ['kubectl'] + args,
            capture_output=True,
            text=True,
            timeout=30
        )
        return r.returncode == 0, r.stdout.strip()
    except Exception as e:
        log_error('KUBECTL', str(e))
        return False, ''

# =========================================================
# RESPUESTA AUTOMÁTICA
# =========================================================

def responder(datos):
    try:
        regla   = datos.get('rule', 'desconocida')
        campos  = datos.get('output_fields') or {}
        pod     = (campos.get('k8s.pod.name') or 'unknown').strip('"')
        ns      = (campos.get('k8s.ns.name')  or PRODUCTION_NS).strip('"')
        detalle = datos.get('output', '')

        # ── Filtros tempranos — silencio total ─────────────
        if regla in REGLAS_IGNORADAS:
            return
        if ns in EXCLUIDOS_NS or any(e in pod for e in EXCLUIDOS_POD):
            return
        if regla not in REGLAS_CRITICAS:
            return
        if pod == 'unknown':
            return

        # ── Deduplicación en memoria ───────────────────────
        # Evita doble procesamiento cuando Falco envía dos alertas
        # críticas distintas del mismo pod casi a la vez
        with _lock_pods:
            if pod in _pods_en_proceso:
                return
            _pods_en_proceso.add(pod)

        try:
            # ── Verificar cuarentena en cluster ───────────
            ok, label = kubectl([
                'get', 'pod', pod, '-n', ns,
                '-o', 'jsonpath={.metadata.labels.cuarentena}'
            ])
            if ok and label == 'true':
                return

            # ── Log de ataque ──────────────────────────────
            log_ataque(regla, pod, ns)

            # ── Aislamiento ────────────────────────────────
            log_accion(f'Aislando {pod}...')
            kubectl(['label', 'pod', pod, 'app-', 'tier-', '-n', ns, '--overwrite'])
            kubectl(['label', 'pod', pod, 'cuarentena=true', '-n', ns, '--overwrite'])

            # ── Clon forense ───────────────────────────────
            log_accion('Clonando pod para análisis forense...')
            ok, manifiesto = kubectl(['get', 'pod', pod, '-n', ns, '-o', 'json'])
            if ok:
                datos_pod = json.loads(manifiesto)
                meta      = datos_pod['metadata']

                for campo in (
                    'resourceVersion', 'uid', 'creationTimestamp',
                    'managedFields', 'ownerReferences', 'selfLink',
                    'finalizers', 'generation'
                ):
                    meta.pop(campo, None)

                datos_pod.pop('status', None)
                datos_pod['spec'].pop('nodeName', None)

                meta['namespace'] = CUARENTENA_NS
                meta['name']      = pod[:40] + '-cuarentena'
                meta['labels']    = {'cuarentena': 'true', 'origen': pod[:30]}

                with tempfile.NamedTemporaryFile(
                    mode='w', suffix='.json', delete=False, dir='/tmp'
                ) as f:
                    json.dump(datos_pod, f)
                    tmp = f.name

                kubectl(['apply', '-f', tmp, '-n', CUARENTENA_NS])
                os.unlink(tmp)

            # ── Persistencia y notificación ────────────────
            guardar_incidente(regla, pod, ns, detalle, 'En cuarentena')
            enviar_email(regla, pod, ns, 'En cuarentena')

            log_ok(f'Pod {pod} aislado · Notificación enviada')

        finally:
            # Liberar tras 10s para permitir re-alertas legítimas futuras
            def _liberar():
                time.sleep(10)
                with _lock_pods:
                    _pods_en_proceso.discard(pod)
            threading.Thread(target=_liberar, daemon=True).start()

    except Exception as e:
        log_error('RESPONDER', str(e))

# =========================================================
# HTTP SERVER
# =========================================================

class ManejadorAlertas(BaseHTTPRequestHandler):

    def log_message(self, *args):
        pass  # Sin logs HTTP

    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != '/alert':
            self.send_response(404)
            self.end_headers()
            return
        try:
            length  = int(self.headers.get('Content-Length', 0))
            raw     = self.rfile.read(length).decode('utf-8').strip()

            if not raw:
                self.send_response(400)
                self.end_headers()
                return

            payload = json.loads(raw.split('\n')[0])

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')

            threading.Thread(
                target=responder,
                args=(payload,),
                daemon=True
            ).start()

        except Exception as e:
            log_error('HTTP', str(e))
            self.send_response(500)
            self.end_headers()

# =========================================================
# MAIN
# =========================================================

if __name__ == '__main__':

    print(
        f'\n{B}{"━" * 60}{R}\n'
        f'{B}  RED INMUNE · Agente de Respuesta Automática{R}\n'
        f'{"━" * 60}',
        flush=True
    )

    log_info('Cargando secretos AWS...')
    try:
        secretos_db  = leer_secreto('inmune/postgres')
        secretos_sns = leer_secreto('inmune/sns')
        PG_DSN  = secretos_db['dsn']
        SNS_ARN = secretos_sns['topic_arn']
        log_info('Secretos cargados.')
    except Exception as e:
        log_error('FATAL', f'Error AWS: {e}')
        exit(1)

    log_info('Verificando base de datos...')
    conectado = False
    for i in range(5):
        try:
            psycopg2.connect(PG_DSN).close()
            conectado = True
            log_info('Base de datos OK.')
            break
        except Exception:
            log_info(f'Reintentando ({i + 1}/5)...')
            time.sleep(5)

    if not conectado:
        log_error('FATAL', 'No se pudo conectar a RDS.')
        exit(1)

    print(
        f'\n{B}{"━" * 60}{R}\n'
        f'  Escuchando en :{PORT} · Esperando alertas de Falco\n'
        f'{"━" * 60}\n',
        flush=True
    )

    HTTPServer.allow_reuse_address = True
    HTTPServer(('0.0.0.0', PORT), ManejadorAlertas).serve_forever()
'@

$agentePy | Out-File -FilePath inmune-agente.py -Encoding utf8
kubectl create configmap inmune-agente-code --from-file=inmune-agente.py -n default --dry-run=client -o yaml | kubectl apply -f -

@"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inmune-agente
spec:
  replicas: 1
  selector:
    matchLabels: { app: inmune-agente }
  template:
    metadata:
      labels: { app: inmune-agente }
    spec:
      serviceAccountName: inmune-agente-sa
      initContainers:
      - name: instalar-deps
        image: python:3.11-slim
        command: ["sh","-c"]
        args:
        - |
          pip install psycopg2-binary boto3 --target=/deps --quiet &&
          python -c "import urllib.request; urllib.request.urlretrieve('https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl','/deps/kubectl')" &&
          chmod +x /deps/kubectl && echo 'Deps OK'
        volumeMounts:
        - { name: deps, mountPath: /deps }
      containers:
      - name: agente
        image: python:3.11-slim
        command: ["python","/app/inmune-agente.py"]
        ports: [ {containerPort: 8080} ]
        env:
        - { name: PYTHONPATH,            value: /deps }
        - { name: PATH,                  value: /deps:/usr/local/bin:/usr/bin:/bin }
        - { name: PYTHONUNBUFFERED,      value: "1" }
        - { name: AWS_ACCESS_KEY_ID,     value: $AWS_ACCESS_KEY_ID }
        - { name: AWS_SECRET_ACCESS_KEY, value: $AWS_SECRET_ACCESS_KEY }
        - { name: AWS_SESSION_TOKEN,     value: $AWS_SESSION_TOKEN }
        volumeMounts:
        - { name: codigo, mountPath: /app }
        - { name: deps,   mountPath: /deps }
        resources:
          requests: { cpu: 100m, memory: 128Mi }
          limits:   { cpu: 300m, memory: 256Mi }
      volumes:
      - { name: codigo, configMap: { name: inmune-agente-code } }
      - { name: deps,   emptyDir: {} }
---
apiVersion: v1
kind: Service
metadata:
  name: inmune-agente-svc
spec:
  selector: { app: inmune-agente }
  ports: [ {port: 8080, targetPort: 8080} ]
  type: ClusterIP
"@ | Out-File -FilePath inmune-agente-deploy.yaml -Encoding utf8
kubectl apply -f inmune-agente-deploy.yaml
Write-Wait "Esperando arranque del agente (~2 min)..."
kubectl rollout status deployment inmune-agente --timeout=300s
Write-OK "inmune-agente listo."

# ============================================================
#  PASO 14 — GRAFANA + FALCO
# ============================================================

Write-Step "14/14 · Desplegando Grafana y Falco..."

# ── Grafana ──────────────────────────────────────────────────
@"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels: { app: grafana }
  template:
    metadata:
      labels: { app: grafana }
    spec:
      containers:
      - name: grafana
        image: grafana/grafana:10.4.0
        ports: [ {containerPort: 3000} ]
        env:
        - { name: GF_SECURITY_ADMIN_PASSWORD, value: YOUR_GRAFANA_PASSWORD }
        - { name: GF_AUTH_ANONYMOUS_ENABLED,  value: "true" }
        resources:
          requests: { cpu: 100m, memory: 128Mi }
          limits:   { cpu: 300m, memory: 256Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: grafana-svc
  namespace: monitoring
spec:
  selector: { app: grafana }
  ports: [ {port: 80, targetPort: 3000} ]
  type: LoadBalancer
"@ | Out-File -FilePath grafana.yaml -Encoding utf8
kubectl apply -f grafana.yaml
kubectl rollout status deployment grafana -n monitoring --timeout=120s
Write-OK "Grafana listo."

# ── Falco ────────────────────────────────────────────────────
#

$AGENTE_IP = kubectl get svc inmune-agente-svc -o jsonpath='{.spec.clusterIP}'

# ── Network Policy Controller (VPC CNI) ──────────────────────────────────────
# Necesario para que las NetworkPolicies de cuarentena sean efectivas en EKS.
# Sin esto, aws-node corre con --enable-network-policy=false y las policies
# no tienen efecto aunque estén aplicadas en el cluster.
Write-Wait "Habilitando Network Policy Controller en VPC CNI..."
aws eks update-addon `
    --cluster-name red-inmune `
    --addon-name vpc-cni `
    --configuration-values '{"enableNetworkPolicy": "true"}' `
    --region us-east-1 | Out-Null
Wait-Resource "Network Policy Controller activo" {
    $flag = kubectl describe daemonset aws-node -n kube-system 2>$null |
            Select-String "enable-network-policy=true"
    $null -ne $flag
} -MaxSegundos 120 -Intervalo 15
Write-OK "Network Policy Controller habilitado."

# ── Falco ─────────────────────────────────────────────────────────────────────
# ServiceAccount creado ANTES del helm install para evitar errores de arranque
kubectl create serviceaccount falco -n falco --dry-run=client -o yaml | kubectl apply -f -
Write-OK "ServiceAccount falco creado."

helm repo add falcosecurity https://falcosecurity.github.io/charts 2>$null
helm repo update 2>$null

helm upgrade --install falco falcosecurity/falco `
    --namespace falco `
    --version 4.0.0 `
    --set driver.kind=kmod `
    --set falco.json_output=true `
    --set falco.json_include_output_property=true `
    --set falco.priority=debug `
    --set "falco.http_output.enabled=true" `
    --set "falco.http_output.url=http://inmune-agente-svc.default.svc.cluster.local:8080/alert" `
    --set resources.requests.memory=64Mi `
    --set resources.limits.memory=256Mi `
    --set tty=true

Write-Wait "Esperando que Falco arranque (~3 min)..."
$falcoListo = Wait-Resource "Falco 2/2 Running en ambos nodos" {
    $running = kubectl get pods -n falco --no-headers 2>$null |
               Where-Object { $_ -match "2/2\s+Running" }
    $running.Count -ge 2
} -MaxSegundos 300 -Intervalo 20

if ($falcoListo) {
    Write-OK "Falco detectando syscalls y enviando alertas al agente."
} else {
    Write-Warn "Falco tardó más de lo esperado."
    Write-Warn "Comprueba con: kubectl get pods -n falco"
    Write-Warn "Logs:          kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=20"
}

# ============================================================
#  RESUMEN FINAL
# ============================================================

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║       ✓  INFRAESTRUCTURA 100% DESPLEGADA             ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`n--- RECURSOS CREADOS ---" -ForegroundColor Cyan
Write-Host "  VPC:          $VPC_ID"
Write-Host "  NAT GW:       $NAT_ID"
Write-Host "  RDS:          $RDS_ENDPOINT"
Write-Host "  SNS ARN:      $SNS_ARN"
Write-Host "  Agente IP:    $AGENTE_IP"

Write-Host ""
Write-Host "--- ESTADO KUBERNETES ---" -ForegroundColor Cyan
kubectl get pods -A --no-headers | Where-Object { $_ -notmatch "^kube-system" }

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║   LO QUE TÚ TIENES QUE HACER AHORA                  ║" -ForegroundColor Yellow
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. CONFIRMA el email de SNS en tu bandeja ($ALERT_EMAIL)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  2. ABRE GRAFANA:" -ForegroundColor Yellow
Write-Host "       kubectl get svc grafana-svc -n monitoring"
Write-Host "     (admin / YOUR_GRAFANA_PASSWORD)"
Write-Host ""
Write-Host "  3. DATASOURCE PostgreSQL en Grafana:" -ForegroundColor Yellow
Write-Host "       Host:     $RDS_ENDPOINT`:5432"
Write-Host "       Database: red_inmune  |  User: inmune  |  Password: $RDS_PASSWORD"
Write-Host "       SSL Mode: require     |  Version: 15"
Write-Host ""

@"
=== La Red Inmune — Datos del despliegue ===
Fecha:        $(Get-Date -Format 'yyyy-MM-dd HH:mm')
Account ID:   $ACCOUNT_ID
VPC ID:       $VPC_ID
NAT Gateway:  $NAT_ID
RDS Endpoint: $RDS_ENDPOINT
SNS ARN:      $SNS_ARN
Agente IP:    $AGENTE_IP
Grafana:      admin / YOUR_GRAFANA_PASSWORD
Email alertas: $ALERT_EMAIL

=== Datasource Grafana ===
Host:     ${RDS_ENDPOINT}:5432  |  Database: red_inmune
User:     inmune  |  Password: $RDS_PASSWORD
SSL:      require  |  Version: 15

=== Comandos útiles ===
Abrir Grafana:      kubectl get svc grafana-svc -n monitoring
Logs agente:        kubectl logs -l app=inmune-agente -c agente -f
Logs Falco:         kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco -f
Pods cuarentena:    kubectl get pods -n inmune-cuarentena -w
Lanzar ataques:     .\Atacar-RedInmune.ps1
"@ | Out-File -FilePath "red-inmune-info.txt" -Encoding utf8
Write-OK "Datos guardados en red-inmune-info.txt"

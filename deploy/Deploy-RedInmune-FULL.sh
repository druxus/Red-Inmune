#!/usr/bin/env bash
# ============================================================
#  Deploy-RedInmune-FULL.sh
#  Automatización COMPLETA de La Red Inmune
#  Diego Bermudo
#
#  Traducido de PowerShell a Bash (lógica idéntica).
#

set +e  # equivalente a $ErrorActionPreference = 'Continue'

# ── Colores / funciones de log ────────────────────────────────
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
RESET='\033[0m'

write_step() { echo -e "\n${CYAN}[►] $1${RESET}"; }
write_ok()   { echo -e "    ${GREEN}[✓] $1${RESET}"; }
write_warn() { echo -e "    ${YELLOW}[!] $1${RESET}"; }
write_fail() { echo -e "    ${RED}[✗] $1${RESET}"; }
write_wait() { echo -e "    ${MAGENTA}[⏳] $1${RESET}"; }

# Equivalente a Wait-Resource
wait_resource() {
    local descripcion="$1"
    local condicion="$2"      # string con el comando a evaluar
    local max_segundos="${3:-600}"
    local intervalo="${4:-15}"

    write_wait "$descripcion"
    local elapsed=0
    while [ "$elapsed" -lt "$max_segundos" ]; do
        if eval "$condicion"; then
            write_ok "$descripcion — listo."
            return 0
        fi
        sleep "$intervalo"
        elapsed=$((elapsed + intervalo))
        write_wait "  ...esperando ($elapsed s / $max_segundos s)"
    done
    write_fail "$descripcion — timeout tras $max_segundos s"
    return 1
}

# ============================================================
#  CONFIGURACIÓN — RELLENA ESTOS VALORES
# ============================================================

AWS_ACCESS_KEY_ID="YOUR_AWS_ACCESS_KEY_ID"
AWS_SECRET_ACCESS_KEY="YOUR_AWS_SECRET_ACCESS_KEY"
AWS_SESSION_TOKEN="YOUR_AWS_SESSION_TOKEN"
ALERT_EMAIL="your-email@example.com"
RDS_PASSWORD="YOUR_RDS_PASSWORD"

# ============================================================
#  VALIDACIÓN
# ============================================================

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║       La Red Inmune · Automated Deployment           ║${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"

ok=true
[ "$AWS_ACCESS_KEY_ID"     = "PEGA_TU_ACCESS_KEY_ID"     ] && { write_fail "Falta AWS_ACCESS_KEY_ID";     ok=false; }
[ "$AWS_SECRET_ACCESS_KEY" = "PEGA_TU_SECRET_ACCESS_KEY" ] && { write_fail "Falta AWS_SECRET_ACCESS_KEY"; ok=false; }
[ "$AWS_SESSION_TOKEN"     = "PEGA_TU_SESSION_TOKEN"     ] && { write_fail "Falta AWS_SESSION_TOKEN";     ok=false; }
[ "$ALERT_EMAIL"           = "PEGA_TU_EMAIL@ejemplo.com" ] && { write_fail "Falta ALERT_EMAIL";           ok=false; }
if [ "$ok" = false ]; then
    echo -e "\n${RED}Edita el bloque CONFIGURACIÓN y vuelve a ejecutar.${RESET}"
    exit 1
fi
write_ok "Configuración validada"

# ============================================================
#  PASO 1 — CREDENCIALES AWS
# ============================================================

write_step "1/14 · Configurando credenciales AWS..."

aws configure set aws_access_key_id     "$AWS_ACCESS_KEY_ID"
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
aws configure set aws_session_token     "$AWS_SESSION_TOKEN"
aws configure set region                us-east-1
aws configure set output                json

identity_json=$(aws sts get-caller-identity --output json 2>/dev/null)
ACCOUNT_ID=$(echo "$identity_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Account',''))" 2>/dev/null)
ARN=$(echo "$identity_json"        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Arn',''))"     2>/dev/null)

if [ -z "$ACCOUNT_ID" ]; then
    write_fail "Credenciales inválidas."
    exit 1
fi
write_ok "Cuenta: $ACCOUNT_ID"
write_ok "ARN:    $ARN"

# ============================================================
#  PASO 2 — VPC
# ============================================================

write_step "2/14 · Creando VPC inmune-net-vpc..."

VPC_ID=$(aws ec2 describe-vpcs --filters 'Name=tag:Name,Values=inmune-net-vpc' \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
    aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value=inmune-net-vpc
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
    write_ok "VPC creada: $VPC_ID"
else
    write_ok "VPC ya existe: $VPC_ID"
fi

# ============================================================
#  PASO 3 — SUBREDES
# ============================================================

write_step "3/14 · Creando subredes..."

get_or_create_subnet() {
    local nombre="$1" cidr="$2" az="$3" publica="$4"
    local id
    id=$(aws ec2 describe-subnets \
        --filters "Name=tag:Name,Values=$nombre" "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    if [ "$id" = "None" ] || [ -z "$id" ]; then
        id=$(aws ec2 describe-subnets \
            --filters "Name=cidrBlock,Values=$cidr" "Name=vpc-id,Values=$VPC_ID" \
            --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    fi
    if [ "$id" = "None" ] || [ -z "$id" ]; then
        id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" \
            --availability-zone "$az" --query 'Subnet.SubnetId' --output text)
        write_ok "Subred creada: $nombre ($id)"
    else
        write_ok "Subred ya existe: $nombre ($id)"
    fi
    aws ec2 create-tags --resources "$id" --tags "Key=Name,Value=$nombre" 2>/dev/null
    if [ "$publica" = "true" ]; then
        aws ec2 modify-subnet-attribute --subnet-id "$id" --map-public-ip-on-launch
    else
        aws ec2 create-tags --resources "$id" \
            --tags "Key=kubernetes.io/cluster/red-inmune,Value=shared" 2>/dev/null
    fi
    echo "$id"
}

SUB_PUB_1A=$(get_or_create_subnet "inmune-subnet-publica-1a" "10.0.1.0/24" "us-east-1a" "true")
SUB_PUB_1B=$(get_or_create_subnet "inmune-subnet-publica-1b" "10.0.3.0/24" "us-east-1b" "true")
SUB_APP_1A=$(get_or_create_subnet "inmune-subnet-app-1a"     "10.0.2.0/24" "us-east-1a" "false")
SUB_APP_1B=$(get_or_create_subnet "inmune-subnet-app-1b"     "10.0.4.0/24" "us-east-1b" "false")

# ============================================================
#  PASO 4 — INTERNET GATEWAY
# ============================================================

write_step "4/14 · Creando Internet Gateway..."

IGW_ID=$(aws ec2 describe-internet-gateways \
    --filters 'Name=tag:Name,Values=inmune-igw' \
    --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)
if [ "$IGW_ID" = "None" ] || [ -z "$IGW_ID" ]; then
    IGW_ID=$(aws ec2 create-internet-gateway \
        --query 'InternetGateway.InternetGatewayId' --output text)
    aws ec2 create-tags --resources "$IGW_ID" --tags Key=Name,Value=inmune-igw
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
    write_ok "IGW creado: $IGW_ID"
else
    attached=$(aws ec2 describe-internet-gateways \
        --internet-gateway-ids "$IGW_ID" \
        --query 'InternetGateways[0].Attachments[0].VpcId' --output text 2>/dev/null)
    [ "$attached" != "$VPC_ID" ] && \
        aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null
    write_ok "IGW ya existe: $IGW_ID"
fi

# ============================================================
#  PASO 5 — ELASTIC IP + NAT GATEWAY
# ============================================================

write_step "5/14 · Creando Elastic IP y NAT Gateway..."

EIP_ALLOC=$(aws ec2 describe-addresses \
    --filters 'Name=tag:Name,Values=inmune-eip' \
    --query 'Addresses[0].AllocationId' --output text 2>/dev/null)
if [ "$EIP_ALLOC" = "None" ] || [ -z "$EIP_ALLOC" ]; then
    eip_json=$(aws ec2 allocate-address --domain vpc --output json)
    EIP_ALLOC=$(echo "$eip_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['AllocationId'])")
    aws ec2 create-tags --resources "$EIP_ALLOC" --tags Key=Name,Value=inmune-eip
    write_ok "Elastic IP creada: $EIP_ALLOC"
else
    write_ok "Elastic IP ya existe: $EIP_ALLOC"
fi

NAT_ID=$(aws ec2 describe-nat-gateways \
    --filter 'Name=tag:Name,Values=inmune-nat-gw' 'Name=state,Values=available,pending' \
    --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null)
if [ "$NAT_ID" = "None" ] || [ -z "$NAT_ID" ]; then
    NAT_ID=$(aws ec2 create-nat-gateway \
        --subnet-id "$SUB_PUB_1A" --allocation-id "$EIP_ALLOC" \
        --query 'NatGateway.NatGatewayId' --output text)
    aws ec2 create-tags --resources "$NAT_ID" --tags Key=Name,Value=inmune-nat-gw
    write_ok "NAT Gateway creado: $NAT_ID"
else
    write_ok "NAT Gateway ya existe: $NAT_ID"
fi

wait_resource "NAT Gateway disponible" \
    "[ \"\$(aws ec2 describe-nat-gateways --nat-gateway-ids '$NAT_ID' --query 'NatGateways[0].State' --output text 2>/dev/null)\" = 'available' ]" \
    180 15

# ============================================================
#  PASO 6 — TABLAS DE RUTAS
# ============================================================

write_step "6/14 · Configurando tablas de rutas..."

get_or_create_route_table() {
    local nombre="$1"
    local id
    id=$(aws ec2 describe-route-tables \
        --filters "Name=tag:Name,Values=$nombre" "Name=vpc-id,Values=$VPC_ID" \
        --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
    if [ "$id" = "None" ] || [ -z "$id" ]; then
        id=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
            --query 'RouteTable.RouteTableId' --output text)
        aws ec2 create-tags --resources "$id" --tags "Key=Name,Value=$nombre"
        write_ok "Route table creada: $nombre ($id)"
    else
        write_ok "Route table ya existe: $nombre ($id)"
    fi
    echo "$id"
}

RT_PUB=$(get_or_create_route_table "inmune-rt-publica")
RT_PRIV=$(get_or_create_route_table "inmune-rt-privada")

aws ec2 create-route --route-table-id "$RT_PUB"  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"   2>/dev/null
aws ec2 create-route --route-table-id "$RT_PRIV" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" 2>/dev/null

for sub in "$SUB_PUB_1A" "$SUB_PUB_1B"; do
    aws ec2 associate-route-table --route-table-id "$RT_PUB"  --subnet-id "$sub" 2>/dev/null
done
for sub in "$SUB_APP_1A" "$SUB_APP_1B"; do
    aws ec2 associate-route-table --route-table-id "$RT_PRIV" --subnet-id "$sub" 2>/dev/null
done
write_ok "Tablas de rutas configuradas."

# ============================================================
#  PASO 7 — CLUSTER EKS
# ============================================================

write_step "7/14 · Creando cluster EKS red-inmune (15-20 min)..."

cluster_status=$(aws eks describe-cluster --name red-inmune \
    --query 'cluster.status' --output text 2>/dev/null)
if [ "$cluster_status" = "ACTIVE" ]; then
    write_ok "Cluster EKS ya existe y está ACTIVE."
else
    cat > cluster.yaml <<EOF
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
EOF
    write_wait "Ejecutando eksctl... 15-20 minutos, no cierres la terminal."
    eksctl create cluster -f cluster.yaml
    if [ $? -ne 0 ]; then
        write_fail "Error al crear el cluster EKS."
        exit 1
    fi
fi

aws eks update-kubeconfig --name red-inmune --region us-east-1
kubectl get nodes
if [ $? -ne 0 ]; then
    write_fail "No se puede conectar al cluster."
    exit 1
fi
write_ok "Cluster EKS listo."

kubectl create namespace inmune-cuarentena --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace falco             --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring        --dry-run=client -o yaml | kubectl apply -f -
write_ok "Namespaces creados."

# ============================================================
#  PASO 8 — SECURITY GROUPS PARA RDS
# ============================================================

write_step "8/14 · Localizando Security Group de los nodos..."

NODE_SG=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=eks-cluster-sg-red-inmune*" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

if [ "$NODE_SG" = "None" ] || [ -z "$NODE_SG" ]; then
    write_fail "No se encontró el SG de los nodos con el patrón eks-cluster-sg-red-inmune*"
    NODE_SG=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=description,Values=*EKS*red-inmune*" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
fi

write_ok "SG nodos identificado: $NODE_SG"

RDS_SG=$(aws ec2 describe-security-groups \
    --filters "Name=tag:Name,Values=inmune-rds-sg" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

if [ "$RDS_SG" = "None" ] || [ -z "$RDS_SG" ]; then
    RDS_SG=$(aws ec2 create-security-group \
        --group-name inmune-rds-sg \
        --description "SG para permitir trafico desde los nodos a RDS" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' --output text)
    aws ec2 create-tags --resources "$RDS_SG" --tags Key=Name,Value=inmune-rds-sg
    if [ "$NODE_SG" != "None" ] && [ -n "$NODE_SG" ]; then
        aws ec2 authorize-security-group-ingress \
            --group-id "$RDS_SG" --protocol tcp --port 5432 \
            --source-group "$NODE_SG" 2>/dev/null
        write_ok "Regla de entrada añadida: Nodos -> RDS (Puerto 5432)"
    fi
else
    write_ok "Security Group RDS ya existe: $RDS_SG"
fi

# ============================================================
#  PASO 9 — RDS SUBNET GROUP + INSTANCIA RDS
# ============================================================

write_step "9/14 · Creando RDS (Subnet Group + instancia PostgreSQL)..."

sgroup_exists=$(aws rds describe-db-subnet-groups \
    --db-subnet-group-name inmune-rds-subnet-group \
    --query 'DBSubnetGroups[0].DBSubnetGroupName' --output text 2>/dev/null)
if [ "$sgroup_exists" != "inmune-rds-subnet-group" ]; then
    aws rds create-db-subnet-group \
        --db-subnet-group-name inmune-rds-subnet-group \
        --db-subnet-group-description "Subredes privadas para RDS inmune" \
        --subnet-ids "$SUB_APP_1A" "$SUB_APP_1B" > /dev/null
    write_ok "DB Subnet Group creado."
else
    write_ok "DB Subnet Group ya existe."
fi

rds_status=$(aws rds describe-db-instances \
    --db-instance-identifier inmune-postgres \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)
if [ "$rds_status" = "available" ]; then
    write_ok "RDS ya existe y está disponible."
    RDS_ENDPOINT=$(aws rds describe-db-instances \
        --db-instance-identifier inmune-postgres \
        --query 'DBInstances[0].Endpoint.Address' --output text)
else
    aws rds create-db-instance \
        --db-instance-identifier inmune-postgres \
        --db-instance-class db.t3.micro \
        --engine postgres \
        --engine-version 15 \
        --master-username inmune \
        --master-user-password "$RDS_PASSWORD" \
        --allocated-storage 20 \
        --storage-type gp2 \
        --db-name red_inmune \
        --vpc-security-group-ids "$RDS_SG" \
        --db-subnet-group-name inmune-rds-subnet-group \
        --no-publicly-accessible \
        --no-multi-az \
        --backup-retention-period 0 \
        --no-deletion-protection > /dev/null
    write_ok "RDS lanzada. Esperando disponibilidad (5-10 min)..."
    wait_resource "RDS disponible" \
        "[ \"\$(aws rds describe-db-instances --db-instance-identifier inmune-postgres --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)\" = 'available' ]" \
        720 20
    RDS_ENDPOINT=$(aws rds describe-db-instances \
        --db-instance-identifier inmune-postgres \
        --query 'DBInstances[0].Endpoint.Address' --output text)
fi
write_ok "RDS Endpoint: $RDS_ENDPOINT"

# ============================================================
#  PASO 10 — TABLA DE INCIDENTES EN RDS
# ============================================================

write_step "10/14 · Inicializando tabla de incidentes en RDS..."

kubectl run psql-init --image=postgres:15-alpine --restart=Never --rm -it -- \
    psql "host=$RDS_ENDPOINT user=inmune password=$RDS_PASSWORD dbname=red_inmune sslmode=require" -c \
    "CREATE TABLE IF NOT EXISTS incidentes (id SERIAL PRIMARY KEY, fecha TIMESTAMPTZ DEFAULT NOW(), regla TEXT NOT NULL, pod TEXT NOT NULL, namespace TEXT NOT NULL, detalles TEXT, estado TEXT DEFAULT 'Detectado');"
write_ok "Tabla incidentes lista."

# ============================================================
#  PASO 11 — SNS + SECRETS MANAGER
# ============================================================

write_step "11/14 · Creando SNS Topic, suscripción y Secrets Manager..."

SNS_ARN=$(aws sns list-topics \
    --query "Topics[?contains(TopicArn,'inmune-security-alerts')].TopicArn | [0]" \
    --output text 2>/dev/null)
if [ "$SNS_ARN" = "None" ] || [ -z "$SNS_ARN" ]; then
    SNS_ARN=$(aws sns create-topic --name inmune-security-alerts \
        --query 'TopicArn' --output text)
    write_ok "SNS Topic creado: $SNS_ARN"
else
    write_ok "SNS Topic ya existe: $SNS_ARN"
fi

sub_status=$(aws sns list-subscriptions-by-topic \
    --topic-arn "$SNS_ARN" \
    --query "Subscriptions[?Endpoint=='$ALERT_EMAIL'].SubscriptionArn | [0]" \
    --output text 2>/dev/null)
if [ "$sub_status" = "None" ] || [ -z "$sub_status" ]; then
    aws sns subscribe --topic-arn "$SNS_ARN" \
        --protocol email --notification-endpoint "$ALERT_EMAIL" > /dev/null
    write_warn "Suscripción email creada. CONFIRMA el email de AWS antes de los ataques."
else
    write_ok "Suscripción email ya existe."
fi

pg_json="{\"dsn\": \"host=$RDS_ENDPOINT user=inmune password=$RDS_PASSWORD dbname=red_inmune\"}"
secret_pg_exists=$(aws secretsmanager describe-secret --secret-id inmune/postgres \
    --query 'Name' --output text 2>/dev/null)
if [ "$secret_pg_exists" != "inmune/postgres" ]; then
    aws secretsmanager create-secret --name inmune/postgres \
        --secret-string "$pg_json" > /dev/null
    write_ok "Secreto inmune/postgres creado."
else
    aws secretsmanager put-secret-value --secret-id inmune/postgres \
        --secret-string "$pg_json" > /dev/null
    write_ok "Secreto inmune/postgres actualizado."
fi

sns_json="{\"topic_arn\": \"$SNS_ARN\"}"
secret_sns_exists=$(aws secretsmanager describe-secret --secret-id inmune/sns \
    --query 'Name' --output text 2>/dev/null)
if [ "$secret_sns_exists" != "inmune/sns" ]; then
    aws secretsmanager create-secret --name inmune/sns \
        --secret-string "$sns_json" > /dev/null
    write_ok "Secreto inmune/sns creado."
else
    aws secretsmanager put-secret-value --secret-id inmune/sns \
        --secret-string "$sns_json" > /dev/null
    write_ok "Secreto inmune/sns actualizado."
fi

# ============================================================
#  PASO 12 — NGINX + HPA + METRICS SERVER + NETPOL + RBAC
# ============================================================

write_step "12/14 · Desplegando nginx, HPA, NetworkPolicies y RBAC..."

cat > nginx.yaml <<'EOF'
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
EOF
kubectl apply -f nginx.yaml
write_ok "nginx-inmune + HPA aplicados."

kubectl delete deployment metrics-server -n kube-system --ignore-not-found 2>/dev/null
kubectl delete service   metrics-server -n kube-system --ignore-not-found 2>/dev/null
kubectl delete apiservice v1beta1.metrics.k8s.io       --ignore-not-found 2>/dev/null
sleep 10
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP"}
]'
kubectl rollout status deployment metrics-server -n kube-system --timeout=120s
write_ok "metrics-server listo."

cat > netpol.yaml <<'EOF'
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
EOF
kubectl apply -f netpol.yaml
write_ok "NetworkPolicies aplicadas."

cat > rbac.yaml <<'EOF'
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
EOF
kubectl apply -f rbac.yaml
write_ok "RBAC aplicado."

# ============================================================
#  PASO 13 — INMUNE-AGENTE
# ============================================================

write_step "13/14 · Desplegando inmune-agente..."

cat > inmune-agente.py <<'PYEOF'
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

REGLAS_CRITICAS = {
    'Terminal shell in container',
    'Read sensitive file untrusted',
    'Netcat Remote Code Execution in Container',
    'Create Symlink Over Sensitive Files',
    'Search Private Keys or Passwords',
}

REGLAS_IGNORADAS = {
    'Contact K8S API Server From Container',
}

EXCLUIDOS_NS  = {'kube-system', 'falco', 'monitoring'}
EXCLUIDOS_POD = {'inmune-agente'}

PG_DSN  = ''
SNS_ARN = ''

_pods_en_proceso: set = set()
_lock_pods = threading.Lock()

# =========================================================
# LOGGING
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

        if regla in REGLAS_IGNORADAS:
            return
        if ns in EXCLUIDOS_NS or any(e in pod for e in EXCLUIDOS_POD):
            return
        if regla not in REGLAS_CRITICAS:
            return
        if pod == 'unknown':
            return

        with _lock_pods:
            if pod in _pods_en_proceso:
                return
            _pods_en_proceso.add(pod)

        try:
            ok, label = kubectl([
                'get', 'pod', pod, '-n', ns,
                '-o', 'jsonpath={.metadata.labels.cuarentena}'
            ])
            if ok and label == 'true':
                return

            log_ataque(regla, pod, ns)

            log_accion(f'Aislando {pod}...')
            kubectl(['label', 'pod', pod, 'app-', 'tier-', '-n', ns, '--overwrite'])
            kubectl(['label', 'pod', pod, 'cuarentena=true', '-n', ns, '--overwrite'])

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

            guardar_incidente(regla, pod, ns, detalle, 'En cuarentena')
            enviar_email(regla, pod, ns, 'En cuarentena')

            log_ok(f'Pod {pod} aislado · Notificación enviada')

        finally:
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
        pass

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
PYEOF

kubectl create configmap inmune-agente-code --from-file=inmune-agente.py -n default \
    --dry-run=client -o yaml | kubectl apply -f -

cat > inmune-agente-deploy.yaml <<EOF
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
EOF
kubectl apply -f inmune-agente-deploy.yaml
write_wait "Esperando arranque del agente (~2 min)..."
kubectl rollout status deployment inmune-agente --timeout=300s
write_ok "inmune-agente listo."

# ============================================================
#  PASO 14 — GRAFANA + FALCO
# ============================================================

write_step "14/14 · Desplegando Grafana y Falco..."

# ── Grafana ───────────────────────────────────────────────────
cat > grafana.yaml <<'EOF'
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
EOF
kubectl apply -f grafana.yaml
kubectl rollout status deployment grafana -n monitoring --timeout=120s
write_ok "Grafana listo."

# ── Falco ───────────────────────────────────────────────────
AGENTE_IP=$(kubectl get svc inmune-agente-svc -o jsonpath='{.spec.clusterIP}')

write_wait "Habilitando Network Policy Controller en VPC CNI..."
aws eks update-addon \
    --cluster-name red-inmune \
    --addon-name vpc-cni \
    --configuration-values '{"enableNetworkPolicy": "true"}' \
    --region us-east-1 > /dev/null

wait_resource "Network Policy Controller activo" \
    "kubectl describe daemonset aws-node -n kube-system 2>/dev/null | grep -q 'enable-network-policy=true'" \
    120 15
write_ok "Network Policy Controller habilitado."

kubectl create serviceaccount falco -n falco --dry-run=client -o yaml | kubectl apply -f -
write_ok "ServiceAccount falco creado."

helm repo add falcosecurity https://falcosecurity.github.io/charts 2>/dev/null
helm repo update 2>/dev/null

helm upgrade --install falco falcosecurity/falco \
    --namespace falco \
    --version 4.0.0 \
    --set driver.kind=kmod \
    --set falco.json_output=true \
    --set falco.json_include_output_property=true \
    --set falco.priority=debug \
    --set "falco.http_output.enabled=true" \
    --set "falco.http_output.url=http://inmune-agente-svc.default.svc.cluster.local:8080/alert" \
    --set resources.requests.memory=64Mi \
    --set resources.limits.memory=256Mi \
    --set tty=true

write_wait "Esperando que Falco arranque (~3 min)..."
falco_listo=false
wait_resource "Falco 2/2 Running en ambos nodos" \
    "[ \"\$(kubectl get pods -n falco --no-headers 2>/dev/null | grep -c '2/2.*Running')\" -ge 2 ]" \
    300 20 && falco_listo=true

if [ "$falco_listo" = true ]; then
    write_ok "Falco detectando syscalls y enviando alertas al agente."
else
    write_warn "Falco tardó más de lo esperado."
    write_warn "Comprueba con: kubectl get pods -n falco"
    write_warn "Logs:          kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=20"
fi

# ============================================================
#  RESUMEN FINAL
# ============================================================

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║       ✓  INFRAESTRUCTURA 100% DESPLEGADA             ║${RESET}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${RESET}"

echo -e "\n${CYAN}--- RECURSOS CREADOS ---${RESET}"
echo "  VPC:          $VPC_ID"
echo "  NAT GW:       $NAT_ID"
echo "  RDS:          $RDS_ENDPOINT"
echo "  SNS ARN:      $SNS_ARN"
echo "  Agente IP:    $AGENTE_IP"

echo ""
echo -e "${CYAN}--- ESTADO KUBERNETES ---${RESET}"
kubectl get pods -A --no-headers | grep -v "^kube-system"

echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${YELLOW}║   LO QUE TÚ TIENES QUE HACER AHORA                  ║${RESET}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${YELLOW}1. CONFIRMA el email de SNS en tu bandeja ($ALERT_EMAIL)${RESET}"
echo ""
echo -e "  ${YELLOW}2. ABRE GRAFANA:${RESET}"
echo "       kubectl get svc grafana-svc -n monitoring"
echo "     (admin / YOUR_GRAFANA_PASSWORD)"
echo ""
echo -e "  ${YELLOW}3. DATASOURCE PostgreSQL en Grafana:${RESET}"
echo "       Host:     ${RDS_ENDPOINT}:5432"
echo "       Database: red_inmune  |  User: inmune  |  Password: $RDS_PASSWORD"
echo "       SSL Mode: require     |  Version: 15"
echo ""

cat > red-inmune-info.txt <<EOF
=== La Red Inmune — Datos del despliegue ===
Fecha:        $(date '+%Y-%m-%d %H:%M')
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
Lanzar ataques:     ./Atacar-RedInmune.sh
EOF
write_ok "Datos guardados en red-inmune-info.txt"

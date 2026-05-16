# Architecture

This document describes the design decisions and component interactions in Red Inmune.

---

## Network topology

The platform runs inside a dedicated VPC (`10.0.0.0/16`) split into four subnets across two availability zones:

| Subnet | CIDR | Type | AZ |
|---|---|---|---|
| `inmune-subnet-publica-1a` | `10.0.1.0/24` | Public | us-east-1a |
| `inmune-subnet-publica-1b` | `10.0.3.0/24` | Public | us-east-1b |
| `inmune-subnet-app-1a` | `10.0.2.0/24` | Private | us-east-1a |
| `inmune-subnet-app-1b` | `10.0.4.0/24` | Private | us-east-1b |

All EKS nodes run in the **private** subnets. Outbound internet access goes through a NAT Gateway in the public subnet. There is no direct inbound access to any node.

---

## EKS cluster

- **Version:** Kubernetes 1.31
- **Node group:** `inmune-workers` — 2×`t3.medium`, private networking, autoscales to 4
- **CNI:** AWS VPC CNI with **NetworkPolicy Controller enabled** (`enableNetworkPolicy: true`)

The NetworkPolicy Controller is required for quarantine to actually block traffic. Without it, `NetworkPolicy` objects are accepted by the API server but have no effect.

---

## Falco

Falco runs as a **DaemonSet** (one pod per node, kernel module driver). It is configured with:

```
json_output: true
json_include_output_property: true
priority: debug
http_output:
  enabled: true
  url: http://inmune-agente-svc.default.svc.cluster.local:8080/alert
```

> **Note on the `http_output` key name:** Falco renamed `httpOutput` to `http_output` in version 0.39. Using the old key silently fails — Falco starts but never sends HTTP alerts. Always use `http_output` with Falco 0.39+.

Falco's ServiceAccount must exist **before** `helm install` — otherwise the DaemonSet pods fail to start with a `serviceaccount not found` error.

---

## Response agent

`inmune-agente.py` is a single-file Python service with no framework dependencies beyond `boto3` and `psycopg2`. It runs inside the cluster as a `Deployment` (1 replica) with a dedicated `ServiceAccount` (`inmune-agente-sa`) bound to a `ClusterRole` that grants only the minimum required verbs on pods, namespaces and deployments.

### Alert processing pipeline

```
Falco HTTP POST /alert
        │
        ▼
  Parse JSON payload
        │
        ▼
  Early filters ──── ignored rule?  ──► discard silently
        │           excluded ns?    ──► discard silently
        │           unknown pod?    ──► discard silently
        │           not critical?   ──► discard silently
        ▼
  In-memory dedup ── pod already processing? ──► discard
        │
        ▼
  Check cluster ──── already quarantined? ──► discard
        │
        ▼
  Strip labels (app-, tier-)
        │
        ▼
  Apply cuarentena=true
        │
        ▼
  Clone pod → inmune-cuarentena ns
        │
        ▼
  INSERT into RDS incidentes table
        │
        ▼
  Publish SNS notification
        │
        ▼
  Release dedup lock (after 10s)
```

### In-memory deduplication

When an attack triggers multiple Falco rules in quick succession, the agent would process the same pod multiple times in parallel. The `_pods_en_proceso` set (protected by a `threading.Lock`) prevents this. The lock is released after 10 seconds to allow legitimate future re-alerts on the same pod.

### Forensic cloning

The agent fetches the full pod JSON, strips ephemeral metadata fields (`resourceVersion`, `uid`, `creationTimestamp`, `managedFields`, `ownerReferences`, `selfLink`, `finalizers`, `generation`), removes `status` and `nodeName`, renames it to `<original-name>-cuarentena`, and applies it to the `inmune-cuarentena` namespace. The resulting pod is subject to the `cuarentena-isolation` NetworkPolicy which denies all traffic.

---

## Secrets management

Credentials are never baked into images. The agent retrieves two secrets from AWS Secrets Manager at startup:

| Secret | Content |
|---|---|
| `inmune/postgres` | `{"dsn": "host=... user=... password=... dbname=..."}` |
| `inmune/sns` | `{"topic_arn": "arn:aws:sns:..."}` |

The Kubernetes deployment injects AWS credentials via environment variables. In a production environment these should be replaced with IAM Roles for Service Accounts (IRSA).

---

## Database schema

```sql
CREATE TABLE incidentes (
    id        SERIAL PRIMARY KEY,
    fecha     TIMESTAMPTZ DEFAULT NOW(),
    regla     TEXT NOT NULL,
    pod       TEXT NOT NULL,
    namespace TEXT NOT NULL,
    detalles  TEXT,
    estado    TEXT DEFAULT 'Detectado'
);
```

The RDS instance (`db.t3.micro`, PostgreSQL 15) runs in the private subnets and is not publicly accessible. SSL is enforced (`sslmode=require`).

---

## HPA and metrics

`nginx-inmune` is fronted by a `HorizontalPodAutoscaler` (min 3, max 8 replicas, 70% CPU target). The `metrics-server` is deployed and patched with `--kubelet-insecure-tls` and `--kubelet-preferred-address-types=InternalIP` to work correctly inside EKS private node groups.

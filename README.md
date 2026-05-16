<div align="center">

# 🛡️ Red Inmune

**Automated Kubernetes Security Response Platform**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-AWS%20EKS-orange.svg)](https://aws.amazon.com/eks/)
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.31-blue.svg)](https://kubernetes.io/)
[![Falco](https://img.shields.io/badge/falco-0.39%2B-teal.svg)](https://falco.org/)
[![Grafana](https://img.shields.io/badge/grafana-10.4-orange.svg)](https://grafana.com/)

*Red Inmune is a fully automated cloud-native security platform that detects, isolates and forensically preserves compromised Kubernetes pods in real time — using Falco, a custom Python response agent, PostgreSQL and Grafana.*

</div>

---

## 📋 Table of Contents

- [Overview](#-overview)
- [Architecture](#-architecture)
- [Features](#-features)
- [Tech Stack](#-tech-stack)
- [Project Structure](#-project-structure)
- [Getting Started](#-getting-started)
- [How It Works](#-how-it-works)
- [SOC Dashboard](#-soc-dashboard)
- [Configuration](#-configuration)
- [License](#-license)
- [Author](#-author)

---

## 🔍 Overview

Red Inmune automates the full incident response lifecycle on Kubernetes:

1. **Detect** — Falco monitors every syscall and fires structured JSON alerts for critical rules.
2. **Isolate** — The response agent strips network labels from the offending pod and applies a `cuarentena=true` label, which is picked up by NetworkPolicies blocking all ingress/egress.
3. **Preserve** — A forensic clone of the pod spec is deployed to an isolated namespace for offline analysis.
4. **Notify** — An email alert is sent via AWS SNS and the incident is persisted in PostgreSQL.
5. **Visualise** — A Grafana SOC dashboard gives real-time visibility over every incident.

All steps happen automatically — from attack detection to quarantine — in under 10 seconds.

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        AWS (us-east-1)                       │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    VPC (10.0.0.0/16)                  │  │
│  │                                                        │  │
│  │   Public Subnets          Private Subnets             │  │
│  │  ┌─────────────┐        ┌──────────────────────────┐  │  │
│  │  │  NAT Gateway│        │     EKS Cluster           │  │  │
│  │  │  (1a / 1b)  │        │   (red-inmune, v1.31)     │  │  │
│  │  └─────────────┘        │                           │  │  │
│  │                          │  ┌─────────┐ ┌────────┐  │  │  │
│  │                          │  │  Falco  │ │ nginx  │  │  │  │
│  │                          │  │DaemonSet│ │  HPA   │  │  │  │
│  │                          │  └────┬────┘ └────────┘  │  │  │
│  │                          │       │ alerts            │  │  │
│  │                          │  ┌────▼──────────────┐   │  │  │
│  │                          │  │   inmune-agente   │   │  │  │
│  │                          │  │  (Python / :8080) │   │  │  │
│  │                          │  └────┬──────────────┘   │  │  │
│  │                          │       │                   │  │  │
│  │                    ┌─────┘  ┌────▼──────┐           │  │  │
│  │                    │        │  Grafana  │           │  │  │
│  │                    │        │(monitoring│           │  │  │
│  │                    │        │    ns)    │           │  │  │
│  │                    │        └───────────┘           │  │  │
│  │                    └──────────────────────────────┘  │  │
│  │                                                        │  │
│  │  ┌─────────────────┐      ┌───────────────────────┐  │  │
│  │  │  RDS PostgreSQL  │      │   Secrets Manager     │  │  │
│  │  │ (inmune-postgres)│      │ inmune/postgres        │  │  │
│  │  └─────────────────┘      │ inmune/sns             │  │  │
│  │                            └───────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────┐                                          │
│  │  SNS Topic   │  → Email alerts                          │
│  └──────────────┘                                          │
└─────────────────────────────────────────────────────────────┘
```

**Kubernetes namespaces:**

| Namespace | Purpose |
|---|---|
| `default` | Production workloads + response agent |
| `inmune-cuarentena` | Forensic pod clones (fully isolated by NetworkPolicy) |
| `falco` | Falco DaemonSet |
| `monitoring` | Grafana |

---

## ✨ Features

- ⚡ **Sub-10-second response** from detection to network isolation
- 🔒 **NetworkPolicy quarantine** — zero ingress/egress for compromised pods
- 🧬 **Forensic cloning** — pod spec preserved in isolated namespace for analysis
- 📊 **Real-time SOC dashboard** — Grafana + PostgreSQL, auto-refreshes every 10s
- 📧 **Email alerting** via AWS SNS
- 🔁 **Fully idempotent deployment** — safe to re-run at any point
- 🛡️ **RBAC-scoped agent** — least-privilege ServiceAccount
- 🧠 **In-memory deduplication** — prevents double-processing the same pod

---

## 🛠️ Tech Stack

| Layer | Technology |
|---|---|
| Cloud | AWS (EKS, RDS PostgreSQL, SNS, Secrets Manager, VPC) |
| Container orchestration | Kubernetes 1.31 |
| Threat detection | Falco 0.39+ |
| Response agent | Python 3.11 (stdlib + boto3 + psycopg2) |
| Observability | Grafana 10.4 |
| Infrastructure-as-code | eksctl + bash/PowerShell |
| Networking | AWS VPC CNI with NetworkPolicy controller |

---

## 📁 Project Structure

```
red-inmune/
├── README.md
├── LICENSE
│
├── deploy/                         # Infrastructure deployment
│   ├── Deploy-RedInmune-FULL.sh    # Main deploy script (bash)
│   ├── Deploy-RedInmune-FULL.ps1   # Main deploy script (PowerShell)
│   └── Crear-Dashboard-SOC.sh      # Grafana dashboard import (bash)
│   └── Crear-Dashboard-SOC.ps1     # Grafana dashboard import (PowerShell)
│
├── agent/
│   └── inmune-agente.py            # Python response agent
│
├── docs/
│   ├── architecture.md             # Deep-dive architecture notes
│   ├── quickstart.md               # Step-by-step deployment guide
│   └── dashboard.md                # SOC dashboard reference
│
└── .github/
    └── ISSUE_TEMPLATE/
        └── bug_report.md
```

---

## 🚀 Getting Started

### Prerequisites

- AWS account with permissions to create EKS, RDS, SNS, VPC resources
- `aws cli` v2 configured
- `eksctl` installed
- `kubectl` installed
- `helm` v3 installed

### 1. Clone the repository

```bash
git clone https://github.com/your-username/red-inmune.git
cd red-inmune
```

### 2. Fill in your credentials

Open `deploy/Deploy-RedInmune-FULL.sh` and set the variables at the top:

```bash
AWS_ACCESS_KEY_ID="..."
AWS_SECRET_ACCESS_KEY="..."
AWS_SESSION_TOKEN="..."       # if using temporary credentials
ALERT_EMAIL="your@email.com"
RDS_PASSWORD="your-password"
```

### 3. Deploy the full stack

```bash
chmod +x deploy/Deploy-RedInmune-FULL.sh
./deploy/Deploy-RedInmune-FULL.sh
```

The script will provision all 14 steps end-to-end (~25 min, mostly waiting for EKS and RDS).

### 4. Import the SOC dashboard

Once Grafana is up, add a PostgreSQL datasource named `grafana-postgresql-datasource`, then:

```bash
chmod +x deploy/Crear-Dashboard-SOC.sh
./deploy/Crear-Dashboard-SOC.sh
```

> See [`docs/quickstart.md`](docs/quickstart.md) for the full step-by-step guide.

---

## ⚙️ How It Works

### Threat detection (Falco)

Falco runs as a DaemonSet and monitors kernel syscalls. It is configured to send JSON alerts over HTTP to the response agent for a curated set of critical rules:

| Rule | Trigger |
|---|---|
| `Terminal shell in container` | `exec` of bash/sh inside a running container |
| `Read sensitive file untrusted` | Access to `/etc/shadow`, `/etc/passwd`, etc. |
| `Netcat Remote Code Execution in Container` | Reverse shell via netcat |
| `Create Symlink Over Sensitive Files` | Symlink attacks on sensitive paths |
| `Search Private Keys or Passwords` | Credential harvesting attempts |

### Response agent (`inmune-agente.py`)

The agent is a lightweight Python HTTP server (`0.0.0.0:8080`) that:

1. Receives the Falco JSON alert on `POST /alert`
2. Filters out noise (ignored rules, system namespaces, already-quarantined pods)
3. Uses an in-memory lock set to deduplicate concurrent alerts for the same pod
4. Strips `app` and `tier` labels → the pod falls out of all Service selectors
5. Applies `cuarentena=true` → NetworkPolicy blocks all traffic
6. Clones the pod manifest into `inmune-cuarentena` namespace for forensics
7. Persists the incident to RDS and sends an SNS email notification

### NetworkPolicy quarantine

Two policies work together:

- `cuarentena-in-default` — denies all ingress/egress to pods with `cuarentena=true` in the default namespace
- `cuarentena-isolation` — denies all traffic inside `inmune-cuarentena` namespace

The VPC CNI Network Policy Controller must be enabled on EKS for these to take effect (the deploy script handles this automatically).

---

## 📊 SOC Dashboard

The Grafana dashboard provides real-time visibility across six panels:

| Panel | Type | Description |
|---|---|---|
| Incidentes Totales | Stat | Total incident count |
| En Cuarentena | Stat | Active quarantined pods |
| Actividad — Últimas 24h | Time series | Incident rate over time |
| Top 10 Reglas | Bar chart | Most triggered Falco rules |
| Distribución por Estado | Donut | Breakdown by incident status |
| Últimos Pods en Cuarentena | Table | Most recently quarantined pods |
| Registro de Incidentes | Table | Full incident log (last 100) |

Dashboard auto-refreshes every **10 seconds**.

---

## 🔧 Configuration

Key parameters in `Deploy-RedInmune-FULL.sh`:

| Variable | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `AWS_SESSION_TOKEN` | Session token (for temporary credentials) |
| `ALERT_EMAIL` | Email address for SNS incident notifications |
| `RDS_PASSWORD` | Master password for the PostgreSQL instance |

Agent behaviour is controlled by constants at the top of `agent/inmune-agente.py`:

| Constant | Description |
|---|---|
| `REGLAS_CRITICAS` | Set of Falco rules that trigger quarantine |
| `REGLAS_IGNORADAS` | Rules silently discarded (no DB, no alert) |
| `EXCLUIDOS_NS` | Namespaces the agent never acts on |
| `EXCLUIDOS_POD` | Pod name substrings excluded from quarantine |

---

## 📄 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

---

## 👤 Author

**Diego Bermudo**
- GitHub: [druxus](https://github.com/druxus)
- LinkedIn: [Diego Bermudo](www.linkedin.com/in/diego-bermudo-lópez-50992a258)

---

<div align="center">
<sub>Built with ☕ and too many <code>kubectl logs</code></sub>
</div>

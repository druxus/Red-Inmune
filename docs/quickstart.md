# Quickstart — Deploying Red Inmune

Estimated total time: **25–35 minutes** (most of it waiting for EKS and RDS to provision).

---

## Prerequisites

Make sure the following tools are installed and available in your `PATH`:

| Tool | Minimum version | Install guide |
|---|---|---|
| `aws` CLI | v2 | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| `eksctl` | 0.180+ | https://eksctl.io/installation/ |
| `kubectl` | 1.29+ | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | v3 | https://helm.sh/docs/intro/install/ |
| `python3` | 3.8+ | System package or https://python.org |

Your AWS account needs permissions for: `ec2:*`, `eks:*`, `rds:*`, `sns:*`, `secretsmanager:*`, `iam:PassRole`.

---

## Step 1 — Clone the repo

```bash
git clone https://github.com/your-username/red-inmune.git
cd red-inmune
```

---

## Step 2 — Set your credentials

Edit `deploy/Deploy-RedInmune-FULL.sh` and fill in the configuration block at the top:

```bash
AWS_ACCESS_KEY_ID="YOUR_ACCESS_KEY"
AWS_SECRET_ACCESS_KEY="YOUR_SECRET_KEY"
AWS_SESSION_TOKEN="YOUR_SESSION_TOKEN"   # leave empty if not using temporary creds
ALERT_EMAIL="you@example.com"
RDS_PASSWORD="choose-a-strong-password"
```

> ⚠️ Never commit real credentials to Git. Consider using environment variables or AWS Vault instead.

---

## Step 3 — Run the deploy script

```bash
chmod +x deploy/Deploy-RedInmune-FULL.sh
./deploy/Deploy-RedInmune-FULL.sh
```

The script runs 14 steps sequentially:

| Step | What it does | Approx. time |
|---|---|---|
| 1 | Configure AWS CLI credentials | < 1 min |
| 2 | Create VPC | < 1 min |
| 3 | Create subnets (4) | < 1 min |
| 4 | Create Internet Gateway | < 1 min |
| 5 | Create Elastic IP + NAT Gateway | ~2 min |
| 6 | Configure route tables | < 1 min |
| 7 | Create EKS cluster | **15–20 min** |
| 8 | Create RDS Security Group | < 1 min |
| 9 | Create RDS PostgreSQL instance | **5–10 min** |
| 10 | Initialise `incidentes` table | < 1 min |
| 11 | Create SNS topic + Secrets Manager | < 1 min |
| 12 | Deploy nginx + HPA + NetworkPolicies + RBAC | < 2 min |
| 13 | Deploy inmune-agente | ~2 min |
| 14 | Deploy Grafana + Falco | ~3 min |

When complete you will see a green summary banner and a `red-inmune-info.txt` file with all resource details.

---

## Step 4 — Confirm the SNS email subscription

Check your inbox for an email from AWS SNS with subject **"AWS Notification - Subscription Confirmation"** and click the confirmation link. Alerts will not be delivered until this is done.

---

## Step 5 — Get the Grafana URL

```bash
kubectl get svc grafana-svc -n monitoring
```

Copy the `EXTERNAL-IP` (may take a minute to appear). Open it in your browser.

- **Username:** `admin`
- **Password:** `YOUR_GRAFANA_PASSWORD`

---

## Step 6 — Add the PostgreSQL datasource

In Grafana:

1. Go to **Connections → Data sources → Add data source**
2. Choose **PostgreSQL**
3. Fill in:
   - **Name:** `grafana-postgresql-datasource`
   - **Host:** `<RDS_ENDPOINT>:5432`
   - **Database:** `red_inmune`
   - **User:** `inmune`
   - **Password:** your `RDS_PASSWORD`
   - **SSL Mode:** `require`
   - **PostgreSQL version:** `15`
4. Click **Save & test**

---

## Step 7 — Import the SOC dashboard

Edit `deploy/Crear-Dashboard-SOC.sh` and set `GRAFANA_URL` to your Grafana external IP, then:

```bash
chmod +x deploy/Crear-Dashboard-SOC.sh
./deploy/Crear-Dashboard-SOC.sh
```

The dashboard will open automatically in your browser (or navigate to the printed URL).

---

## Verifying the setup

```bash
# Check all pods are running
kubectl get pods -A

# Watch the agent logs live
kubectl logs -l app=inmune-agente -c agente -f

# Watch Falco logs
kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco -f

# Watch quarantine namespace
kubectl get pods -n inmune-cuarentena -w
```

---

## Cleanup

To avoid ongoing AWS charges, delete all resources when done:

```bash
# Delete EKS cluster (also removes node groups and associated resources)
eksctl delete cluster --name red-inmune --region us-east-1

# Delete RDS instance
aws rds delete-db-instance \
  --db-instance-identifier inmune-postgres \
  --skip-final-snapshot \
  --region us-east-1

# Delete NAT Gateway and release Elastic IP
# (get IDs from red-inmune-info.txt)
aws ec2 delete-nat-gateway --nat-gateway-id <NAT_ID>
aws ec2 release-address --allocation-id <EIP_ALLOC_ID>

# Delete SNS topic
aws sns delete-topic --topic-arn <SNS_ARN>

# Delete Secrets Manager secrets
aws secretsmanager delete-secret --secret-id inmune/postgres --force-delete-without-recovery
aws secretsmanager delete-secret --secret-id inmune/sns --force-delete-without-recovery
```

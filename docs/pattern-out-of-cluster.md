# Out-of-cluster pattern

Step-by-step walkthrough for the case where the workloads sending telemetry run **outside the cluster the gateway runs in**, using an ACM Private CA for TLS and a Route53 private zone for internal DNS.

This walkthrough provisions two EKS clusters in a shared VPC, because that gives a complete, runnable example. The pattern itself is broader: any sender that cannot use in-cluster Service DNS takes this path, including EC2 instances, ECS tasks, workloads in a peered VPC, and on-prem hosts. Only the sender-side steps change.

**Companion doc:** [`pattern-intra-cluster.md`](pattern-intra-cluster.md) covers the intra-cluster topology. See [`architecture.md`](architecture.md) for how the two compare.

---

## What this pattern gives you

- **Gateway cluster**: the cluster running the gateway. In this walkthrough Agent Control installs Flux, which manages the gateway for you and needs cluster-admin. Use the Fluxless module if you need namespace-scoped RBAC, or if you'd rather own the gateway's scaling and upgrades yourself.
- **Sender side**: in this walkthrough, a second EKS cluster in the same VPC. Substitute your own senders as needed.
- **Private-only**: no public DNS, no internet-facing load balancer. Gateway hostname resolves only inside your VPC.
- **Private CA**: TLS cert issued by AWS ACM Private CA. Apps in the apps-cluster mount the CA root as a K8s Secret to trust the gateway.
- **Out-of-cluster secret distribution**: Terraform writes the CA root to apps-cluster via a second `kubernetes` provider alias — no trust-manager, no manual secret copying.

Validated end to end: apps-cluster pod → VPC DNS → Route53 private zone → internal ALB (TLS via the Private CA) → gateway → New Relic.

---

## Architecture at a glance

```
┌────────────────────────── Shared VPC (10.0.0.0/16) ────────────────────────────┐
│                                                                                │
│  ┌─── pcg-cluster (EKS) ───┐        ┌─── apps-cluster (EKS) ───┐               │
│  │                         │        │                          │               │
│  │  ┌─────────────────┐    │        │  ┌────────────────┐      │               │
│  │  │  Agent Control  │    │        │  │  Sample App    │      │               │
│  │  │  (Flux mode)    │    │        │  │  Pod           │      │               │
│  │  └────────┬────────┘    │        │  │                │      │               │
│  │           │             │        │  │  Mounts:       │      │               │
│  │           ▼             │        │  │  pcg-ca-bundle │      │               │
│  │  ┌─────────────────┐    │        │  │  Secret        │      │               │
│  │  │     gateway     │◄───┼────────┼──┤                │      │               │
│  │  │  (Deployment)   │    │        │  └───────┬────────┘      │               │
│  │  └─────────────────┘    │        │          │               │               │
│  │           ▲             │        │          │ https://      │               │
│  │           │             │        │          │ pcg.internal. │               │
│  │  ┌────────┴────────┐    │        │          │ newrelic      │               │
│  │  │  Ingress "alb"  │◄───┼────────┼──────────┘               │               │
│  │  │  spec:          │    │        │                          │               │
│  │  │    tls: acm-arn │    │        │                          │               │
│  │  └────────┬────────┘    │        │                          │               │
│  │           │ managed by  │        │                          │               │
│  │           ▼             │        │                          │               │
│  │  ┌─────────────────┐    │        │                          │               │
│  │  │  ALB Controller │    │        │                          │               │
│  │  └────────┬────────┘    │        │                          │               │
│  └───────────┼─────────────┘        └──────────────────────────┘               │
│              │                                                                 │
│              ▼                                                                 │
│  ┌──────────────────────────────────────────────────────────────────────┐      │
│  │  Internal ALB (scheme = internal)                                    │      │
│  │  DNS: internal-k8s-newrelic-pcgalb-xxx.eu-west-1.elb.amazonaws.com   │      │
│  │  TLS cert: ACM ARN (imported from ACM Private CA)                    │      │
│  │  Route53 alias target of pcg.internal.newrelic                       │      │
│  └──────────────────────────────────────────────────────────────────────┘      │
│                                                                                │
│  ┌──────────────────────────────────────────────────────────────────────┐      │
│  │  Route53 private hosted zone: internal.newrelic                      │      │
│  │  A-record: pcg.internal.newrelic → alias(ALB)                        │      │
│  │  Associated with the shared VPC                                      │      │
│  └──────────────────────────────────────────────────────────────────────┘      │
│                                                                                │
└────────────────────────────────────────────────────────────────────────────────┘

┌─ AWS account, outside the VPC ───────────────────┐
│                                                  │
│  ACM Private CA ──► issues the server cert ──────┼──► imported into ACM
│  (self-signed root)                              │    (the ALB references
│                                                  │     it by ARN)
└──────────────────────────────────────────────────┘
```

The apps-cluster **does not need cert-manager**. It only needs the CA root Secret, which Terraform writes directly.

---

## The Terraform modules involved

Applied in this order:

| Step | Module | Purpose |
|---|---|---|
| 1 | `aws/1-vpc/` | Shared VPC with two clusters' worth of subnet tags |
| 2 | `aws/2-eks/` (×2 workspaces) | pcg-cluster + apps-cluster, both in shared VPC |
| 3 | `aws/3-ingress/alb/` (pcg-cluster workspace) | AWS Load Balancer Controller via Helm + IRSA |
| 4 | `aws/4-dns-tls/private/4.1-route53-private-zone/` | Private hosted zone `internal.newrelic` |
| 5 | `aws/4-dns-tls/private/4.2-out-of-cluster-tls/` | ACM Private CA + server cert + ACM import + 2 K8s Secrets (in 2 clusters) |
| 6 | `aws/5-pcg/flux/` | gateway install + ALB Ingress + Route53 A-record |
| 7 | Reproducible test script | 4 OTLP logs from apps-cluster; verify data in New Relic |

Intra-cluster users only apply steps 1–2 + `aws/4-dns-tls/cert-manager/4.1-installer/` + `aws/4-dns-tls/cert-manager/4.3-pcg-certificate/` + `aws/3-ingress/reverse-proxy-within-cluster/nginx/` + `aws/5-pcg/flux/` (with `create_alb_ingress = false`).

---

## Prerequisites

- **AWS account** with EKS, IAM role creation, ACM Private CA, and Route53 permissions
- **AWS CLI** configured (`aws sts get-caller-identity` should return your identity)
- **kubectl** installed
- **Terraform** >= 1.0
- **Helm** (for troubleshooting)
- A **New Relic ingest license key** — this walkthrough will show where you get it
- A **New Relic Pipeline Control fleet** — created via the New Relic UI

### Restricted-IAM accounts

Some AWS accounts don't grant `iam:CreateRole` to the default user role. If yours doesn't, assume a delegated provisioning role before applying, and set these env vars in every terminal you run Terraform from:

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::123456789012:role/resource-provisioner \
  --role-session-name $(date +%Y%m%d-%H%M%S) > response.json
export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId' response.json)
export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' response.json)
export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken' response.json)
```

STS credentials expire in ~1 hour. Re-run when you get `Unauthorized` or `ExpiredToken` errors.

### ⚠️ Cost warning

**ACM Private CA bills a flat monthly rate** whether it issues one certificate or ten thousand, plus a per-certificate issuance fee ([pricing](https://aws.amazon.com/private-ca/pricing/)). It is by far the most expensive component of this topology.

**Recommended workflow for validation:** apply → verify data flow → destroy same day. The full destroy sequence at the end of this guide takes about 30 minutes.

---

## Configuration file

You'll need two tfvars files at the repo root, both gitignored:

- `out-of-cluster-private-dns-pcg.tfvars` — gateway-side + out-of-cluster config
- `out-of-cluster-private-dns-apps.tfvars` — apps-side config

Start by copying the examples:

```bash
cp aws/out-of-cluster-private-dns-pcg.tfvars.example  aws/out-of-cluster-private-dns-pcg.tfvars
cp aws/out-of-cluster-private-dns-apps.tfvars.example aws/out-of-cluster-private-dns-apps.tfvars
```

Edit both files:
- Replace `Owner = "your-name"` with your name in the `tags` block
- Confirm the `aws_region` (default `eu-west-1`)
- If your account has no boundary policy, leave `permissions_boundary` empty
- `acm_certificate_arn` in `out-of-cluster-private-dns-pcg.tfvars` will be filled in AFTER step 5 completes — leave placeholder for now

---

## Step 1: VPC

All commands assume you start from the **repo root**. Return to root between steps.

```bash
cd aws/1-vpc
terraform init
terraform apply -var-file=../out-of-cluster-private-dns-pcg.tfvars
cd -   # back to repo root
```

**Applied once** (not per-cluster). The `shared_cluster_names = ["pcg-cluster", "apps-cluster"]` variable adds one `kubernetes.io/cluster/<name> = shared` tag per cluster to every subnet, so both clusters can discover the shared subnets.

**Expected:** 24 resources created (1 VPC, 6 subnets, 1 IGW, 3 NAT gateways, 3 EIPs, 4 route tables, 6 associations).

**Verify:**

```bash
aws ec2 describe-vpcs --region eu-west-1 \
  --filters "Name=tag:Name,Values=pcg-shared-vpc" \
  --query 'Vpcs[].VpcId' --output text
# vpc-xxxxxxxxx

aws ec2 describe-subnets --region eu-west-1 \
  --filters "Name=vpc-id,Values=vpc-xxxxxxxxx" \
  --query 'Subnets[?Tags[?Key==`kubernetes.io/role/internal-elb`]].[SubnetId,Tags[?starts_with(Key, `kubernetes.io/cluster/`)]]' \
  --output json
# Each private subnet should show both `kubernetes.io/cluster/pcg-cluster` and `kubernetes.io/cluster/apps-cluster`.
```

---

## Step 2: EKS clusters (two applies, one module)

Terraform workspaces isolate state between the two clusters.

### 2a. pcg-cluster

```bash
cd aws/2-eks
terraform init
terraform workspace new pcg-cluster
terraform workspace show   # Should print: pcg-cluster
terraform apply -var-file=../out-of-cluster-private-dns-pcg.tfvars
```

**Expected:** 12 resources (IAM roles, security group, EKS cluster, OIDC provider, launch template, node group). Takes ~15 minutes — control plane provisioning is the slow bit.

**Verify:**

```bash
aws eks update-kubeconfig --region eu-west-1 --name pcg-cluster
kubectl get nodes
# 2 nodes Ready
```

### 2b. apps-cluster

Still in `aws/2-eks/`. Switch to a new workspace. **State is separate** — the pcg-cluster state stays intact.

```bash
terraform workspace new apps-cluster
terraform workspace show   # Should print: apps-cluster
terraform apply -var-file=../out-of-cluster-private-dns-apps.tfvars
cd -   # back to repo root
```

Another ~15 minutes.

**Verify:**

```bash
aws eks update-kubeconfig --region eu-west-1 --name apps-cluster
kubectl config use-context arn:aws:eks:eu-west-1:<account>:cluster/apps-cluster
kubectl get nodes
# 2 nodes Ready

# Cross-check both clusters live in the same VPC
aws eks describe-cluster --region eu-west-1 --name pcg-cluster  --query 'cluster.resourcesVpcConfig.vpcId' --output text
aws eks describe-cluster --region eu-west-1 --name apps-cluster --query 'cluster.resourcesVpcConfig.vpcId' --output text
# Both should print the same VPC ID
```

### Save the kubectl context names

You'll use these repeatedly. Set them once:

```bash
export CTX_PCG=arn:aws:eks:eu-west-1:<account-id>:cluster/pcg-cluster
export CTX_APPS=arn:aws:eks:eu-west-1:<account-id>:cluster/apps-cluster
```

---

## Step 3: ALB Controller (on pcg-cluster only)

The controller runs on the cluster that hosts the Ingress it manages — here, `pcg-cluster` only. If you later add an ALB Ingress in apps-cluster, install the controller there separately (different workspace, same module).

```bash
cd aws/3-ingress/alb
terraform init
terraform workspace new pcg-cluster
terraform apply -var-file=../../out-of-cluster-private-dns-pcg.tfvars
cd -   # back to repo root
```

**Expected:** 5 resources (IAM policy, IAM role, policy attachment, ServiceAccount, Helm release). Takes ~2 minutes.

**Verify:**

```bash
kubectl --context $CTX_PCG get deploy -n kube-system aws-load-balancer-controller
# 2/2 replicas Ready

kubectl --context $CTX_PCG get ingressclass alb
# alb   ingress.k8s.aws/alb   <none>   ...
```

**Note on IAM permissions.** ALB Controller v2.6+ requires `DescribeListenerAttributes`, `ModifyListenerAttributes`, `DescribeTrustStores`, `DescribeCapacityReservation`, and `ModifyCapacityReservation`. Without them the controller reports `AccessDenied` part-way through reconciliation. The module's policy includes all five; if you substitute your own policy, carry them across.

---

## Step 4: Route53 private hosted zone

Creates the empty zone. DNS records get added in step 6 when the ALB exists.

```bash
cd aws/4-dns-tls/private/4.1-route53-private-zone
terraform init
terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars
cd -   # back to repo root
```

**Expected:** 1 resource. Takes ~5 seconds.

**Note the outputs:**

```
zone_id = "Z0EXAMPLE1234567"        <-- copy this for step 6
zone_name = "internal.newrelic"
example_pcg_hostname = "pcg.internal.newrelic"
```

Take the `zone_id` and paste it into `out-of-cluster-private-dns-pcg.tfvars` where `route53_zone_id` is set.

**Verify DNS is scoped to your VPC:**

> **What `kubectl run` does here:** creates a throwaway `busybox` pod inside the target cluster (`--context $CTX_PCG`), runs `nslookup` from *inside* that pod (which puts you inside the VPC), then deletes the pod (`--rm`). This tests whether DNS resolves from a pod inside the VPC, without needing SSH access to a node.

```bash
# Requires CTX_PCG to be set (from Step 2). Example:
#   export CTX_PCG=arn:aws:eks:eu-west-1:<account-id>:cluster/pcg-cluster

# From pcg-cluster (VPC-inside) — should succeed
kubectl --context $CTX_PCG run dnstest --rm -it --restart=Never --image=busybox -- \
  nslookup -type=SOA internal.newrelic
```

From outside the VPC, the same query returns NXDOMAIN — the zone is unresolvable.

---

## Step 5: Out-of-cluster TLS (⚠️ creates an ACM Private CA)

Creates the CA, issues the server cert, distributes trust to both clusters.

```bash
cd aws/4-dns-tls/private/4.2-out-of-cluster-tls
terraform init
terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars
cd -   # back to repo root
```

**Expected:** 9 resources — CA + activation dance (3), server private key + CSR + cert (3), namespace + 2 Secrets (3). Takes ~5-10 minutes (CA activation dominates).

**Note the outputs:**

```
acm_certificate_arn = "arn:aws:acm:eu-west-1:<account>:certificate/xxxxxxxx-..."   <-- copy this for step 6
ca_arn = "arn:aws:acm-pca:eu-west-1:<account>:certificate-authority/..."
pcg_tls_secret_ref = {name = "pcg-tls-secret", namespace = "newrelic"}
apps_ca_bundle_secret_ref = {name = "pcg-ca-bundle", namespace = "default"}
cost_reminder = "⚠ AWS Private CA bills a flat monthly rate whether idle or busy. Run 'terraform destroy' when not actively testing."
```

**Paste `acm_certificate_arn` into `out-of-cluster-private-dns-pcg.tfvars`** where `acm_certificate_arn = "REPLACE_..."` is set.

**Verify out-of-cluster trust chain:**

```bash
# Server cert in pcg-cluster with correct subject + issuer
kubectl --context $CTX_PCG get secret pcg-tls-secret -n newrelic \
  -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -ext subjectAltName
# subject=O=New Relic, CN=pcg.internal.newrelic
# issuer=CN=New Relic PCG Root CA, O=New Relic, C=US
# DNS:pcg.internal.newrelic

# CA bundle in apps-cluster
kubectl --context $CTX_APPS get secret pcg-ca-bundle -n default \
  -o jsonpath='{.data.ca\.crt}' | base64 -d \
  | openssl x509 -noout -subject
# subject=CN=New Relic PCG Root CA

# Out-of-cluster verify — THE critical proof
kubectl --context $CTX_PCG  get secret pcg-tls-secret -n newrelic -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/server.crt
kubectl --context $CTX_APPS get secret pcg-ca-bundle  -n default  -o jsonpath='{.data.ca\.crt}'  | base64 -d > /tmp/ca.crt
openssl verify -CAfile /tmp/ca.crt /tmp/server.crt
# /tmp/server.crt: OK
```

If that final `openssl verify` returns `OK`, apps in apps-cluster will trust the gateway's cert once the ALB comes up.

### About the two artifacts

- **K8s Secret `pcg-tls-secret`** — kept for informational parity with NGINX/Kong ingress controllers (which read TLS from Secrets). AWS ALB doesn't actually consume it.
- **ACM certificate ARN** — this is what the ALB Ingress references. AWS ALB requires certs to be in ACM (by ARN), not K8s Secrets.

Both are created by this module so downstream consumers have what they need regardless of ingress controller choice.

---

## Step 6: gateway install + ALB Ingress + Route53 record

Requires:
- Steps 1–5 complete
- `route53_zone_id` set in tfvars
- `acm_certificate_arn` set in tfvars
- Values file(s) downloaded from the New Relic install wizard (varies by install mode — see below)

### Choose your install mode: Flux or Fluxless

There are **two mutually exclusive modules** in `aws/5-pcg/`. Pick ONE.

| | `aws/5-pcg/flux/` | `aws/5-pcg/fluxless/` |
|---|---|---|
| **Helm charts installed** | 1 (`agent-control-bootstrap`) | 2 (`agent-control-deployment` + `pipeline-control-gateway`) |
| **New Relic install wizard shows** | Single `values.yaml` download | TWO `values.yaml` downloads |
| **In-cluster Flux operator?** | Yes (installed by Agent Control) | No |
| **RBAC required** | Cluster-admin | Namespace-scoped |
| **Replicas, CPU target, gateway version** | Managed for you from the New Relic UI | Yours, in `pcg-values.yaml` |
| **Which to pick** | You can grant cluster-admin, and want New Relic to manage the gateway's scaling and version | You need namespace-scoped RBAC, the gateway shares the cluster with other workloads, or your change process requires you to own gateway upgrades |
| **Out-of-cluster interface** | `create_alb_ingress`, `route53_zone_id`, `acm_certificate_arn`, `tls_secret_name`, `pcg_hostname`, `alb_scheme` | Identical to the Flux module |

**How to know which one the install wizard is giving you:**
- If the wizard's final page has ONE "Download values.yaml" button → **Flux mode** → use `aws/5-pcg/flux/` (skip to 6a).
- If the wizard shows TWO "Download values.yaml" buttons (one for `agent-control-deployment`, one for `pipeline-control-gateway`) → **Fluxless mode** → use `aws/5-pcg/fluxless/` (skip to 6c).

---

### 6a. (Flux mode) Get pcg-values.yaml from the New Relic UI

1. New Relic UI → **Pipeline Control** → **Add Gateway** / **Create Fleet**
2. Fleet name: something descriptive (e.g. `pcg-out-of-cluster-eu-west-1`)
3. Cluster name: `pcg-cluster`
4. Complete the wizard, download the single values.yaml
5. Save to `aws/5-pcg/flux/pcg-values.yaml` (this path is gitignored)

The file contains:
- `global.licenseKey` — your NR ingest license key
- `agentControlDeployment.chartValues.systemIdentity.parentIdentity.clientSecret` — 12h TTL, will need refresh if you take too long

### 6b. (Flux mode) Apply

```bash
cd aws/5-pcg/flux
terraform init
terraform apply -var-file=../../out-of-cluster-private-dns-pcg.tfvars
cd -   # back to repo root
```

**Expected:** 6 resources — Agent Control namespace, Helm release, wait for the gateway (180s), ALB Ingress, wait for ALB (120s), Route53 A-record. Takes ~8-10 minutes.

**If the apply fails with `data.kubernetes_ingress_v1.pcg_alb ... status ... is empty list`** — the ALB is still provisioning. Wait 60 seconds, re-run apply.  See "Known issues" below.

(Skip 6c/6d — they're the Fluxless alternative. Jump to "Note the outputs" below.)

---

### 6c. (Fluxless mode) Get both values.yaml files from the New Relic UI

1. New Relic UI → **Pipeline Control** → **Add Gateway** / **Create Fleet**
2. Fleet name: something descriptive (e.g. `pcg-out-of-cluster-eu-west-1`)
3. Cluster name: `pcg-cluster`
4. Complete the wizard, download **both** values.yaml files
5. Save them next to the module (both paths are gitignored):
   - Agent Control values → `aws/5-pcg/fluxless/agent-control-values.yaml`
   - The gateway values → `aws/5-pcg/fluxless/pcg-values.yaml`

**In your `out-of-cluster-private-dns-pcg.tfvars`**, set:
```hcl
# Only for Fluxless — where the two values files live
agent_control_values_file = "./agent-control-values.yaml"
pcg_values_file           = "./pcg-values.yaml"
```

### 6d. (Fluxless mode) Apply

```bash
cd aws/5-pcg/fluxless
terraform init
terraform apply -var-file=../../out-of-cluster-private-dns-pcg.tfvars
cd -   # back to repo root
```

**Expected:** 5 resources — namespace, agent-control-deployment Helm release, pipeline-control-gateway Helm release, wait for the gateway (180s), ALB Ingress, wait for ALB (120s), Route53 A-record. Takes ~8-10 minutes.

**Same ALB-timing caveat as 6b** — if it fails with `data.kubernetes_ingress_v1.pcg_alb ... status ... is empty list`, wait 60 seconds and re-run apply.

---

### Note the outputs (Flux OR Fluxless — same output names)

```
alb_hostname = "internal-k8s-newrelic-pcgalb-xxxxxxxx.eu-west-1.elb.amazonaws.com"
pcg_url = "https://pcg.internal.newrelic"
route53_record_fqdn = "pcg.internal.newrelic"
```

**Verify:**

```bash
# Gateway pods running
kubectl --context $CTX_PCG get pods -n newrelic
# pipeline-control-gateway-xxxxx-xxxxx  1/1  Running

# Ingress has an ADDRESS
kubectl --context $CTX_PCG get ingress -n newrelic pcg-alb
# NAME      CLASS   HOSTS                   ADDRESS                                  PORTS
# pcg-alb   alb     pcg.internal.newrelic   internal-k8s-newrelic-pcgalb-...         80,443

# Route53 record exists
aws route53 list-resource-record-sets \
  --hosted-zone-id <your-zone-id> \
  --query 'ResourceRecordSets[?Name==`pcg.internal.newrelic.`]'
# Returns one A-record with AliasTarget pointing to the ALB

# DNS resolves from apps-cluster
kubectl --context $CTX_APPS run dnstest --rm -it --restart=Never --image=busybox -- \
  nslookup pcg.internal.newrelic
# Returns 3 private IPs (one per AZ)
```

If DNS resolves and returns private IPs, the full chain from apps-cluster to the gateway works.

---

## Step 7: Send test data

Use the reproducible test script:

```bash
export NR_LICENSE_KEY=<your-ingest-key-from-pcg-values.yaml>
export CTX_APPS=arn:aws:eks:eu-west-1:<account>:cluster/apps-cluster

./aws/tests/send-inventory-logs-out-of-cluster.sh
```

The script:
1. Spawns a curl pod in apps-cluster with the CA bundle Secret mounted
2. POSTs 4 OTLP log records to `https://pcg.internal.newrelic/v1/logs`
3. Prints HTTP response codes for each
4. Deletes the pod

Expected output: 4 × `HTTP_CODE:200`.

**Verify data in New Relic** — wait ~1-2 minutes for the gateway to forward, then in the New Relic query builder:

```
FROM Log SELECT * WHERE testID = 'PCG-OUT-OF-CLUSTER-<timestamp>' SINCE 5 minutes ago
```

You should see 4 log records with the test attributes.

You can also verify:
- **Fleet Control** — New Relic UI → Pipeline Control → your fleet → should show `pcg-cluster` as Healthy
- **Log**: `FROM Log SELECT * WHERE service.name = 'inventory-service' SINCE 10 minutes ago` — 3 records
- **Log**: `FROM Log SELECT * WHERE service.name = 'infra-instant-delivery-service' SINCE 10 minutes ago` — 1 record

---

## Cleanup (destroy)

**⚠️ Priority order:** step 5's Private CA is the expensive resource. If you're rushed, destroy that first.

```bash
# Destroy in reverse-of-apply order. All commands start from repo root.

# Step 6: The gateway + Ingress + Route53 record
cd aws/5-pcg/flux
terraform destroy -var-file=../../out-of-cluster-private-dns-pcg.tfvars
cd -

# Step 5: Private CA + certs + Secrets (STOPS THE PRIVATE CA BILLING)
cd aws/4-dns-tls/private/4.2-out-of-cluster-tls
terraform destroy -var-file=../../../out-of-cluster-private-dns-pcg.tfvars
cd -

# Step 4: Route53 zone
cd aws/4-dns-tls/private/4.1-route53-private-zone
terraform destroy -var-file=../../../out-of-cluster-private-dns-pcg.tfvars
cd -

# Step 3: ALB Controller
cd aws/3-ingress/alb
terraform workspace select pcg-cluster
terraform destroy -var-file=../../out-of-cluster-private-dns-pcg.tfvars
cd -

# Step 2b: apps-cluster EKS
cd aws/2-eks
terraform workspace select apps-cluster
terraform destroy -var-file=../out-of-cluster-private-dns-apps.tfvars

# Step 2a: pcg-cluster EKS (still in aws/2-eks)
terraform workspace select pcg-cluster
terraform destroy -var-file=../out-of-cluster-private-dns-pcg.tfvars
cd -

# Step 1: VPC
cd aws/1-vpc
terraform destroy -var-file=../out-of-cluster-private-dns-pcg.tfvars
cd -
```

**Verify AWS is clean:**

```bash
aws eks list-clusters --region eu-west-1
# Empty

aws elbv2 describe-load-balancers --region eu-west-1
# Empty or unrelated

aws ec2 describe-vpcs --region eu-west-1 --filters "Name=is-default,Values=false"
# Empty (or only pre-existing non-project VPCs)

aws ec2 describe-addresses --region eu-west-1
# Empty (or only pre-existing non-project EIPs)
```

The ACM Private CA lingers in `PENDING_DELETION` state for 7 days (the AWS minimum) but stops billing immediately after `terraform destroy`.

---

## Coverage

Verified end to end:

- Two clusters in one VPC apply cleanly, and both clusters come up healthy
- Cross-cluster CA trust verified: `openssl verify` returns OK
- The ALB provisions as internal only, with no public IPs
- The Route53 private zone resolves from the apps cluster to the gateway hostname
- OTLP logs sent from the apps cluster reach New Relic through the full chain
- Fleet Control reports the gateway cluster healthy

Not exercised, though they run over the same infrastructure:

- **OTLP metrics and traces** — only logs were sent. The receivers and the network path are shared.
- **New Relic APM agent traffic** — needs an instrumented application workload rather than a raw OTLP client.
- **Pushing a filter rule from the New Relic UI** — a control-plane operation independent of this Terraform.
- **Bring-your-own Private CA (`private_ca_arn`)** — the variable is implemented but this path has not been run end to end.
- **The Kong layered variant** — this guide covers the direct ALB path. See the optional layered section in [`../aws/README.md`](../aws/README.md).

---

## Known issues

### 1. ALB Controller sometimes needs a second `terraform apply`

The `time_sleep.wait_for_alb` block in `aws/5-pcg/flux/main.tf` waits 120 seconds after Ingress creation. In real-world testing, ALB Controller sometimes takes longer (2-4 min for the first ALB in a fresh cluster). Symptom:

```
Error: Invalid index
  data.kubernetes_ingress_v1.pcg_alb[0].status[0].load_balancer[0].ingress is empty list
```

**Fix:** wait 60 seconds, re-run `terraform apply`. Terraform is idempotent — the second apply reads the now-populated Ingress status and creates the Route53 record.

If you hit this often, raise `alb_wait_duration` to `240s`.

### 2. ALB health check log spam

the gateway's port 80 (NR proprietary receiver) doesn't handle `GET /health`. It logs "unknown request at gateway urlpath=health" back-to-back for every ALB health check probe. Doesn't affect functionality — targets show as unhealthy in ALB console but traffic still routes because the Ingress rule matches the actual data paths.

The modules already set `alb.ingress.kubernetes.io/success-codes = "200,404"` so the ALB treats the gateway's 404 on the health-check path as healthy. The log lines are cosmetic.

### 3. Kubeconfig context accumulates orphans

Every `aws eks update-kubeconfig` adds a new context; it doesn't remove old ones. Clean up manually:

```bash
kubectl config get-contexts
kubectl config delete-context <name-of-destroyed-cluster>
kubectl config delete-cluster <name>
kubectl config delete-user <name>
```

### 4. Terraform state files across workspaces

Workspaces store state at `terraform.tfstate.d/<workspace>/terraform.tfstate`. If you accidentally run `terraform apply` in the `default` workspace, Terraform sees empty state and tries to create resources that already exist in AWS. Always `terraform workspace show` before applying.

---

## Reference

- **Architecture overview**: [`architecture.md`](architecture.md)
- **Companion guide** for the intra-cluster pattern: [`pattern-intra-cluster.md`](pattern-intra-cluster.md)
- **Step-by-step deployment commands**: [`../aws/README.md`](../aws/README.md)
- **Module-level READMEs** — every module has its own `README.md` with variables, outputs, troubleshooting

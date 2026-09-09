# Intra-cluster pattern — from zero AWS infra to data flowing

Complete, self-sufficient walkthrough. **Start here if you have no VPC, no EKS, nothing — just an AWS account.** End state: Pipeline Control gateway running inside your own EKS cluster, terminating TLS with cert-manager + NGINX, reachable at the Kubernetes Service DNS name `pcg-nginx.newrelic.svc.cluster.local`, and accepting telemetry from your apps.

You deploy **6 modules in order**. After each `terraform apply`, you run a couple of `kubectl` / `aws` commands to confirm it landed before moving on. If anything fails, stop and read the Troubleshooting section for that step — don't run the next one.

## Architecture (end state)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              EKS Cluster                                    │
│                                                                             │
│  ┌─────────────┐      ┌─────────────────┐      ┌─────────────────────────┐  │
│  │ App Pods    │      │  NGINX proxy    │      │ Gateway Pods            │  │
│  │ (NR Agents) │─────▶│ (TLS + gRPC)    │─────▶│ (pipeline-control-gw)   │  │
│  └─────────────┘      │ Port 80/443/4317│      │ Port 80/4317/4318/13133 │  │
│        │              └─────────────────┘      └─────────────────────────┘  │
│        │                      ▲                                             │
│        ▼                      │                                             │
│  ┌─────────────┐      ┌───────┴───────┐      ┌─────────────────────────┐    │
│  │ CoreDNS     │      │ Cert-Manager  │      │ Agent Control           │    │
│  │ (resolves   │      │ (self-signed  │      │ (deploys the gateway    │    │
│  │  internal)  │      │  TLS certs)   │      │  via Flux)              │    │
│  └─────────────┘      └───────────────┘      └─────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

## What you'll create, in order

| Step | Module | What gets created | Approx. time |
|---|---|---|---|
| 0 | (you) | AWS creds + 4 CLI tools + the shared `intra-cluster.tfvars` | 5 min |
| 1 | [`1-vpc`](../aws/1-vpc/) | VPC, 6 subnets, IGW, 3 NAT gateways, route tables | 2-3 min |
| 2 | [`2-eks`](../aws/2-eks/) | EKS control plane, OIDC provider, IAM roles, 2 EC2 worker nodes | 12-15 min |
| 3 | [`4.1-installer`](../aws/4-dns-tls/cert-manager/4.1-installer/) | cert-manager + self-signed internal CA + ClusterIssuer | 2-3 min |
| 4 | [`4.3-pcg-certificate`](../aws/4-dns-tls/cert-manager/4.3-pcg-certificate/) | TLS Certificate covering the NGINX and Kong Service DNS names + CA bundle Secret | 1-2 min |
| 5 | [`5-pcg/flux`](../aws/5-pcg/flux/) | Agent Control Helm install (deploys the gateway via Flux) | 3-5 min |
| 6 | [`reverse-proxy-within-cluster/nginx`](../aws/3-ingress/reverse-proxy-within-cluster/nginx/) | NGINX Deployment + Service (terminates TLS, proxies to the gateway via k8s Service DNS) | < 1 min |

**Total wall-clock: ~30 minutes.** Most of it is EKS provisioning (Step 2).

## The shared tfvars trick — set values ONCE

Instead of editing 6 separate `terraform.tfvars` files, this guide uses **one shared file**, `aws/intra-cluster.tfvars`. You fill in your cluster name + region + a few other values *once*, and pass that file to every `terraform` command via `-var-file`.

How it works: when Terraform sees a variable in your tfvars file that the current module doesn't declare, it **emits a warning and ignores it** (rather than erroring). So one file with all variables → each module picks up only what it needs → you never copy-paste a cluster name.

You'll see warnings like `Values for undeclared variables: 8 other variable(s)` on every apply. **That's expected and harmless.** It just means "this module didn't need those vars" — exactly what you want.

## Cost heads-up

If you tear down right after testing, this is inexpensive. If you leave it running, the ongoing charges are, roughly in order of size:

- **NAT gateways** — the largest line item, billed hourly per gateway plus data transfer. This guide creates one per AZ; drop to a single gateway in non-production if cost matters.
- **EKS control plane** — a fixed hourly charge per cluster.
- **Worker nodes** — whatever instance types you choose.
- **EBS volumes** — one root volume per node.

No load balancer, no private CA, and no public DNS zone are involved in this topology, which is what makes it the cheaper of the two. See [`cost-guidance.md`](cost-guidance.md) for the full breakdown, and the [AWS pricing calculator](https://calculator.aws/) for current rates.

**Always run Step 7 (Cleanup) when you're done testing** to stop the meter.

---

## Step 0 — Prerequisites & shared config

### 0.1 Install CLI tools (macOS shown)

```bash
brew install terraform awscli kubectl helm

terraform version
aws --version
kubectl version --client
helm version
```

### 0.2 Configure AWS credentials

You need creds with permission to create VPC + EKS + IAM resources. **Do not paste creds outside your terminal.**

```bash
# Either short-lived creds in this shell:
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."           # if using STS / SSO
export AWS_DEFAULT_REGION="us-west-1"

# Or a named profile:
# aws configure --profile pcg
# export AWS_PROFILE=pcg

# Confirm
aws sts get-caller-identity
```

### 0.3 Download the gateway values.yaml from New Relic

1. Open the New Relic UI → **Pipeline Control** → **Setup**
2. Follow the install wizard
3. Download the generated `values.yaml`
4. Save it somewhere you can find it — Step 5 references it

**Treat this file like a credential** (it contains your ingest license key).

### 0.4 Create your shared tfvars file

This is where you set your cluster name + region **once**.

```bash
# From the repo root
cp aws/intra-cluster.tfvars.example aws/intra-cluster.tfvars
$EDITOR aws/intra-cluster.tfvars
```

**Minimum changes:**

```hcl
cluster_name = "my-pcg-cluster"          # YOUR cluster name
aws_region   = "us-west-1"               # YOUR region

tags = {
  Owner   = "your-name"                  # YOUR name
  Purpose = "pipeline-control-gateway"
}
```

Everything else has sensible defaults. Read the comments in the file — every variable is explained. Notable optional ones:

- **`vpc_cidr`** — change only if `10.0.0.0/16` conflicts with another VPC you peer with
- **`node_groups`** — bump to `t3.large` or more nodes if you'll run apps alongside the gateway
- **`permissions_boundary`** — leave empty unless your AWS admin specifically requires one (most users don't, see the file's comments)

### 0.5 A note on the `-var-file` paths

Every module below is applied from its own directory, and each passes the same shared file via `-var-file`. Because the modules sit at different depths under `aws/`, the number of `../` segments differs per module — `../` from `aws/1-vpc`, `../../../` from `aws/4-dns-tls/cert-manager/4.1-installer`, and so on. Each command below already has the right depth, so copy them as written.

Every `cd` in this guide is written from the **repo root**. Return to the root between steps (`cd -` after each block, or open a fresh shell).

---

## Step 1 — VPC

**What it creates:** A new VPC with:
- 3 public subnets (one per AZ) — tagged for external load balancers
- 3 private subnets (one per AZ) — tagged for internal load balancers; EKS nodes run here
- 1 Internet Gateway
- 3 NAT gateways (one per AZ — for private subnet egress)
- Route tables wiring it all together
- All resources tagged `kubernetes.io/cluster/<cluster_name>=shared` so EKS auto-discovers them

**Why:** EKS needs subnets in multiple AZs. Private subnets keep worker nodes off the public internet; NAT gateways let those nodes still pull container images.

```bash
cd aws/1-vpc

terraform init
terraform plan  -var-file=../intra-cluster.tfvars
terraform apply -var-file=../intra-cluster.tfvars     # ~2-3 min, type 'yes' when prompted
```

**Verify:**

```bash
terraform output

VPC_ID=$(terraform output -raw vpc_id)
aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].{id:VpcId,cidr:CidrBlock,state:State}'

# Expect 3 private + 3 public subnets across 3 AZs
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{az:AvailabilityZone,cidr:CidrBlock,name:Tags[?Key==`Name`].Value|[0]}'
```

**Troubleshooting:**
- **`UnauthorizedOperation`** — your AWS creds lack `ec2:*`. Fix the creds.
- **CIDR conflict** — change `vpc_cidr` in `intra-cluster.tfvars` to a different /16, e.g. `10.42.0.0/16`.

---

## Step 2 — EKS cluster

**What it creates:**
- IAM role for the EKS control plane (with managed policies)
- IAM role for worker nodes (with managed policies)
- Security group for the cluster
- EKS cluster (control plane) — Kubernetes 1.31
- OIDC provider (for IRSA — IAM roles for service accounts)
- Launch template for nodes (encrypted EBS, proper tags)
- 1 managed node group with 2 × t3.medium nodes (auto-scales 1-4)

The module **auto-discovers** the VPC and private subnets from Step 1 by their `Name` tag — no IDs to copy.

**Why:** This is where the gateway and your apps will run.

### About `permissions_boundary`

This is an **optional** IAM guardrail — a policy that caps what the role can ever do. Most accounts don't need one. **Leave `permissions_boundary = ""` in the shared file unless:**

- Your AWS admin told you "all roles must have boundary X attached"
- You hit `AccessDenied: ... no permissions boundary was specified` when applying

If your org requires one, set the ARN in the shared tfvars:
```hcl
permissions_boundary = "arn:aws:iam::123456789012:policy/your-boundary"
```

### Deploy

```bash
cd aws/2-eks

terraform init
terraform plan  -var-file=../intra-cluster.tfvars
terraform apply -var-file=../intra-cluster.tfvars     # ~12-15 min, mostly EKS control plane
```

**Verify:**

```bash
terraform output

# Configure kubectl (the module also prints this exact command)
CLUSTER_NAME=$(terraform output -raw cluster_name)
REGION=$(terraform output -raw aws_region)
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

kubectl cluster-info
kubectl get nodes                       # 2 nodes, STATUS=Ready
kubectl get pods -n kube-system         # aws-node, coredns, kube-proxy all Running
```

If `kubectl get nodes` shows `NotReady`, wait 30s and retry — kubelet takes a moment to register after EC2 boots.

**Troubleshooting:**
- **`error: You must be logged in to the server (Unauthorized)`** — the AWS creds in your current shell aren't the ones that created the cluster. Either re-export the original creds or run `aws eks update-kubeconfig` with the right profile.
- **Nodes stuck `NotReady` for >5 min** — `kubectl describe node <name>`. Most common: NAT gateway broken (can't pull images). Re-check Step 1.
- **`AccessDenied` during IAM role creation** — see the `permissions_boundary` note above.

---

## Step 3 — cert-manager + internal CA

**What it does:** Installs cert-manager via Helm in the `cert-manager` namespace. Creates a self-signed bootstrap `ClusterIssuer`, uses that to mint a long-lived internal CA Certificate (10 years), then creates a CA-backed `ClusterIssuer` (`internal-ca-issuer`) that Step 4 uses to sign the gateway cert.

**Why:** No public domain → no public ACM/Let's Encrypt cert. A self-signed internal CA is the standard answer: the CA cert gets distributed to app pods so they trust the gateway.

```bash
cd aws/4-dns-tls/cert-manager/4.1-installer

terraform init
terraform plan  -var-file=../../../intra-cluster.tfvars
terraform apply -var-file=../../../intra-cluster.tfvars     # ~2-3 min
```

**Verify:**

```bash
# All 3 cert-manager pods Running (cert-manager, cainjector, webhook)
kubectl get pods -n cert-manager

# Both ClusterIssuers Ready=True
kubectl get clusterissuer

# The internal CA Certificate is Ready
kubectl get certificate -n cert-manager
kubectl get secret internal-ca-secret -n cert-manager

terraform output
```

**Troubleshooting:**
- **Webhook pod CrashLoopBackOff** — give it 60s; webhook needs CRDs installed first.
- **`internal-ca-issuer` READY=False** — `kubectl describe clusterissuer internal-ca-issuer`. Almost always the `internal-ca` Certificate isn't ready yet.

---

## Step 4 — gateway TLS certificate

**What it does:** Creates a `Certificate` covering the in-cluster Kubernetes Service DNS names that apps will use to reach the gateway — `pcg-nginx.newrelic.svc.cluster.local` (via NGINX ingress), `pcg-kong-kong-proxy.newrelic.svc.cluster.local` (via Kong, if used), `pipeline-control-gateway.newrelic.svc.cluster.local` (direct-to-gateway), plus the short-form aliases. Signed by `internal-ca-issuer` from Step 3. cert-manager writes the TLS cert+key into the Secret `pcg-tls-secret` in the `newrelic` namespace. The module **waits** for the Certificate to report `Ready=True` before finishing — no race with downstream steps. It also reads the CA Secret from Step 3 and copies the CA cert into a Secret (`pcg-ca-bundle`, type Opaque) in the `newrelic` namespace, so app pods can mount it and trust the gateway. This matches the out-of-cluster module's shape — apps in both scenarios use the same mount pattern.

**Why:** Step 6's NGINX needs the TLS cert+key to terminate HTTPS. Apps need the CA cert (`ca.crt`) to trust the gateway over TLS.

**How it works:** `kubernetes_manifest` with a `wait { condition { type = "Ready" status = "True" } }` block — Terraform polls until cert-manager flips the condition. 5 minute timeout.

```bash
cd aws/4-dns-tls/cert-manager/4.3-pcg-certificate

terraform init
terraform plan  -var-file=../../../intra-cluster.tfvars
terraform apply -var-file=../../../intra-cluster.tfvars
```

**Verify:**

```bash
kubectl get certificate -n newrelic
kubectl describe certificate pcg-tls -n newrelic | grep -A5 Status

kubectl get secret pcg-tls-secret -n newrelic -o jsonpath='{.data}' \
  | tr ',' '\n' | grep -o '"tls.[a-z]*"'

kubectl get secret pcg-ca-bundle -n newrelic -o jsonpath='{.data.ca\.crt}' | base64 -d | head -c 50
echo

terraform output
```

**Troubleshooting:**
- **Apply hangs at "Still creating..."** — cert-manager is slow. `kubectl get certificaterequest -n newrelic` and `kubectl logs -n cert-manager -l app=cert-manager` show progress.

---

## Step 5 — the gateway (Agent Control)

**What it does:** Helm-installs `agent-control-bootstrap` from `https://helm-charts.newrelic.com` in the `newrelic-agent-control` namespace, using **your downloaded values.yaml**. Agent Control then deploys the gateway (via Flux) into the `newrelic` namespace. This is the Terraform equivalent of:
```bash
helm upgrade --install agent-control-bootstrap -n newrelic-agent-control \
  newrelic/agent-control-bootstrap --create-namespace \
  --values ~/Downloads/values-newrelic-gateway.yaml
```
You don't run that manually — Terraform does it.

**Why Step 5 comes before Step 6 (NGINX):** NGINX resolves its gateway backend by DNS at startup. If NGINX starts before the gateway Service exists in `newrelic`, NGINX crashes with `host not found in upstream` and enters CrashLoopBackOff. Deploying the gateway first makes NGINX's cold-start clean.

### Set up the values file

Copy your wizard-generated values.yaml into the module directory. Keep it local so Terraform's `file()` can find it. **This file contains your ingest license — don't commit it.**

```bash
cd aws/5-pcg/flux

# Adjust path to wherever you saved the wizard download:
cp ~/Downloads/values-newrelic-gateway.yaml ./pcg-values.yaml

# Sanity check
head -20 ./pcg-values.yaml
```

### Apply

```bash
terraform init
terraform plan  -var-file=../../intra-cluster.tfvars -var="pcg_values_file=./pcg-values.yaml"
terraform apply -var-file=../../intra-cluster.tfvars -var="pcg_values_file=./pcg-values.yaml"
```

Apply takes ~3-5 min: Helm installs Agent Control, then a 180s `time_sleep` gives Flux time to create the gateway's Deployment and Service before Terraform returns.

**Verify:**

```bash
# Agent Control installed
kubectl get pods -n newrelic-agent-control
helm list -n newrelic-agent-control

# The gateway deployed by Flux (1-2 min after apply finishes)
kubectl get pods -n newrelic
# Expect: pipeline-control-gateway-* pods Running

# Gateway Service exists — NGINX in Step 6 will resolve to this
kubectl get svc pipeline-control-gateway -n newrelic
# Expect ports: 80, 4317, 4318
```

**Troubleshooting:**
- **`pipeline-control-gateway` pods missing after apply** — Flux is slow. Wait 2-3 min. `kubectl get helmrelease -n newrelic-agent-control` and `kubectl logs -n newrelic-agent-control -l app=agent-control` show progress.
- **`namespaces "newrelic" already exists`** — Step 4 ([`4.3-pcg-certificate`](../aws/4-dns-tls/cert-manager/4.3-pcg-certificate/)) already created it, and by default this module trusts that (`create_pcg_namespace = false`). If you somehow still hit this error, either (a) an old apply of this module put the namespace in this module's state — import it: `terraform import 'kubernetes_namespace_v1.pcg[0]' newrelic`; or (b) you set `create_pcg_namespace = true` — set it back to `false` for the intra-cluster pattern.

---

## Step 6 — Ingress (NGINX)

You have two options for the ingress. Pick one (mutually exclusive — both would try to own the same TLS Secret).

- **[`reverse-proxy-within-cluster/nginx`](../aws/3-ingress/reverse-proxy-within-cluster/nginx/)** — validated end to end (this guide). Use this by default.
- **[`reverse-proxy-within-cluster/kong`](../aws/3-ingress/reverse-proxy-within-cluster/kong/)** — Kong instead of NGINX. Use it if your platform already standardises on Kong; see its module README. The rest of this Step 6 assumes NGINX.

**What it does:** Deploys `nginx:1.25-alpine` (2 replicas) + ClusterIP Service in `newrelic`. Listens on:
- **80** — HTTP for OTLP HTTP + NR proprietary agent traffic
- **443** — HTTPS (terminates TLS using `pcg-tls-secret` from Step 4)
- **4317** — OTLP gRPC (HTTP/2, passes through to the gateway's gRPC receiver)

Routes by path: `/v1/traces|metrics|logs` → gateway OTLP HTTP (4318), `/metric/v1|/v1/accounts/events|/agent_listener` → gateway NR proprietary (80), `/` catch-all → gateway NR proprietary. `/health` returns a static 200 from NGINX itself (the gateway's health port 13133 is not exposed by its Service).

**How apps find NGINX:** Apps use the Kubernetes-native Service DNS name — `pcg-nginx.newrelic.svc.cluster.local` — which Kubernetes' built-in DNS resolves automatically. **No CoreDNS patching, no custom hostname setup.** The TLS certificate from Step 4 already covers this name, so TLS handshakes verify cleanly.

**Why not the friendlier `pcg.newrelic.internal`?** Previous versions of this module patched CoreDNS to add a `newrelic.internal:53` server block so apps could use `pcg.newrelic.internal`. That approach had a real destroy-safety bug: `terraform destroy` on this module left the coredns ConfigMap in a broken state, breaking cluster-wide DNS. Using the Kubernetes-native Service DNS name avoids that class of bug entirely, and needs no cluster-wide DNS changes at all.

### Apply

```bash
cd aws/3-ingress/reverse-proxy-within-cluster/nginx

terraform init
terraform plan  -var-file=../../../intra-cluster.tfvars
terraform apply -var-file=../../../intra-cluster.tfvars
```

Apply takes <1 min. NGINX pods should become Ready quickly since the gateway (Step 5) already exists.

**Verify:**

```bash
# 2 NGINX pods Running (not CrashLoopBackOff)
kubectl get pods -n newrelic -l app.kubernetes.io/name=pcg-nginx

# NGINX Service has a ClusterIP
kubectl get svc pcg-nginx -n newrelic

# DNS resolution — Kubernetes' built-in service DNS just works
kubectl run dnstest --rm -it --restart=Never --image=busybox -- \
  nslookup pcg-nginx.newrelic.svc.cluster.local
# Expect: Address: <NGINX Service ClusterIP>

# End-to-end health check
kubectl run curltest --rm -it --restart=Never --image=curlimages/curl -- \
  curl -kv https://pcg-nginx.newrelic.svc.cluster.local/health
# Expect: HTTP 200 with body "healthy"
```

**If the health check returns 200 — you're done. The gateway is live.**

**Troubleshooting:**
- **NGINX pods CrashLoopBackOff with `host not found in upstream`** — the gateway doesn't exist yet. Step 5 didn't complete. Re-check `kubectl get svc pipeline-control-gateway -n newrelic`.
- **NGINX pods CrashLoopBackOff with `mkdir() ".../nginx" failed (Read-only file system)`** — module deployment spec is out of sync. Re-apply.
- **`curl` returns 502** — NGINX reaches its backend DNS but the gateway service is down. `kubectl logs -n newrelic -l app.kubernetes.io/name=pipeline-control-gateway`.
- **`curl` returns TLS error `x509: certificate is not valid for any names`** — the cert doesn't cover the hostname you're using. Confirm you're hitting `pcg-nginx.newrelic.svc.cluster.local` (the name the cert covers), not `pcg.newrelic.internal` (legacy) or an IP.
- **`curl -k` still returns a TLS error** — `-k` skips certificate verification, but not the handshake itself. If handshake is failing, check `kubectl logs -n newrelic -l app.kubernetes.io/name=pcg-nginx` for TLS load errors.

---

## Done — verify data is flowing

1. **New Relic Gateway Health dashboard** — should show your gateway connected within minutes
2. **Send test traffic** — point any NR agent at `pcg-nginx.newrelic.svc.cluster.local:443` (mount the CA bundle, see below)

## Configuring apps in this cluster to use the gateway

Apps need (a) the gateway hostname/port, and (b) trust for the self-signed CA.

### Hostname env vars (most NR agents)

```yaml
env:
  - name: NEW_RELIC_HOST
    value: "pcg-nginx.newrelic.svc.cluster.local"
  - name: NEW_RELIC_PORT
    value: "443"
```

If your app runs in the `newrelic` namespace, the short form `pcg-nginx` works too. From other namespaces you need the full `.newrelic.svc.cluster.local` suffix.

### OTLP exporters

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "https://pcg-nginx.newrelic.svc.cluster.local:443"
  # gRPC variant:
  # value: "pcg-nginx.newrelic.svc.cluster.local:4317"
```

### Mounting the CA bundle (so apps trust the self-signed cert)

```yaml
spec:
  containers:
    - name: app
      env:
        - name: NODE_EXTRA_CA_CERTS              # Node.js
          value: /etc/ssl/certs/pcg-ca.crt
        # Java:   NEW_RELIC_CA_BUNDLE_PATH or JAVA_TOOL_OPTIONS=-Djavax.net.ssl.trustStore=...
        # Python: NEW_RELIC_CA_BUNDLE_PATH or SSL_CERT_FILE
        # Go:     SSL_CERT_FILE (+ init container to merge with system CAs)
        # .NET:   SSL_CERT_FILE (+ init container)
        # Ruby:   SSL_CERT_FILE
        # PHP:    CURL_CA_BUNDLE
      volumeMounts:
        - name: ca-bundle
          mountPath: /etc/ssl/certs/pcg-ca.crt
          subPath: ca.crt
  volumes:
    - name: ca-bundle
      secret:
        secretName: pcg-ca-bundle    # in 'newrelic' namespace
```

If your apps run in another namespace, copy the Secret:
```bash
kubectl get secret pcg-ca-bundle -n newrelic -o yaml \
  | sed 's/namespace: newrelic/namespace: YOUR_APP_NAMESPACE/' \
  | kubectl apply -f -
```

---

## Step 7 — Cleanup (when done testing)

Tear down in **reverse order**:

Run each block from the repo root.

```bash
cd aws/3-ingress/reverse-proxy-within-cluster/nginx
terraform destroy -var-file=../../../intra-cluster.tfvars
cd -

cd aws/5-pcg/flux
terraform destroy -var-file=../../intra-cluster.tfvars -var="pcg_values_file=./pcg-values.yaml"
cd -

cd aws/4-dns-tls/cert-manager/4.3-pcg-certificate
terraform destroy -var-file=../../../intra-cluster.tfvars
cd -

cd aws/4-dns-tls/cert-manager/4.1-installer
terraform destroy -var-file=../../../intra-cluster.tfvars
cd -

cd aws/2-eks
terraform destroy -var-file=../intra-cluster.tfvars    # ~10 min
cd -

cd aws/1-vpc
terraform destroy -var-file=../intra-cluster.tfvars    # ~3 min
cd -
```

**If destroy hangs on EKS:** nodes sometimes get stuck terminating. `aws eks list-nodegroups --cluster-name <name> --region <region>`, then `aws eks delete-nodegroup` manually.

**If destroy hangs on VPC:** check for orphaned ENIs (`aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<VPC_ID>`). EKS sometimes leaves them — delete manually, retry destroy.

---

## Module reference

| Step | Module | What it creates |
|---|---|---|
| 1 | [`1-vpc`](../aws/1-vpc/) | VPC + 6 subnets + IGW + 3 NAT gateways + route tables |
| 2 | [`2-eks`](../aws/2-eks/) | EKS control plane + node group + OIDC + IAM roles |
| 3 | [`4.1-installer`](../aws/4-dns-tls/cert-manager/4.1-installer/) | cert-manager Helm release + self-signed CA + `internal-ca-issuer` |
| 4 | [`4.3-pcg-certificate`](../aws/4-dns-tls/cert-manager/4.3-pcg-certificate/) | TLS Certificate covering the NGINX and Kong Service DNS names → `pcg-tls-secret`, plus `pcg-ca-bundle` Secret |
| 5 | [`5-pcg/flux`](../aws/5-pcg/flux/) | `agent-control-bootstrap` Helm release (deploys the gateway via Flux) |
| 6 | [`reverse-proxy-within-cluster/nginx`](../aws/3-ingress/reverse-proxy-within-cluster/nginx/) | NGINX Deployment + Service (terminates TLS, proxies to the gateway via k8s Service DNS) |

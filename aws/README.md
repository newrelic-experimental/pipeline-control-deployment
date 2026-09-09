# AWS deployment guide

Terraform modules for deploying the New Relic Pipeline Control gateway on AWS EKS. This is the canonical set of commands; for the architecture behind them see [`../docs/architecture.md`](../docs/architecture.md).

> **Experimental.** A reference architecture meant as a baseline to adapt, not a supported product. The defaults here favor a working end-to-end walkthrough over a hardened one, so review them against your own network, IAM, and security model before any production use.

**Two supported topologies.** Pick one and follow that section end to end. Do not mix steps between the two: the variable files, modules, and verification paths all differ.

- **[Intra-cluster](#intra-cluster-telemetry-workloads-in-the-gateways-cluster)** — agents and telemetry workloads are deployed in the same k8s cluster as your Pipeline Control gateway. Uses NGINX (or Kong) with cert-manager for in-cluster TLS. Generally the simplest and cheapest to deploy.
- **[Out-of-cluster](#out-of-cluster-telemetry-workloads-outside-the-gateways-cluster)** — agents and telemetry workloads are deployed outside the k8s cluster running your Pipeline Control gateway. Uses an internal ALB, an ACM Private CA, and a Route53 private zone. This guide uses a second EKS cluster in the same VPC as its worked example of a sender, but senders can be anywhere that can route to the load balancer.

> **Going deeper on either topology:** [`../docs/pattern-intra-cluster.md`](../docs/pattern-intra-cluster.md) and [`../docs/pattern-out-of-cluster.md`](../docs/pattern-out-of-cluster.md) explain the design, trade-offs, and verification proofs. This guide is the commands.

---

## Prerequisites (both topologies)

- An AWS account, with credentials that can create the resources each module needs. If your account restricts `iam:CreateRole`, see [Restricted-IAM accounts](#restricted-iam-accounts) below.
- `terraform` >= 1.0, `kubectl`, `aws` CLI, `helm`, `jq`, `python3`
- A New Relic account and an **ingest license key**
- A Pipeline Control fleet configured in the New Relic UI. You download a `values.yaml` from it during the gateway install step.

**Cost heads-up (out-of-cluster only):** the ACM Private CA created in Step 5 bills a flat monthly rate whether idle or busy ([pricing](https://aws.amazon.com/private-ca/pricing/)). Destroy that module when you are not actively using it.

**Cross-cutting choice — gateway install mode:**

Your pipeline configuration arrives from the New Relic UI in both modes. What differs is who owns the gateway's infrastructure lifecycle.

- **Flux mode** (`5-pcg/flux/`) — Agent Control installs Flux, and New Relic manages the gateway's replicas, CPU target and version for you. Needs cluster-admin.
- **Fluxless mode** (`5-pcg/fluxless/`) — Helm installs the gateway directly and you own its scaling and upgrades via `pcg-values.yaml`. Namespace-scoped RBAC, co-locates with other workloads.

Both modes work with both topologies and expose identical interfaces for ingress and Route53.

If you're **creating a new gateway fleet**, you pick the pattern in the install wizard and the fleet is created with it, so choose on whether you want New Relic managing gateway scaling and versions, and on the RBAC you can grant. If you're **reusing an existing gateway fleet**, its pattern is already fixed and you need to match it — the wizard offering one `values.yaml` means Flux, two means Fluxless. See [`5-pcg/README.md`](5-pcg/README.md) for the full trade-offs.

> **Variable files live in `aws/`**, alongside this file, so that each cloud owns its own inputs.
>
> **All `cd` commands start from the repo root.** Return to the root between steps.

---

# Intra-cluster: telemetry workloads in the gateway's cluster

**End state:** app pod in the cluster → in-cluster reverse proxy (NGINX or Kong) → gateway → New Relic. No external ALB, no Route53. Reachable at Kubernetes Service DNS names.

**Modules used, in order:**

| Step | Module | Purpose |
|---|---|---|
| 1 | `1-vpc/` | VPC + subnets + NAT (or BYO — skip if you have one) |
| 2 | `2-eks/` | Single EKS cluster (or BYO) |
| 3 | `4-dns-tls/cert-manager/4.1-installer/` | cert-manager (installs the CRDs) |
| 4a | `4-dns-tls/cert-manager/4.2-cluster-issuer/` | Internal CA + `internal-ca-issuer` ClusterIssuer |
| 4b | `4-dns-tls/cert-manager/4.3-pcg-certificate/` | Server cert + CA bundle Secret |
| 5 | `5-pcg/flux/` OR `5-pcg/fluxless/` | gateway install (with `create_alb_ingress = false`) |
| 6 | `3-ingress/reverse-proxy-within-cluster/nginx/` OR `.../kong/` | In-cluster reverse proxy (⚠️ apply AFTER the gateway — see note below) |
| 7 | Reproducible test | Pod curls the Service DNS name; verify in New Relic |

> **Ordering matters:** the reverse proxy (Step 6) must run **after** the gateway (Step 5). NGINX has a hardcoded upstream (`pipeline-control-gateway.newrelic.svc.cluster.local`) that resolves at nginx startup. If the gateway's Service doesn't exist yet when NGINX starts, NGINX crashloops with `host not found in upstream`. Kong hits the same issue at Ingress reconcile time. Apply the gateway first, then the proxy.

## Intra-cluster Step 0 — tfvars

```bash
cp aws/intra-cluster.tfvars.example aws/intra-cluster.tfvars
# Edit: cluster_name, aws_region, permissions_boundary (if your account needs one)
```
This single tfvars file is passed to every intra-cluster module.

## Intra-cluster Step 1 — VPC

```bash
cd aws/1-vpc
terraform init
terraform apply -var-file=../intra-cluster.tfvars
cd -
```

Skip if you have an existing VPC (BYO — see [`1-vpc/README.md`](1-vpc/README.md)).

## Intra-cluster Step 2 — EKS

```bash
cd aws/2-eks
terraform init
terraform apply -var-file=../intra-cluster.tfvars
cd -
```

Takes ~15 min. Set your kubectl context:
```bash
# Copy-paste warning: substitute your real region and cluster name INTO the
# command. Do NOT copy the angle brackets — zsh treats `<region>` as a
# here-string redirect and fails with an obscure parse error.
aws eks update-kubeconfig --region "YOUR_REGION" --name "YOUR_CLUSTER_NAME"
```

Skip if you have an existing cluster (BYO — see [`2-eks/README.md`](2-eks/README.md)).

## Intra-cluster Step 3 — cert-manager installer

```bash
cd aws/4-dns-tls/cert-manager/4.1-installer
terraform init
terraform apply -var-file=../../../intra-cluster.tfvars
cd -
```

Installs cert-manager (Helm), including its CRDs.

## Intra-cluster Step 4a — internal CA + ClusterIssuer

```bash
cd aws/4-dns-tls/cert-manager/4.2-cluster-issuer
terraform init
terraform apply -var-file=../../../intra-cluster.tfvars
cd -
```

Creates the `selfsigned-issuer` ClusterIssuer, the `internal-ca` Certificate, and the `internal-ca-issuer` ClusterIssuer that Step 4b will use to sign the gateway cert.

## Intra-cluster Step 4b — gateway certificate

```bash
cd aws/4-dns-tls/cert-manager/4.3-pcg-certificate
terraform init
terraform apply -var-file=../../../intra-cluster.tfvars
cd -
```

Requests a cert (SANs cover the NGINX and Kong Service DNS names). Emits:
- `pcg-tls-secret` (`kubernetes.io/tls`) — for the reverse-proxy module
- `pcg-ca-bundle` (Opaque) — for app pods to mount as their CA trust source

## Intra-cluster Step 5 — gateway install (Flux OR Fluxless)

Intra-cluster uses `create_alb_ingress = false` (the default). No external ALB, no Route53 record.

**⚠️ Must run before Step 6.** The reverse proxy resolves the gateway's Service DNS at startup — the gateway must exist first.

### Intra-cluster Step 5a — Get values.yaml from the New Relic UI

- **Flux mode:** wizard shows ONE download → save as `aws/5-pcg/flux/pcg-values.yaml`
- **Fluxless mode:** wizard shows TWO downloads → save:
  - `aws/5-pcg/fluxless/agent-control-values.yaml`
  - `aws/5-pcg/fluxless/pcg-values.yaml`

**Fluxless-only tfvars:**
```hcl
agent_control_values_file = "./agent-control-values.yaml"
pcg_values_file           = "./pcg-values.yaml"
```

### Intra-cluster Step 5b — Apply

**Flux mode:**
```bash
cd aws/5-pcg/flux
terraform init
terraform apply -var-file=../../intra-cluster.tfvars
cd -
```

**Fluxless mode:**
```bash
cd aws/5-pcg/fluxless
terraform init
terraform apply -var-file=../../intra-cluster.tfvars
cd -
```

**Verify:**
```bash
kubectl get pods -n newrelic
# pipeline-control-gateway-xxxxx  1/1 or 2/2 Running
```

## Intra-cluster Step 6 — Reverse proxy (pick ONE)

**⚠️ Must run after Step 5.** NGINX/Kong resolves the gateway upstream Service DNS at startup — if the gateway's Service doesn't exist yet, the proxy CrashLoopBackOff's with `host not found in upstream`.

### Option A — NGINX

```bash
cd aws/3-ingress/reverse-proxy-within-cluster/nginx
terraform init
terraform apply -var-file=../../../intra-cluster.tfvars
cd -
```
Reachable at `pcg-nginx.newrelic.svc.cluster.local:443`.

### Option B — Kong

```bash
cd aws/3-ingress/reverse-proxy-within-cluster/kong
terraform init
terraform apply -var-file=../../../intra-cluster.tfvars
cd -
```
Reachable at `pcg-kong-kong-proxy.newrelic.svc.cluster.local:443`.

## Intra-cluster Step 7 — Send test data

Any pod in the cluster can hit the reverse proxy's Service DNS name, mounting `pcg-ca-bundle` as its CA trust:

```bash
# NGINX endpoint:
curl --cacert /tmp/pcg-ca.crt https://pcg-nginx.newrelic.svc.cluster.local:443/v1/logs -X POST ...

# Kong endpoint:
curl --cacert /tmp/pcg-ca.crt https://pcg-kong-kong-proxy.newrelic.svc.cluster.local:443/v1/logs -X POST ...
```

Reference test scripts are under `aws/tests/` ([`tests/send-inventory-logs-intra-cluster.sh`](tests/send-inventory-logs-intra-cluster.sh) for intra-cluster, [`tests/send-inventory-logs-out-of-cluster.sh`](tests/send-inventory-logs-out-of-cluster.sh) for out-of-cluster). Guided install/teardown scaffolds live at `aws/scripts/`.

## Intra-cluster Cleanup (destroy) — reverse of apply order

```bash
# Step 6 — reverse proxy (pick whichever you applied)
cd aws/3-ingress/reverse-proxy-within-cluster/nginx && terraform destroy -var-file=../../../intra-cluster.tfvars && cd -
# (or aws/3-ingress/reverse-proxy-within-cluster/kong)

# Step 5 — gateway install
cd aws/5-pcg/flux && terraform destroy -var-file=../../intra-cluster.tfvars && cd -
# (or aws/5-pcg/fluxless)

# Step 4b
cd aws/4-dns-tls/cert-manager/4.3-pcg-certificate && terraform destroy -var-file=../../../intra-cluster.tfvars && cd -

# Step 4a
cd aws/4-dns-tls/cert-manager/4.2-cluster-issuer && terraform destroy -var-file=../../../intra-cluster.tfvars && cd -

# Step 3
cd aws/4-dns-tls/cert-manager/4.1-installer && terraform destroy -var-file=../../../intra-cluster.tfvars && cd -

# Step 2
cd aws/2-eks && terraform destroy -var-file=../intra-cluster.tfvars && cd -

# Step 1
cd aws/1-vpc && terraform destroy -var-file=../intra-cluster.tfvars && cd -
```

> **Kubernetes provider 2.37.0 identity bug on the reverse proxy destroy:** the repo pins `~> 2.37.1` to skip it. If you've loosened the pin and `terraform destroy` on the NGINX/Kong module fails with `Error: Unexpected Identity Change`, workaround:
> ```bash
> kubectl delete deployment,service,configmap -n newrelic -l app.kubernetes.io/name=pcg-nginx  # or pcg-kong
> terraform state rm kubernetes_deployment_v1.nginx kubernetes_service_v1.nginx kubernetes_config_map_v1.nginx_config
> rm -rf terraform.tfstate* .terraform .terraform.lock.hcl
> ```
> Then continue destroy on the next module.

**Terraform state drift heads-up:** if any apply was interrupted, Helm releases may exist without TF state. `terraform destroy` only removes tracked resources. After destroy:
```bash
helm list -n newrelic
# If not empty:
helm uninstall newrelic-pcg -n newrelic
helm uninstall agent-control-deployment -n newrelic
```

**NAT Gateway Elastic IP is not stable across destroy/recreate.** Destroying `1-vpc` releases each NAT Gateway's EIP; a subsequent apply allocates fresh ones. If you rely on a stable egress IP anywhere off-cluster (a customer firewall allowlist, a partner-side allowlist, or a third-party service that authenticates by source IP), do not destroy/recreate this module — either keep `1-vpc` up between sessions, or arrange to update the allowlist on every recreate.

For failure recovery patterns (state lock stuck, DNS blips against the cluster endpoint, provider-registry timeouts), see [Common failure recovery](#common-failure-recovery) below.

---

# Out-of-cluster: telemetry workloads outside the gateway's cluster

For when the workloads sending telemetry run outside the cluster the gateway runs in. The steps below use a second EKS cluster in the same VPC as the gateway cluster, because that is the case this repo provisions end to end, but nothing in the gateway-side setup assumes that: any sender that can resolve the private hostname and reach the internal ALB works the same way.

**End state:** apps-cluster pod → Route53 private zone → internal ALB (TLS via Private CA) → gateway → New Relic.

**Modules used, in order:**

| Step | Module | Purpose |
|---|---|---|
| 1 | `1-vpc/` | Shared VPC with 2 clusters' subnet tags |
| 2 | `2-eks/` (×2 workspaces) | pcg-cluster + apps-cluster, both in shared VPC |
| 3 | `3-ingress/alb/` (pcg-cluster workspace) | AWS Load Balancer Controller via Helm + IRSA |
| 4 | `4-dns-tls/private/4.1-route53-private-zone/` | Private hosted zone `internal.newrelic` |
| 5 | `4-dns-tls/private/4.2-out-of-cluster-tls/` | ACM Private CA + server cert + 2 K8s Secrets |
| 6 | `5-pcg/flux/` OR `5-pcg/fluxless/` | gateway install + ALB Ingress + Route53 A-record |
| 7 | Reproducible test script | 4 OTLP logs from apps-cluster; verify in New Relic |

## Out-of-cluster Step 0 — tfvars

```bash
cp aws/out-of-cluster-private-dns-pcg.tfvars.example  aws/out-of-cluster-private-dns-pcg.tfvars
cp aws/out-of-cluster-private-dns-apps.tfvars.example aws/out-of-cluster-private-dns-apps.tfvars
# Edit both. They share vpc_name and shared_cluster_names; differ on cluster_name.
```

## Out-of-cluster Step 1 — VPC

```bash
cd aws/1-vpc
terraform init
terraform apply -var-file=../out-of-cluster-private-dns-pcg.tfvars
cd -
```

**Note:** `shared_cluster_names = ["pcg-cluster", "apps-cluster"]` tags every subnet with `kubernetes.io/cluster/<name>=shared` for both clusters, so both discover the shared subnets.

## Out-of-cluster Step 2 — EKS (two clusters, two workspaces)

```bash
cd aws/2-eks
terraform init

# pcg-cluster
terraform workspace new pcg-cluster 2>/dev/null || terraform workspace select pcg-cluster
terraform apply -var-file=../out-of-cluster-private-dns-pcg.tfvars

# apps-cluster
terraform workspace new apps-cluster 2>/dev/null || terraform workspace select apps-cluster
terraform apply -var-file=../out-of-cluster-private-dns-apps.tfvars

cd -
```

Takes ~15 min per cluster. The `new … || select …` pattern is idempotent so a leftover workspace from an earlier run doesn't cause `workspace new` to fail and leave you in the wrong workspace.

**Set kubectl contexts and save them:**
```bash
# Substitute your real region name into both commands (don't include the quotes-or-angle-brackets).
aws eks update-kubeconfig --region "YOUR_REGION" --name pcg-cluster
aws eks update-kubeconfig --region "YOUR_REGION" --name apps-cluster

# Substitute your real region + AWS account ID (no angle brackets).
export CTX_PCG="arn:aws:eks:YOUR_REGION:YOUR_ACCOUNT_ID:cluster/pcg-cluster"
export CTX_APPS="arn:aws:eks:YOUR_REGION:YOUR_ACCOUNT_ID:cluster/apps-cluster"
```

## Out-of-cluster Step 3 — ALB Controller (pcg-cluster only)

```bash
cd aws/3-ingress/alb
terraform init
terraform workspace new pcg-cluster 2>/dev/null || terraform workspace select pcg-cluster
terraform apply -var-file=../../out-of-cluster-private-dns-pcg.tfvars
cd -
```

Installs the AWS Load Balancer Controller into pcg-cluster's `kube-system`. The controller watches Ingress resources; the ALB itself is created in out-of-cluster Step 6 when the Ingress is applied.

**Verify:** `kubectl --context $CTX_PCG get deploy aws-load-balancer-controller -n kube-system`

## Out-of-cluster Step 4 — Route53 private hosted zone

```bash
cd aws/4-dns-tls/private/4.1-route53-private-zone
terraform init
terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars
cd -
```

Creates the empty private zone (default `internal.newrelic`), associated with the shared VPC.

**Copy the output `zone_id`** into `aws/out-of-cluster-private-dns-pcg.tfvars` where `route53_zone_id = "REPLACE_..."` is set.

## Out-of-cluster Step 5 — TLS ⚠️ the Private CA charge starts here

```bash
cd aws/4-dns-tls/private/4.2-out-of-cluster-tls
terraform init
terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars
cd -
```

Creates ACM Private CA + server cert. Writes:
- `pcg-tls-secret` (cert+key) → pcg-cluster `newrelic` namespace
- `pcg-ca-bundle` (CA cert only) → apps-cluster `default` namespace
- ACM certificate (import of the same server cert, ARN used by the ALB)

**Copy the output `acm_certificate_arn`** into `aws/out-of-cluster-private-dns-pcg.tfvars` where `acm_certificate_arn = "REPLACE_..."` is set.

**Out-of-cluster trust verify:**
```bash
kubectl --context $CTX_PCG  get secret pcg-tls-secret -n newrelic -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/server.crt
kubectl --context $CTX_APPS get secret pcg-ca-bundle  -n default  -o jsonpath='{.data.ca\.crt}'  | base64 -d > /tmp/ca.crt
openssl verify -CAfile /tmp/ca.crt /tmp/server.crt
# /tmp/server.crt: OK
```

## Out-of-cluster Step 6 — gateway install (Flux OR Fluxless)

> Terraform targets the cluster named in `cluster_name` in tfvars — NOT your current kubectl context. `data "aws_eks_cluster"` fetches the endpoint. For the `kubectl` verify commands, use `--context $CTX_PCG` explicitly.

### Out-of-cluster Step 6a — Get values.yaml from the New Relic UI

- **Flux mode:** wizard shows ONE download. Save as `aws/5-pcg/flux/pcg-values.yaml` (gitignored).
- **Fluxless mode:** wizard shows TWO downloads. Save:
  - `aws/5-pcg/fluxless/agent-control-values.yaml`
  - `aws/5-pcg/fluxless/pcg-values.yaml`

**Fluxless-only tfvars:**
```hcl
agent_control_values_file = "./agent-control-values.yaml"
pcg_values_file           = "./pcg-values.yaml"
```

### Out-of-cluster Step 6b — Apply

**Flux mode:**
```bash
cd aws/5-pcg/flux
terraform init
terraform apply -var-file=../../out-of-cluster-private-dns-pcg.tfvars
cd -
```

**Fluxless mode:**
```bash
cd aws/5-pcg/fluxless
terraform init
terraform apply -var-file=../../out-of-cluster-private-dns-pcg.tfvars
cd -
```

**Route53 propagation quirk:** After apply, DNS may lag 30–60 s. If out-of-cluster Step 7's script says `Could not resolve host`, wait a minute and re-run.

**ALB provisioning quirk:** if apply itself fails with `data.kubernetes_ingress_v1.pcg_alb ... status ... is empty list`, wait 60 s and re-run apply.

**Verify:**
```bash
kubectl --context $CTX_PCG get pods -n newrelic
# pipeline-control-gateway-xxxxx  1/1 or 2/2 Running

kubectl --context $CTX_PCG get ingress -n newrelic pcg-alb
# ADDRESS should be the internal ALB hostname

```

## Out-of-cluster Step 7 — Send test data

```bash
aws/tests/send-inventory-logs-out-of-cluster.sh
# Expect HTTP 200 on each of the 4 OTLP records
```

Data lands in New Relic UI → Logs.

## Out-of-cluster Cleanup (destroy) — reverse of apply order

```bash
# Step 6 first
cd aws/5-pcg/flux && terraform destroy -var-file=../../out-of-cluster-private-dns-pcg.tfvars && cd -
# (or aws/5-pcg/fluxless)

# Step 5 STOPS THE PRIVATE CA BILLING
cd aws/4-dns-tls/private/4.2-out-of-cluster-tls && terraform destroy -var-file=../../../out-of-cluster-private-dns-pcg.tfvars && cd -

# Step 4
cd aws/4-dns-tls/private/4.1-route53-private-zone && terraform destroy -var-file=../../../out-of-cluster-private-dns-pcg.tfvars && cd -

# Step 3
cd aws/3-ingress/alb && terraform workspace select pcg-cluster && terraform destroy -var-file=../../out-of-cluster-private-dns-pcg.tfvars && cd -

# Step 2 (both workspaces)
cd aws/2-eks
terraform workspace select apps-cluster && terraform destroy -var-file=../out-of-cluster-private-dns-apps.tfvars
terraform workspace select pcg-cluster  && terraform destroy -var-file=../out-of-cluster-private-dns-pcg.tfvars
cd -

# Step 1
cd aws/1-vpc && terraform destroy -var-file=../out-of-cluster-private-dns-pcg.tfvars && cd -
```

**Terraform state drift heads-up:** if any apply was interrupted, Helm releases may exist without TF state. `terraform destroy` only removes tracked resources. After destroy:
```bash
helm list -n newrelic
# Should be empty. If not:
helm uninstall newrelic-pcg -n newrelic
helm uninstall agent-control-deployment -n newrelic
```

**NAT Gateway Elastic IP is not stable across destroy/recreate.** Destroying `1-vpc` releases each NAT Gateway's EIP; a subsequent apply allocates fresh ones. If you rely on a stable egress IP anywhere off-cluster (a customer firewall allowlist, a partner-side allowlist, or a third-party service that authenticates by source IP), do not destroy/recreate this module — either keep `1-vpc` up between sessions, or arrange to update the allowlist on every recreate.

**Verify the destroy actually stopped billing:**
```bash
# Substitute your region + the VPC ID printed at destroy time.
aws eks list-clusters              --region "YOUR_REGION"                              # empty
aws elbv2 describe-load-balancers  --region "YOUR_REGION"                              # empty or unrelated
aws acm-pca list-certificate-authorities --region "YOUR_REGION"                        # empty (or in DELETED state — see below)
aws ec2 describe-nat-gateways      --region "YOUR_REGION" \
   --filter Name=state,Values=available,pending                                        # empty
aws ec2 describe-addresses         --region "YOUR_REGION" \
   --query 'Addresses[?AssociationId==`null`].[AllocationId,PublicIp]'                 # empty (or unrelated EIPs)
helm list --all-namespaces                                                             # no leftovers
```
Private CA note: `aws acm-pca list-certificate-authorities` may still show your CA in `DELETED` state for **7 days** after destroy. Billing stops at the moment of destroy, not at end-of-7-days — the record just lingers as a safety net in case you want to restore.

---

## Common failure recovery

Symptoms you're likely to hit at some point, ordered by "did you actually break something."

**`Error acquiring the state lock`** — happens when a previous `apply` or `destroy` was killed (closed laptop, lost connection, Ctrl+C). Before you reach for `-lock=false` or `force-unlock`, confirm nothing is actually still running:
```bash
ps aux | grep terraform
```
Terraform operations on EKS and VPC routinely take 10–15 min and are easy to mistake for stuck. Only force-unlock if there's genuinely no `terraform` process alive:
```bash
terraform force-unlock <LOCK_ID>   # LOCK_ID appears in the error output
```
On a shared state backend (S3 + DynamoDB), also confirm no teammate is applying — force-unlocking someone else's live apply corrupts state.

**Transient DNS or provider-registry errors during `terraform init`** — `Failed to query available provider packages`, `dial tcp: lookup ... no such host`, connection resets against `registry.terraform.io`. Common on corporate networks/VPNs. Safe to retry — `init` doesn't modify state or resources. If it fails 3+ times in a row, check corporate proxy / DNS / firewall rules rather than the modules.

**Transient errors against the EKS cluster endpoint** during `terraform apply` — `dial tcp: lookup <cluster>.eks.amazonaws.com`, DNS failures resolving the K8s API. Usually a one-off VPN/DNS blip. Retry once. If it persists, check whether your workstation can reach the cluster's endpoint (see the endpoint-access variables in [`2-eks/README.md`](2-eks/README.md#cluster-endpoint-access)).

**Do NOT retry `terraform apply` blindly if it partially succeeded on state-modifying steps.** Read the error, understand what got created and what didn't. `terraform state list` shows what Terraform thinks it owns.

---

## Out-of-cluster optional — with an in-cluster reverse proxy in the middle

**When to use:** you want a reverse proxy in the request path (for plugins, request rewriting, header manipulation, rate-limiting) in addition to ALB as the external entry point.

**Architecture (Option 1 — plain HTTP between ALB and the proxy):**
```
apps-cluster pod
     │ HTTPS (pcg-ca-bundle validates ACM cert)
     ▼
Route53 → pipeline-control-gateway.internal.newrelic
     ▼
ALB (443, ACM cert)     ← TLS terminates here
     │ HTTP :80 (Kong or NGINX; both default to port 80 in TLS-off mode)
     ▼
Reverse proxy Service (ClusterIP, in pcg-cluster)
     │ HTTP
     ▼
Gateway Service (:4318 OTLP HTTP, :4317 OTLP gRPC)
```

**Trust boundary:** ALB → proxy is unencrypted, but both live in the same VPC + same cluster + same namespace. Kubernetes CNI traffic is internal. TLS is only needed on the public-facing hop (client → ALB).

### Pick your reverse proxy

| | Kong | NGINX |
|---|---|---|
| **Backend port ALB targets** | `80` | `80` |
| **TLS-off flag** | `proxy_tls_enabled=false` | `nginx_tls_enabled=false` |
| **Backend Service name** | `pcg-kong-kong-proxy` | `pcg-nginx` |
| **Best for** | API-gateway features (plugins, rate-limit, transforms) | Simpler, lighter-weight reverse proxy |

### Apply order — 2 phases (set the tfvars first, then apply in sequence)

**Ordering constraint:** NGINX/Kong resolves the gateway upstream Service DNS at proxy startup. If the proxy starts before the gateway's Service exists, NGINX CrashLoopBackOffs with `host not found in upstream`. So Step 5 (gateway) MUST apply before Step 6 (proxy). No re-apply of Step 5 is needed — set `pcg_service_name` in tfvars up-front, and ALB Controller reconciles the target group automatically once Step 6 creates the Service (~30-60s).

1. Out-of-cluster Steps 1–4 as normal (VPC → EKS → ALB Controller → Route53 → Private CA).

2. **Set the layered-mode overrides in `aws/out-of-cluster-private-dns-pcg.tfvars` BEFORE Step 5.** Pick one:

   **For Kong:**
   ```hcl
   pcg_service_name     = "pcg-kong-kong-proxy"
   pcg_otlp_http_port   = 80
   pcg_nr_receiver_port = 80
   ```

   **For NGINX:**
   ```hcl
   pcg_service_name     = "pcg-nginx"
   pcg_otlp_http_port   = 80
   pcg_nr_receiver_port = 80
   ```

   > **Naming heads-up:** these are `pcg_service_name` / `pcg_otlp_http_port` / `pcg_nr_receiver_port` **only** because you're setting them for the `5-pcg/*` modules (they describe what ALB routes to — the layered proxy). Do NOT put the same values in the `3-ingress/reverse-proxy-within-cluster/*` modules — those modules use `pcg_upstream_*` port variables (describing what the proxy routes to — always the gateway) and default them correctly. Same tfvars file is fine because Terraform only reads the variables each module declares.

3. **Out-of-cluster Step 5: gateway install.** ALB Ingress is created with `backend = pcg-nginx` (or `pcg-kong-kong-proxy`) from the tfvars values above. The Service doesn't exist yet, so the ALB target group is temporarily empty — the ALB returns 503 until Step 6 finishes. This is expected.

   ```bash
   cd aws/5-pcg/flux
   terraform init
   terraform apply -var-file=../../out-of-cluster-private-dns-pcg.tfvars -var="pcg_values_file=./pcg-values.yaml"
   cd -
   # (or aws/5-pcg/fluxless with the two -var= flags for both values.yaml files)
   ```

4. **Out-of-cluster Step 6: install ONE reverse proxy on pcg-cluster with TLS disabled.** The proxy's config resolves `pipeline-control-gateway.newrelic.svc.cluster.local` at startup — the gateway Service exists (from Step 5), so this succeeds. Once the Service comes up, ALB Controller populates the target group and traffic starts flowing.

   **Kong:**
   ```bash
   cd aws/3-ingress/reverse-proxy-within-cluster/kong
   terraform workspace new pcg-cluster 2>/dev/null || terraform workspace select pcg-cluster
   terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars -var="proxy_tls_enabled=false"
   cd -
   ```

   **NGINX:**
   ```bash
   cd aws/3-ingress/reverse-proxy-within-cluster/nginx
   terraform workspace new pcg-cluster 2>/dev/null || terraform workspace select pcg-cluster
   terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars -var="nginx_tls_enabled=false"
   cd -
   ```

   The `*_tls_enabled=false` flag makes the proxy expose HTTP only (no port 443 in the Service). The proxy's own TLS Ingress is skipped because the ALB in front of it terminates TLS.

5. **Verify the ALB target group is healthy** (~30-60s after Step 6):
   ```bash
   kubectl get endpoints pcg-nginx -n newrelic          # or pcg-kong-kong-proxy
   kubectl describe ingress pcg-alb -n newrelic | grep -A1 Backends
   ```
   Expect real pod IPs in the endpoints output, no `services "pcg-nginx" not found` in the Ingress description.

6. Out-of-cluster Step 7 test — apps-cluster hits `https://pipeline-control-gateway.internal.newrelic`, which resolves through the private zone to the ALB, TLS-terminates on the ALB, forwards to the reverse proxy, which forwards to the gateway.

### About the TLS-toggle variables

- **Kong `proxy_tls_enabled`** — default `true` (intra-cluster). Set to `false` in ALB-fronted mode.
- **NGINX `nginx_tls_enabled`** — default `true` (intra-cluster). Set to `false` in ALB-fronted mode.

Both variables control the same thing: whether the proxy exposes port 443 and mounts `pcg-tls-secret`. No `main.tf` edits needed — pass the flag via `-var` or add to an out-of-cluster-specific tfvars section.

### Verification

```bash
# Proxy Service is Ready in pcg-cluster
# Use pcg-kong-kong-proxy for Kong, or pcg-nginx for NGINX
kubectl --context $CTX_PCG get svc -n newrelic pcg-nginx

# ALB Ingress backend is the proxy, not the gateway
kubectl --context $CTX_PCG describe ingress -n newrelic pcg-alb | grep -A2 Backend
# Expect: pcg-kong-kong-proxy:80  OR  pcg-nginx:80

# End-to-end (same script as out-of-cluster Step 7)
aws/tests/send-inventory-logs-out-of-cluster.sh
```

If Kong routes correctly to the gateway and the gateway accepts the OTLP payload, logs land in New Relic.

---

## Each module's README

Every module has its own `README.md` with details on inputs, outputs, and BYO patterns:

- [`3-ingress/README.md`](3-ingress/README.md) — external vs in-cluster ingress
- [`3-ingress/reverse-proxy-within-cluster/README.md`](3-ingress/reverse-proxy-within-cluster/README.md) — NGINX vs Kong choice
- [`4-dns-tls/README.md`](4-dns-tls/README.md) — cert-manager vs private vs public
- [`5-pcg/README.md`](5-pcg/README.md) — Flux vs Fluxless choice

## BYO (bring your own)

Every module supports "skip = BYO". If you already have a VPC, cluster, ingress controller, cert-manager, or DNS zone, don't apply the corresponding module — set 1–3 tfvars variables and downstream modules pick up your existing resources.

**Full skip matrix + minimal tfvars snippets** live in each module's README. Summary:

| Module | To skip, set in tfvars | Detail |
|---|---|---|
| `1-vpc/` | `vpc_id` + `subnet_ids` (recommended), or `vpc_name` for tag lookup | [1-vpc/README.md — BYO section](1-vpc/README.md#byo--reuse-an-existing-vpc) |
| `2-eks/` | `cluster_name` (data source resolves it) | [2-eks/README.md — BYO section](2-eks/README.md#byo--reuse-an-existing-eks-cluster) |
| `3-ingress/alb/` | Nothing — just skip; downstream uses `ingressClassName: alb` | [3-ingress/alb/README.md — BYO section](3-ingress/alb/README.md#byo--reuse-an-existing-aws-load-balancer-controller) |
| `3-ingress/reverse-proxy-within-cluster/nginx/` | Skip entirely (intra-cluster with your own ingress) OR set `nginx_tls_enabled = false` for out-of-cluster layered | [nginx/README.md — BYO section](3-ingress/reverse-proxy-within-cluster/nginx/README.md#byo--reuse-your-own-ingress--reverse-proxy) |
| `3-ingress/reverse-proxy-within-cluster/kong/` | Skip entirely OR set `proxy_tls_enabled = false` for out-of-cluster layered | [kong/README.md — BYO section](3-ingress/reverse-proxy-within-cluster/kong/README.md#byo--reuse-an-existing-kong-installation) |
| `4-dns-tls/cert-manager/4.1-installer/` | `issuer_name` + `ca_secret_name` + `ca_secret_namespace` | [4.1-installer/README.md — BYO section](4-dns-tls/cert-manager/4.1-installer/README.md#byo--reuse-an-existing-cert-manager) |
| `4-dns-tls/cert-manager/4.3-pcg-certificate/` | `tls_secret_name` | [4.3-pcg-certificate/README.md — BYO section](4-dns-tls/cert-manager/4.3-pcg-certificate/README.md#byo--reuse-an-existing-tls-cert-for-the-gateway) |
| `4-dns-tls/private/4.1-route53-private-zone/` | `route53_zone_id` + `pcg_hostname` | [4.1-route53-private-zone/README.md — BYO section](4-dns-tls/private/4.1-route53-private-zone/README.md#byo--reuse-an-existing-route53-private-zone) |
| `4-dns-tls/private/4.2-out-of-cluster-tls/` | `private_ca_arn` (still apply the module) | [4.2-out-of-cluster-tls/README.md — BYO section](4-dns-tls/private/4.2-out-of-cluster-tls/README.md#byo--reuse-an-existing-private-ca) |
| `5-pcg/flux/` | Can't skip — pick between `flux/` and `fluxless/` | [flux/README.md — BYO section](5-pcg/flux/README.md#byo--you-cant-skip-this-module) |
| `5-pcg/fluxless/` | Can't skip — pick between `flux/` and `fluxless/` | [fluxless/README.md — BYO section](5-pcg/fluxless/README.md#byo--you-cant-skip-this-module) |

Also see [`../docs/byo-infrastructure.md`](../docs/byo-infrastructure.md) for common BYO scenarios and prerequisites your existing infra must meet.

## Restricted-IAM accounts

Some AWS accounts don't grant `iam:CreateRole` to the default SSO role. `terraform apply` in `aws/2-eks/` will fail with `AccessDenied` unless you assume a delegated provisioning role first. The role name below is an example; use whatever your organization provides.

**Do the role assumption in your shell**, before `terraform apply`:

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/<your-provisioning-role> \
  --role-session-name $(date +%Y%m%d-%H%M%S) > response.json
export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId' response.json)
export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' response.json)
export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken' response.json)
```

Terraform reads the exported STS creds from your environment. **There is no `assume_role_arn` tfvars variable** — the shell approach is the only path.

If the provisioner role has its own permissions boundary that requires new roles to carry a boundary, set:
```hcl
permissions_boundary = "arn:aws:iam::<ACCOUNT_ID>:policy/<your-boundary-policy>"
```
in your tfvars. Full details in [`2-eks/README.md`](2-eks/README.md#iam-prerequisites--read-this-first-if-in-a-restricted-aws-account).

STS creds expire in ~1 hour. Re-run the assume-role block when you hit `ExpiredToken`.

## Secrets in Terraform state

Two secret values in this deployment land in `terraform.tfstate` in plaintext. This is a Terraform-level constraint, not a bug you can work around inside the modules.

**1. The New Relic ingest license key.** The `helm_release` resource in [`5-pcg/flux`](5-pcg/flux/) and [`5-pcg/fluxless`](5-pcg/fluxless/) inlines the entire `values.yaml` (which the New Relic install wizard writes with the license key embedded) into the resource's `values` attribute via `file(var.pcg_values_file)`. The Helm provider has no way to mark that attribute sensitive — the key ends up in state.

**2. The gateway server's TLS private key** (out-of-cluster pattern only). Generated by the `tls_private_key` resource in [`4-dns-tls/private/4.2-out-of-cluster-tls`](4-dns-tls/private/4.2-out-of-cluster-tls/) and stored in state next to its ACM Private CA-signed certificate. The `tls` provider has no `sensitive` attribute for this either.

**What to do about it**, in order of priority:

- **Never commit state.** `terraform.tfstate` and `terraform.tfstate.backup` are gitignored in this repo. Verify with `git check-ignore terraform.tfstate` before your first commit on a fork.
- **Use a remote backend with encryption + strict access controls.** S3 with `aes256` or KMS + a bucket policy scoped to the operators who need it. Terraform Cloud, HashiCorp's managed offering, and each cloud's equivalent all support this.
- **Rotate the license key if state was ever exposed.** Regenerate the key in the New Relic UI, update `values.yaml`, and re-apply.
- **For the TLS private key**, if it was ever exposed, rotate the entire gateway server cert. Destroy `4.2-out-of-cluster-tls` and re-apply — the module generates a fresh key and CSR, requests a new Private CA-signed cert.

The two `aws/tests/send-inventory-logs-*.sh` scripts create a short-lived Kubernetes Secret to source the license key into the test pod, then delete it in the exit trap — so it doesn't sit in Pod env vars visible to `kubectl describe`.

## What's not in this guide

- **Per-language agent CA-trust configuration** (`NODE_EXTRA_CA_CERTS`, `NEW_RELIC_CA_BUNDLE_PATH`, `SSL_CERT_FILE`, and equivalents). Mounting the CA bundle into a pod is covered in the pattern guides; the per-language variable names are not yet collected in one place.
- **The New Relic infrastructure agent.** The gateway runs without it, but the [Pipeline Control gateway quickstart](https://newrelic.com/instant-observability/pipeline-control-gateway) dashboard and alerts read host metrics that only the agent reports, so we recommend you install it on the gateway's cluster if it is not already there.

## References

- [`../docs/architecture.md`](../docs/architecture.md) — diagrams, component walkthrough, sizing, Flux vs Fluxless
- [`../docs/pattern-out-of-cluster.md`](../docs/pattern-out-of-cluster.md) — the out-of-cluster topology in depth
- [`../docs/pattern-intra-cluster.md`](../docs/pattern-intra-cluster.md) — the intra-cluster topology in depth
- [`../docs/tls-options.md`](../docs/tls-options.md) — decision tree for TLS paths (cert-manager, Private CA, public ACM, BYO)
- [`../docs/byo-infrastructure.md`](../docs/byo-infrastructure.md) — BYO skip matrix and prerequisites
- [`../docs/cost-guidance.md`](../docs/cost-guidance.md) — cost drivers per module and teardown reminders

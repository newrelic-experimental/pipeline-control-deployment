# 5-pcg/fluxless

Deploys Pipeline Control gateway in **Fluxless mode** — two Helm charts installed directly (no Flux, no cluster-admin RBAC).

**Sibling module:** [`5-pcg/flux/`](../flux/) does the same job via the `agent-control-bootstrap` chart in Flux mode. Same interface — same variables, same outputs, same out-of-cluster ingress support — pick whichever mode your gateway fleet uses, or for a new fleet, whichever suits how much of the gateway's lifecycle you want New Relic to manage.

## Two modes, one job

Your pipeline configuration arrives from the New Relic UI in both modes. What differs is who owns the gateway's infrastructure lifecycle.

| | 5-pcg/flux | 5-pcg/fluxless |
|---|---|---|
| Pipeline configuration from the New Relic UI | Yes | Yes |
| Replicas and CPU target | Managed for you from the New Relic UI | Yours, in `pcg-values.yaml` |
| Gateway version upgrades | New Relic rolls them out | Your deployment tooling rolls them out |
| RBAC required | cluster-admin (Flux requires it) | namespace-scoped only |
| Charts installed | 1 (`agent-control-bootstrap`) | 2 (`agent-control-deployment` + `pipeline-control-gateway`) |
| Installs Flux? | Yes (Flux then deploys the gateway) | No (Helm installs the gateway directly) |
| The gateway kind | Deployment (Flux-managed) | Deployment OR DaemonSet (via values.yaml) |

> **Scaling fields are seeded once in this mode.** The replica and CPU-target values you enter in the install wizard seed the HPA at install time only. Later changes in the New Relic UI do not reach the cluster, and those fields render read-only with a note that they are Helm-managed. Change them in `pcg-values.yaml` and re-apply.

## Which mode to use?

- **Fluxless (this module)** — use when you need namespace-scoped RBAC, the gateway is co-located with other workloads, or your change process requires you to own gateway upgrades. Works with either topology.
- **Flux (sibling module)** — use when you can grant cluster-admin and you want New Relic to manage the gateway's scaling and version for you. Works with either topology.

**Both modes work with all ingress options** (NGINX, Kong, ALB) and with both topologies. Both expose the ALB + Route53 alias flow via identical flags.

## BYO — you can't skip this module

The gateway itself is the workload this repo installs. Either this module OR the `flux/` sibling must run. See [`flux/README.md`](../flux/README.md) for the choose-between-modes matrix.

### Out-of-cluster layered mode — put an in-cluster proxy (NGINX or Kong) BETWEEN ALB and the gateway

If you're using this module with an external ALB AND an in-cluster NGINX/Kong proxy in the middle (the layered ALB+Kong and ALB+NGINX patterns), set these ALB backend overrides in `aws/out-of-cluster-private-dns-pcg.tfvars`:

```hcl
# For ALB → NGINX → gateway:
pcg_service_name    = "pcg-nginx"
pcg_otlp_http_port  = 80
pcg_nr_receiver_port = 80

# OR for ALB → Kong → gateway:
pcg_service_name    = "pcg-kong-kong-proxy"
pcg_otlp_http_port  = 80
pcg_nr_receiver_port = 80
```

Without these overrides, ALB points its backend directly at the gateway's Service (bypassing the in-cluster proxy).

## What it creates

**Both topologies:**
1. `newrelic` namespace (opt-out via `create_pcg_namespace = false`)
2. `helm_release.agent_control` — installs `newrelic/agent-control-deployment` chart with your `agent_control_values_file`
3. `time_sleep.wait_for_agent_control` — brief wait before installing gateway chart
4. `helm_release.pcg` — installs `newrelic/pipeline-control-gateway` chart with your `pcg_values_file`
5. `time_sleep.wait_for_pcg` — brief wait for pod readiness

**Out-of-cluster additions (when `create_alb_ingress = true`):**
6. `kubernetes_ingress_v1.pcg_alb` — ALB Ingress with ACM cert
7. `time_sleep.wait_for_alb` — wait for ALB provisioning
8. `aws_route53_record.pcg_alias` — Route53 A-alias to the ALB

## Prerequisites

- EKS cluster reachable via kubectl
- `agent-control-deployment-values.yaml` — from New Relic install wizard
- `pipeline-control-gateway-values.yaml` — from New Relic install wizard
- **Out-of-cluster**: `pcg-tls-secret` and ACM cert ARN from [`4.2-out-of-cluster-tls`](../../4-dns-tls/private/4.2-out-of-cluster-tls/); Route53 zone from [`4.1-route53-private-zone`](../../4-dns-tls/private/4.1-route53-private-zone/)
- **Intra-cluster**: `pcg-tls-secret` from [`4.3-pcg-certificate`](../../4-dns-tls/cert-manager/4.3-pcg-certificate/)

## Getting the values.yaml files

In New Relic UI: Pipeline Control → Add Gateway → follow the wizard. It will present TWO downloads for Fluxless mode:
- `agent-control-deployment-values.yaml` — Agent Control config
- `pipeline-control-gateway-values.yaml` — gateway chart config (this is where `kind: Deployment` vs `kind: DaemonSet` lives)

**Copy both into this module directory before running `terraform apply`** — Terraform reads them as file paths relative to the module dir. Treat them like credentials (they contain your ingest license key + Fleet Control identity).

```bash
cp /path/to/agent-control-deployment-values.yaml aws/5-pcg/fluxless/agent-control-values.yaml
cp /path/to/pipeline-control-gateway-values.yaml aws/5-pcg/fluxless/pcg-values.yaml
```

Any filenames work — the tfvars snippets below assume the two names above.

## Usage — intra-cluster (no ingress)

```hcl
# In your intra-cluster tfvars file (aws/intra-cluster.tfvars)
agent_control_values_file = "./agent-control-values.yaml"
pcg_values_file           = "./pcg-values.yaml"
# create_alb_ingress + create_route53_record left at default false
```

```bash
cd aws/5-pcg/fluxless
terraform init
terraform apply -var-file=../../intra-cluster.tfvars
```

## Usage — out-of-cluster (with ALB)

```hcl
# In out-of-cluster-private-dns-pcg.tfvars
agent_control_values_file = "./agent-control-values.yaml"
pcg_values_file           = "./pcg-values.yaml"

# Turn on out-of-cluster ingress
create_alb_ingress    = true
create_route53_record = true
pcg_hostname          = "pcg.internal.newrelic"
alb_scheme            = "internal"
route53_zone_id       = "Z0EXAMPLE1234567"  # from 4.1-route53-private-zone
acm_certificate_arn   = "arn:aws:acm:eu-west-1:.../certificate/xxx"  # from 4.2-out-of-cluster-tls
tls_secret_name       = "pcg-tls-secret"
```

```bash
cd aws/5-pcg/fluxless
terraform init
terraform apply -var-file=../../out-of-cluster-private-dns-pcg.tfvars
```

## Verify

```bash
# Both Helm releases installed
helm list -n newrelic

# Agent Control pods Running
kubectl get pods -n newrelic -l app.kubernetes.io/name=agent-control

# Gateway pods Running (Deployment or DaemonSet depending on your values.yaml)
kubectl get pods,svc -n newrelic -l app.kubernetes.io/name=pipeline-control-gateway
```

## Deployment vs DaemonSet

Whichever your `pipeline-control-gateway-values.yaml` says. Same Helm command either way. Intra-cluster:
- **Mode 1 (default)**: `kind: Deployment` — standard replicas + HPA
- **Mode 2**: `kind: DaemonSet` + `service.internalTrafficPolicy: Local` — one gateway pod per node, apps talk to their same-node pod. Requires K8s ≥ 1.26.

## Cost

Same as 5-pcg/flux. Helm releases plus optional AWS resources (an ALB when `create_alb_ingress=true`, and a Route53 record).

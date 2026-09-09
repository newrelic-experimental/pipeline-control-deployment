# 5-pcg/flux

Deploys Pipeline Control gateway via New Relic's public `agent-control-bootstrap` Helm chart in **Flux mode**. **Step 5** of the intra-cluster pattern.

**Sibling module:** [`5-pcg/fluxless/`](../fluxless/) does the same job via `agent-control-deployment` + `pipeline-control-gateway` charts directly (no Flux). Same interface — same variables, same outputs — pick whichever mode your gateway fleet uses, or for a new fleet, whichever suits how much of the gateway's lifecycle you want New Relic to manage.

Terraform runs the Helm install (equivalent to `helm upgrade --install agent-control-bootstrap -n newrelic-agent-control newrelic/agent-control-bootstrap --create-namespace --values ./pcg-values.yaml`) — you don't run the helm command yourself. Agent Control then deploys the gateway into the `newrelic` namespace via Flux, which it installs first and which needs cluster-admin RBAC. Because of that, this module needs cluster-admin in the target cluster; use the Fluxless module for namespace-scoped RBAC.

Step 5 runs **before** NGINX (Step 6). NGINX resolves the gateway service DNS at startup, so the gateway must exist first.

## What it creates

- `newrelic-agent-control` namespace (opt-out via `create_agent_control_namespace = false`)
- `agent-control-bootstrap` Helm release

**By default, this module does NOT create the `newrelic` namespace** — Step 4 ([`4.3-pcg-certificate`](../../4-dns-tls/cert-manager/4.3-pcg-certificate/)) already owns it (that's where the TLS Secret lives). If you're skipping Step 4 and no other module creates the namespace, set `create_pcg_namespace = true` to have this module create it instead.
- A 180-second `time_sleep` after the Helm install so Flux has time to create the gateway's Deployment and Service

After Terraform finishes, Flux (installed by Agent Control) creates the actual `pipeline-control-gateway` Deployment + Service in `newrelic` — you'll see the pods appear a minute or two after `terraform apply` completes.

## What it does NOT create

- **Any DNS or ingress setup** — apps reach the gateway through the NGINX/Kong ingress (Step 6) at that Service's Kubernetes-native DNS name. No CoreDNS patching or custom hostname setup needed anywhere.
- **CA bundle Secret** — that lives in [`4.3-pcg-certificate`](../../4-dns-tls/cert-manager/4.3-pcg-certificate/) (Step 4). Apps mount it from the `newrelic` namespace.

## BYO — you can't skip this module

The gateway itself is the workload this repo installs. You must run this module (or its sibling `../fluxless/`) unless you're bringing a pre-existing gateway install too — in which case, this reference architecture isn't what you need.

### Choosing between `flux/` (this module) and `fluxless/`

| Use `flux/` (this module) | Use `fluxless/` |
|---|---|
| You want New Relic to drive rollouts via Fleet Control | You want a direct Helm install with namespace-scoped RBAC |
| You have cluster-admin RBAC available | You do NOT have cluster-admin RBAC |
| You want the standard NR installation path | You need tighter operational isolation |

Both modules have the **identical interface** for out-of-cluster ingress (`create_alb_ingress`, `create_route53_record`, `pcg_hostname`, `tls_secret_name`, `acm_certificate_arn`, `alb_scheme`, `route53_zone_id`, `pcg_service_name`, `pcg_otlp_http_port`, `pcg_nr_receiver_port`).

### Out-of-cluster layered mode — put an in-cluster proxy (NGINX or Kong) BETWEEN ALB and the gateway

If you're using this module with an ALB out front AND an in-cluster NGINX/Kong proxy in the middle (the layered ALB+Kong and ALB+NGINX patterns), set these ALB backend overrides in `aws/out-of-cluster-private-dns-pcg.tfvars`:

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

## Prerequisites

- Steps 1–4 applied (VPC, EKS, cert-manager, gateway cert)
- **Gateway values.yaml** — generated in New Relic UI → Pipeline Control → Setup wizard. Save as `pcg-values.yaml` (or any path you pass via `pcg_values_file`).
- Terraform ≥ 1.0

### Getting the values.yaml

1. New Relic UI → **Pipeline Control** → **Setup**
2. Follow the install wizard
3. Download the generated `values.yaml`
4. Save it — treat it like a credential (contains your ingest license key + Fleet Control identity)

## Usage

```bash
cd aws/5-pcg/flux

# Copy your wizard-generated values into the module dir
cp /path/to/values-newrelic-gateway.yaml ./pcg-values.yaml

terraform init
terraform plan  -var-file=../../intra-cluster.tfvars \
                -var="pcg_values_file=./pcg-values.yaml"
terraform apply -var-file=../../intra-cluster.tfvars \
                -var="pcg_values_file=./pcg-values.yaml"
```

**Why `pcg_values_file` is a `-var` on the command line, not in the shared tfvars**: it's a per-module file path that Terraform resolves relative to the module directory. Doesn't belong in the shared root tfvars.

## Verify

```bash
# Agent Control installed
kubectl get pods -n newrelic-agent-control
helm list -n newrelic-agent-control

# The gateway deployed by Flux (1-2 min after apply finishes)
kubectl get pods -n newrelic
# Expect: pipeline-control-gateway-* pods Running

# The gateway Service (used by NGINX in Step 6)
kubectl get svc pipeline-control-gateway -n newrelic
# Ports: 80, 4317, 4318
```

Note: The gateway **does not** expose port 13133 on its cluster Service. NGINX's `/health` handler in Step 6 returns a static 200 from NGINX itself rather than proxying to the gateway's health port.

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| `cluster_name` | EKS cluster name | — | Yes |
| `aws_region` | AWS region | — | Yes |
| `pcg_values_file` | Path to the wizard-generated values.yaml | — | Yes |
| `pcg_wait_duration` | Sleep after helm to let Flux catch up | `"180s"` | No |
| `create_agent_control_namespace` | Create the Agent Control namespace | `true` | No |
| `create_pcg_namespace` | Create the `newrelic` namespace (usually unnecessary — Step 4 owns it) | `false` | No |
| `agent_control_namespace` | Agent Control namespace | `newrelic-agent-control` | No |
| `pcg_namespace` | gateway namespace | `newrelic` | No |

## Outputs

| Name | Description |
|---|---|
| `agent_control_namespace` | Namespace where Agent Control was deployed |
| `pcg_namespace` | Namespace where the gateway was deployed |

The user-facing outputs (`pcg_hostname`, `pcg_https_url`, `agent_config_example`) live in [`reverse-proxy-within-cluster/nginx`](../../3-ingress/reverse-proxy-within-cluster/nginx/) — that's the module that owns the ingress + DNS.

## Troubleshooting

**`pipeline-control-gateway` pods not appearing after `terraform apply` finishes** — Flux can take 2–3 min after Agent Control comes up. Check:
```bash
kubectl get helmrelease -n newrelic-agent-control
kubectl logs -n newrelic-agent-control -l app=agent-control
```

**`namespaces "newrelic" already exists`** — shouldn't happen with the current defaults (this module leaves the `newrelic` namespace alone by default; [`4.3-pcg-certificate`](../../4-dns-tls/cert-manager/4.3-pcg-certificate/) from Step 4 owns it). If you hit this, either (a) an old apply of this module put the namespace in state — remove it with `terraform state rm 'kubernetes_namespace_v1.pcg[0]'` and re-apply; or (b) you set `create_pcg_namespace = true` — set it back to `false`.

**Helm timeout on install** (`failed post-install: timed out waiting for the condition`) — reads like "the cluster is slow, wait longer." Usually wrong. `agent-control-bootstrap` runs a pre-install hook Job; the real failure fires inside that Job seconds after apply starts, but Terraform doesn't surface it until the outer 600s timeout expires. Before assuming a capacity or network-speed problem:
```bash
# Look for a failed hook Job or a non-Running pod.
kubectl get all -n newrelic-agent-control
kubectl logs -n newrelic-agent-control <pod-name>   # for anything not 1/1 Running
```
Typical hook failures: RBAC misconfiguration, IRSA misconfigured for the ServiceAccount, image-pull denied, or a target namespace already holds a conflicting resource. Fix the underlying problem in values.yaml or IAM setup, then re-apply. Only if the hooks all succeeded and the timeout truly fired on chart-level readiness (pods never went `1/1 Running`) is "re-run apply" or "investigate node pull performance" the right response.

## Cleanup

```bash
terraform destroy -var-file=../../intra-cluster.tfvars \
                  -var="pcg_values_file=./pcg-values.yaml"
```

Removes Agent Control (which cascades → removes the gateway via Flux) and the two namespaces (if this module created them).

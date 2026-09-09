# reverse-proxy-within-cluster/nginx

Deploys a custom NGINX reverse proxy in front of the gateway. **Step 6** (final step) of the intra-cluster pattern.

Step 6 comes **after** the gateway (Step 5) — NGINX resolves the gateway backend at boot, so the gateway has to exist first or NGINX CrashLoops.

## What it creates

**NGINX** in the `newrelic` namespace (default 2 replicas, `nginx:1.25-alpine`):
- Deployment + Service + ConfigMap holding the nginx.conf
- Listens on **80** (HTTP), **443** (HTTPS, TLS terminated using Step 4's cert), **4317** (OTLP gRPC via HTTP/2)
- Routes by path — see below

## BYO — reuse your own ingress / reverse proxy

**Skip this module entirely** if you have your own reverse proxy in front of the gateway. Nothing downstream consumes this module's outputs.

No tfvars to set — you're just not applying this module.

### Out-of-cluster layered mode — you DO want to apply this module, in ALB-fronted mode

If you're using this NGINX **inside** the cluster with an external ALB in front of it (the layered out-of-cluster pattern), don't skip — set this in `aws/out-of-cluster-private-dns-pcg.tfvars`:

```hcl
nginx_tls_enabled = false    # NGINX listens on HTTP :80 only; ALB terminates TLS
```

Then in `5-pcg/*` tfvars, point ALB backend at this NGINX Service (see [`5-pcg/flux/README.md`](../../../5-pcg/flux/README.md) BYO section).

### What your BYO ingress must do (intra-cluster)

| Requirement | Detail |
|---|---|
| Reachable via a K8s Service inside the cluster | Apps hit it by `<service>.<namespace>.svc.cluster.local` |
| TLS terminates at your proxy | Using the cert from `pcg-tls-secret` (created by [`4-dns-tls/cert-manager/4.3-pcg-certificate`](../../../4-dns-tls/cert-manager/4.3-pcg-certificate/)) |
| Route OTLP + NR proprietary paths | `/v1/traces`, `/v1/metrics`, `/v1/logs` → gateway:4318; `/metric/v1`, `/v1/accounts/events`, `/agent_listener` → gateway:80; `/` → gateway:80 |
| Cert SAN covers the hostname apps use | Otherwise agents get x509 name-mismatch errors |

## How apps reach NGINX

Apps use the Kubernetes-native Service DNS name: **`pcg-nginx.newrelic.svc.cluster.local`** (or the short form `pcg-nginx` from within the `newrelic` namespace). Kubernetes' built-in DNS resolves this automatically — no CoreDNS patching, no custom hostname setup.

The TLS certificate from [`4.3-pcg-certificate`](../../../4-dns-tls/cert-manager/4.3-pcg-certificate/) (Step 4) already covers this Service DNS name, so TLS handshakes verify cleanly against the k8s-native name.

**Previous versions of this module patched CoreDNS** to enable a friendlier hostname (`pcg.newrelic.internal`). That approach had a destroy-safety bug — `terraform destroy` left the coredns ConfigMap in a broken state, breaking cluster-wide DNS. Removed in favor of the k8s Service DNS approach, which needs no cluster-wide DNS changes at all.

## NGINX routing

**Port 80 / 443 (HTTP/HTTPS):**

| Path | Backend port | Purpose |
|---|---|---|
| `/health` | (returns 200 from NGINX itself) | Liveness/readiness probe |
| `/v1/traces`, `/v1/metrics`, `/v1/logs` | gateway 4318 | OTLP HTTP |
| `/metric/v1`, `/v1/accounts/events`, `/agent_listener` | gateway 80 | NR proprietary agent traffic |
| `/` (default) | gateway 80 | Catch-all → NR proprietary |

**Port 4317 (OTLP gRPC):** all traffic → gateway 4317 via `grpc_pass`

The `/health` location returns a static 200 from NGINX so kubelet's probe stays green even if the gateway is degraded (probes only tell us NGINX is up, not the full backend). the gateway's own health port (13133) isn't exposed via its Service, so proxying `/health` there would deadlock.

## Prerequisites

- Steps 1–5 applied (VPC, EKS, cert-manager, gateway cert, the gateway itself)
- The TLS Secret from Step 4 (`pcg-tls-secret` by default) exists in the `newrelic` namespace
- The gateway Service (`pipeline-control-gateway`) exists — Step 5 creates it
- Terraform ≥ 1.0

## Usage

```bash
cd aws/3-ingress/reverse-proxy-within-cluster/nginx
terraform init
terraform plan  -var-file=../../../intra-cluster.tfvars
terraform apply -var-file=../../../intra-cluster.tfvars
```

## Verify

```bash
# 2 NGINX pods Running (not CrashLoopBackOff)
kubectl get pods -n newrelic -l app.kubernetes.io/name=pcg-nginx

# Service has a ClusterIP
kubectl get svc pcg-nginx -n newrelic

# DNS resolves via k8s-native service DNS
kubectl run dnstest --rm -it --restart=Never --image=busybox -- \
  nslookup pcg-nginx.newrelic.svc.cluster.local

# End-to-end health check
kubectl run curltest --rm -it --restart=Never --image=curlimages/curl -- \
  curl -kv https://pcg-nginx.newrelic.svc.cluster.local/health
```

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| `cluster_name` | EKS cluster name | — | Yes |
| `aws_region` | AWS region | — | Yes |
| `namespace` | NGINX namespace | `newrelic` | No |
| `service_name` | NGINX Service name | `pcg-nginx` | No |
| `tls_secret_name` | TLS Secret to mount at `/etc/nginx/certs/` | `pcg-tls-secret` | No |
| `pcg_hostname` | Hostname apps use (nginx.conf `server_name`) | `pcg-nginx.newrelic.svc.cluster.local` | No |
| `pcg_namespace` | Namespace where the gateway lives | `newrelic` | No |
| `replicas` | NGINX replica count | `2` | No |
| `nginx_image` | Image | `nginx:1.25-alpine` | No |
| `pcg_upstream_service_name` | gateway Service name NGINX routes to. Composed with `pcg_namespace` into the in-cluster FQDN. | `pipeline-control-gateway` | No |
| `pcg_upstream_otlp_http_port`, `pcg_upstream_otlp_grpc_port`, `pcg_upstream_nr_receiver_port` | gateway backend ports NGINX routes to. Named `pcg_upstream_*` to avoid colliding with the same-named variables in `5-pcg/*`, which mean the opposite (ALB → NGINX ports, not NGINX → gateway ports). | 4318 / 4317 / 80 | No |
| `pcg_health_port` | gateway health probe port (unchanged) | 13133 | No |

## Outputs

| Name | Description |
|---|---|
| `service_name`, `service_namespace`, `cluster_ip` | NGINX Service identity |
| `http_endpoint`, `https_endpoint`, `grpc_endpoint` | In-cluster URLs |
| `pcg_hostname`, `pcg_https_url`, `pcg_grpc_endpoint` | Hostname/URLs apps use to reach the gateway |
| `agent_config_example` | Example env vars for NR-agent-instrumented pods |

## Troubleshooting

**NGINX pods CrashLoopBackOff with `[emerg] host not found in upstream`** → gateway hasn't been deployed yet. NGINX resolves the upstream at startup, not per-request. Run Step 5 first.

**NGINX pods CrashLoopBackOff with `mkdir() "/var/cache/nginx/..." failed (Read-only file system)`** → the pod's `read_only_root_filesystem = true` needs a writable `/var/cache/nginx` volume. The module already mounts an emptyDir there; if you see this, the deployment spec is out of sync — re-apply.

**Curl gets `Could not resolve host: pcg-nginx.newrelic.svc.cluster.local`** → your curl pod isn't using the cluster's DNS. When running `kubectl run` for a test pod, k8s configures the pod to use CoreDNS by default; if you're testing from a pod with custom DNS config, verify it resolves the cluster's `.svc.cluster.local` domain.

**Curl gets `HTTP 502`** → gateway is down or its Service is misnamed. `kubectl get svc pipeline-control-gateway -n newrelic` should show a ClusterIP with ports 80, 4317, 4318.

**Curl gets TLS error `x509: certificate is not valid for any names`** → the cert doesn't cover the hostname you're using. Confirm you're using `pcg-nginx.newrelic.svc.cluster.local` (or a short form the cert covers), not `pcg.newrelic.internal` (legacy) or an IP.

## Cleanup

```bash
terraform destroy -var-file=../../../intra-cluster.tfvars
```

Removes the NGINX Deployment/Service/ConfigMap. Apps in the cluster will lose gateway connectivity. No cluster-wide side effects (unlike previous versions of this module that touched CoreDNS).

# 3-ingress/reverse-proxy-within-cluster/kong

Intra-cluster Kong ingress as an **alternative** to [`reverse-proxy-within-cluster/nginx`](../nginx/). **Step 6** of the intra-cluster pattern. Mutually exclusive with the NGINX module — use one, not both.

## Why use Kong instead of custom NGINX?

- Your org already standardizes on Kong operationally
- You want Kong plugins for auth, rate limiting, or request transformation on top of the gateway's own filtering
- Intra-cluster gateway is what you need, but you specifically want Kong

If none of the above applies, use [`reverse-proxy-within-cluster/nginx`](../nginx/) instead.

## What it creates

- Kong Helm release in the `newrelic` namespace (DB-less, ClusterIP, no external LB)
- Two `Ingress` resources on `IngressClass=kong`:
  - **HTTP/HTTPS** for OTLP HTTP paths (`/v1/traces|metrics|logs`), NR proprietary paths (`/metric/v1`, `/v1/accounts/events`, `/agent_listener`), and a `/` catch-all → gateway's NR-proprietary receiver on port 80
  - **gRPC** with `konghq.com/protocols: grpc,grpcs` annotation → gateway's OTLP gRPC receiver on port 4317

## BYO — reuse an existing Kong installation

**Skip this module entirely** if your cluster already has Kong. Nothing downstream consumes this module's outputs.

No tfvars to set — just don't apply this module. Instead, create Ingress resources against your existing Kong with `ingressClassName: kong`, routing the paths listed under "Routing" below to the gateway.

### Out-of-cluster layered mode — apply this module in ALB-fronted mode

If you're using this Kong **inside** the cluster with an external ALB in front (the layered out-of-cluster pattern), don't skip. Set in `aws/out-of-cluster-private-dns-pcg.tfvars`:

```hcl
proxy_tls_enabled = false    # Kong proxy listens on HTTP :8000 only; ALB terminates TLS
```

Then in `5-pcg/*` tfvars, point ALB backend at this Kong Service (see [`5-pcg/flux/README.md`](../../../5-pcg/flux/README.md) BYO section).

### What your existing Kong must have (intra-cluster pure-Kong)

| Requirement | Detail |
|---|---|
| Kong Ingress Controller (v2.9+) | Older versions may not recognize the annotations |
| Kong CRDs installed | `KongIngress`, `KongPlugin`, etc. |
| IngressClass `kong` registered | Verify: `kubectl get ingressclass` |
| Kong proxy Service reachable in-cluster | Apps hit it directly |
| Cert whose SAN covers the Kong proxy Service DNS name | From [`4.3-pcg-certificate`](../../../4-dns-tls/cert-manager/4.3-pcg-certificate/) (Step 4) or your own PKI |

## How apps reach Kong

Apps use the Kubernetes-native Service DNS name: **`pcg-kong-kong-proxy.newrelic.svc.cluster.local`** (default; the Kong Helm chart names its proxy Service `<release_name>-kong-proxy`, and the default `release_name` here is `pcg-kong`). Kubernetes' built-in DNS resolves this automatically — no CoreDNS trickery.

The TLS certificate from [`4.3-pcg-certificate`](../../../4-dns-tls/cert-manager/4.3-pcg-certificate/) (Step 4) includes this name in its SANs (via the `kong_service_name` variable defaulting to `pcg-kong-kong-proxy`), so TLS handshakes verify cleanly. If you override `release_name` here, update `kong_service_name` in [`4.3-pcg-certificate`](../../../4-dns-tls/cert-manager/4.3-pcg-certificate/) too.

**Previous versions of this module patched CoreDNS** to enable a friendlier hostname. Removed — same destroy-safety issue as [`reverse-proxy-within-cluster/nginx`](../nginx/) used to have. See the guide's Step 6 for context.

## Routing (matches reverse-proxy-within-cluster/nginx)

| Path / Protocol | Backend port | Purpose |
|---|---|---|
| `/v1/traces`, `/v1/metrics`, `/v1/logs` | gateway 4318 | OTLP HTTP |
| `/metric/v1`, `/v1/accounts/events`, `/agent_listener` | gateway 80 | NR proprietary agent traffic |
| `/` (catch-all) | gateway 80 | NR proprietary default |
| gRPC (protocols: grpc,grpcs) | gateway 4317 | OTLP gRPC |

Apps connect to `https://pcg-kong-kong-proxy.newrelic.svc.cluster.local` — Kong terminates TLS on port 443 and routes internally.

## Prerequisites

- Steps 1–5 applied (VPC, EKS, cert-manager, gateway cert + TLS Secret, the gateway itself)
- The TLS Secret from Step 4 (`pcg-tls-secret` by default) exists in the `newrelic` namespace
- The gateway Service (`pipeline-control-gateway`) exists in `newrelic` — Step 5 creates it via Flux
- **[`reverse-proxy-within-cluster/nginx`](../nginx/) is NOT applied** (both modules would try to own the same TLS Secret and expose overlapping paths — use one, not both)

## Usage

```bash
cd aws/3-ingress/reverse-proxy-within-cluster/kong
terraform init
terraform plan  -var-file=../../../intra-cluster.tfvars
terraform apply -var-file=../../../intra-cluster.tfvars
```

## Verify

```bash
# Kong pods Running
kubectl get pods -n newrelic -l app.kubernetes.io/name=kong

# Kong proxy Service has a ClusterIP
kubectl get svc pcg-kong-kong-proxy -n newrelic

# Ingress resources registered with Kong
kubectl get ingress -n newrelic

# DNS resolves via k8s-native service DNS
kubectl run dnstest --rm -it --restart=Never --image=busybox -- \
  nslookup pcg-kong-kong-proxy.newrelic.svc.cluster.local

# End-to-end HTTPS
kubectl run curltest --rm -it --restart=Never --image=curlimages/curl -- \
  curl -kv https://pcg-kong-kong-proxy.newrelic.svc.cluster.local/health
```

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| `cluster_name` | EKS cluster name | — | Yes (via shared tfvars) |
| `aws_region` | AWS region | — | Yes |
| `namespace` | Namespace to install Kong into | `newrelic` | No |
| `release_name` | Helm release name | `pcg-kong` | No |
| `kong_chart_version` | Kong Helm chart version | `2.38.0` | No |
| `kong_image_tag` | Kong image tag | `3.7` | No |
| `replicas` | Kong proxy replica count | `2` | No |
| `tls_secret_name` | TLS Secret to terminate against | `pcg-tls-secret` | No |
| `pcg_hostname` | Hostname apps use (k8s Service DNS name of the Kong proxy) | `pcg-kong-kong-proxy.newrelic.svc.cluster.local` | No |
| `pcg_namespace` | Namespace where the gateway lives | `newrelic` | No |
| `pcg_upstream_service_name` | Service that Kong's K8s Ingress routes to (default: the gateway's Service). Named `pcg_upstream_*` to avoid colliding with the same-named variable in `5-pcg/*`, which means the opposite thing (ALB → proxy, rather than proxy → gateway). | `pipeline-control-gateway` | No |
| `pcg_upstream_otlp_http_port` / `pcg_upstream_otlp_grpc_port` / `pcg_upstream_nr_receiver_port` | gateway backend ports Kong routes to | 4318 / 4317 / 80 | No |

## Outputs

| Name | Description |
|---|---|
| `namespace`, `release_name`, `ingress_class` | Kong install identity |
| `proxy_service_name` | Kong proxy Service name (build the k8s DNS name from this + namespace) |
| `pcg_hostname`, `pcg_https_url`, `pcg_grpc_endpoint` | Hostname/URLs apps use to reach the gateway via Kong |
| `agent_config_example` | Ready-to-paste env vars for NR-agent pods |

## Known limitations

- **Mutually exclusive with [`reverse-proxy-within-cluster/nginx`](../nginx/).** Both modules issue Ingress resources against the same TLS Secret and would fight over routing paths. Pick one.
- **gRPC routing** currently sends all gRPC on port 443 (with `grpcs` protocol) to the gateway's OTLP gRPC receiver. If you have non-OTLP gRPC clients that need to reach a different port on the gateway, they'll need a separate Ingress rule.
- **`release_name` and cert coverage are coupled.** If you override `release_name` (which changes the Kong proxy Service name), update `kong_service_name` in [`4.3-pcg-certificate`](../../../4-dns-tls/cert-manager/4.3-pcg-certificate/) too or you'll get TLS name-mismatch errors.

## About the vendored CRDs

You'll find a `kong-crds.yaml` file in this module — ~3000 lines of Kong CRD definitions vendored from the Kong Helm chart repo (at the tag matching `kong_chart_version`). The module applies this file directly via `kubernetes_manifest`, entirely outside Helm.

**Why:** Kong's Helm chart installs CRDs through a pre-install hook that does NOT attach Helm ownership labels. Helm's post-install ownership check then rejects the CRDs it just created, and the first `terraform apply` fails with:

```
invalid ownership metadata; label validation error:
missing key "app.kubernetes.io/managed-by": must be set to "Helm"
```

We tried a dedicated CRD-only Helm release (thinking a normal Helm install would stamp labels correctly) — but the hook behavior is per-chart, not per-release, so the second-release approach fails identically.

The working fix is to bypass Helm entirely for CRDs: apply the CRD YAML directly with `kubernetes_manifest`, then run the main Kong Helm release with `installCRDs=false` so it references the already-existing CRDs. Terraform owns the CRDs cleanly; Helm owns everything else. First `terraform apply` succeeds first-try.

**Bumping `kong_chart_version`:** re-download the CRDs from the matching chart tag. One-liner:

```bash
curl -sf "https://raw.githubusercontent.com/Kong/charts/kong-<NEW_VERSION>/charts/kong/crds/custom-resource-definitions.yaml" \
  -o aws/3-ingress/reverse-proxy-within-cluster/kong/kong-crds.yaml
```

This is a workaround for a design disagreement between Kong (CRDs are cluster infrastructure, no single release should own them) and Helm (releases own everything they create). Documented in Kong's GitHub issues; won't be fixed upstream in the near term.

## Troubleshooting

**Kong pods CrashLoopBackOff with cert mount errors** — TLS Secret is missing or malformed. `kubectl get secret pcg-tls-secret -n newrelic`.

**Ingress not reachable / Kong not picking up config** — check the ingress controller sidecar logs: `kubectl logs -n newrelic -l app.kubernetes.io/name=kong -c ingress-controller`.

**Curl gets TLS error `x509: certificate is not valid for any names`** — the cert doesn't cover the hostname you're using. Confirm you're using `pcg-kong-kong-proxy.newrelic.svc.cluster.local` (or match `kong_service_name` in [`4.3-pcg-certificate`](../../../4-dns-tls/cert-manager/4.3-pcg-certificate/) if you changed the Kong release_name).

**gRPC clients get connection reset** — Kong's OTLP gRPC path handling depends on the ALPN handshake succeeding. Verify TLS cert covers the hostname, and the client is sending SNI.

## Cleanup

```bash
terraform destroy -var-file=../../../intra-cluster.tfvars
```

Removes the Kong Helm release + Ingress resources. No cluster-wide side effects.

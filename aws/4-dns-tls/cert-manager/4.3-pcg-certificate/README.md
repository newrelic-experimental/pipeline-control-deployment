# 4-dns-tls/cert-manager/4.3-pcg-certificate

Creates a TLS certificate for Pipeline Control gateway signed by the internal CA from Step 3, plus a Secret of the CA cert for app pods to trust. **Step 4** of the intra-cluster pattern.

## What it creates

- `newrelic` namespace (opt-out via `create_namespace = false`)
- `pcg-tls` `Certificate` covering the Kubernetes Service DNS names apps use to reach the gateway (see SAN list below), signed by `internal-ca-issuer` from Step 3
- The `Certificate` resource **waits** for cert-manager to report `Ready=True` before Terraform continues — 5-minute timeout, no race with Step 5/6
- `pcg-tls-secret` (created by cert-manager, populated with `tls.crt` + `tls.key`) — Step 6's NGINX mounts this to terminate TLS
- `pcg-ca-bundle` Secret (type Opaque, keys `ca.crt` + `pcg-ca.pem`) in `newrelic` — a copy of the CA cert from Step 3, so app pods can mount it and trust the gateway. Matches the shape of the out-of-cluster module's CA Secret, so apps mount it the same way either way.

## Why the module waits explicitly

Prior versions used a fixed `time_sleep = 15s` before reading the CA secret. On a slow cluster the cert wouldn't be issued yet and the read would fail. We now use `kubernetes_manifest` with a `wait { condition { type = "Ready" status = "True" } }` block — polls the API server, no race.

## When to use

| Scenario | Use? |
|---|---|
| You have cert-manager + a ClusterIssuer | ✅ |
| You want automated cert renewal | ✅ (renews 30 days before expiry) |
| You already have TLS certs for the gateway | ❌ Skip; see BYO below |

## BYO — reuse an existing TLS cert for the gateway

**Skip this module entirely** if you already have a TLS cert for the gateway (corporate PKI, another cert-manager setup, or manually-provisioned).

Set this in `aws/intra-cluster.tfvars` (downstream `3-ingress/*` modules read it):

```hcl
tls_secret_name = "my-existing-pcg-tls-secret"    # your kubernetes.io/tls Secret in the newrelic namespace
```

### What your existing Secret must have

| Requirement | Detail |
|---|---|
| Secret type `kubernetes.io/tls` in the `newrelic` namespace | With keys `tls.crt` + `tls.key` |
| Cert SANs cover the Service DNS names apps use | `pcg-nginx.newrelic.svc.cluster.local` (NGINX), `pcg-kong-kong-proxy.newrelic.svc.cluster.local` (Kong), or your custom Service DNS |
| CA cert available for apps to trust (recommended) | A Secret with `ca.crt` — mounted into app pods at `/etc/ssl/certs/pcg-ca.crt`. Otherwise apps must use `--insecure` |
| You own expiry/renewal | This module's auto-renewal (30 days before expiry) doesn't apply |

## Prerequisites

- cert-manager + a `ClusterIssuer` (from Step 3 or existing)
- Terraform ≥ 1.0

## Usage

```bash
cd aws/4-dns-tls/cert-manager/4.3-pcg-certificate
terraform init
terraform plan  -var-file=../../../intra-cluster.tfvars
terraform apply -var-file=../../../intra-cluster.tfvars
```

## Verify

```bash
# Certificate Ready
kubectl get certificate -n newrelic
kubectl describe certificate pcg-tls -n newrelic | grep -A5 Status

# TLS Secret has both keys
kubectl get secret pcg-tls-secret -n newrelic -o jsonpath='{.data}' \
  | tr ',' '\n' | grep -o '"tls\.[a-z]*"'

# CA bundle Secret
kubectl get secret pcg-ca-bundle -n newrelic
```

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| `cluster_name` | EKS cluster name | — | Yes |
| `aws_region` | AWS region | — | Yes |
| `issuer_name` | ClusterIssuer/Issuer to sign with | `internal-ca-issuer` | No |
| `issuer_kind` | `ClusterIssuer` or `Issuer` | `ClusterIssuer` | No |
| `certificate_name` | Certificate resource name | `pcg-tls` | No |
| `secret_name` | TLS secret name | `pcg-tls-secret` | No |
| `certificate_duration` | Cert lifetime | `8760h` (1 year) | No |
| `certificate_renew_before` | Renew this early before expiry | `720h` (30 days) | No |
| `internal_domain` | Legacy — used to build `pcg_fqdn` for BYO scenarios where a customer wires their own DNS. Not needed for the standard intra-cluster path. | `newrelic.internal` | No |
| `pcg_subdomain` | Legacy — see `internal_domain`. | `pcg` | No |
| `additional_dns_names` | Extra SANs for the cert | `[]` | No |
| `pcg_namespace` | Namespace where cert lives | `newrelic` | No |
| `create_namespace` | Create gateway namespace if not exists | `true` | No |
| `nginx_namespace` | Namespace of the NGINX/Kong Service (for SAN generation) | `newrelic` | No |
| `nginx_service_name` | NGINX Service name (for SAN generation) | `pcg-nginx` | No |
| `kong_service_name` | Kong proxy Service name (for SAN generation, if using Kong instead of NGINX) | `pcg-kong-kong-proxy` | No |
| `ca_secret_name` | CA secret to read for the CA-bundle Secret. Empty = skip. | `internal-ca-secret` | No |
| `ca_secret_namespace` | Namespace of the CA secret | `cert-manager` | No |

## Outputs

| Name | Description | Consumer |
|---|---|---|
| `tls_secret_name` | Name of the TLS Secret | → `reverse-proxy-within-cluster/nginx.tls_secret_name` |
| `tls_secret_namespace` | Namespace of the TLS Secret | Reference |
| `pcg_fqdn` | Legacy — `pcg.newrelic.internal` by default; only relevant for BYO DNS scenarios | Reference |
| `ca_bundle_secret` | Name of the CA-bundle Secret for app trust | App pod volume mounts |
| `dns_names` | Full list of SANs on the cert | Reference |

## DNS names on the cert

Default SAN list — covers all the ways apps might reach the gateway in the intra-cluster pattern:

| DNS name | Purpose |
|---|---|
| `pipeline-control-gateway`, `pipeline-control-gateway.newrelic`, `.svc`, `.svc.cluster.local` | gateway service DNS (direct-to-gateway, bypassing any ingress) |
| `pcg-nginx`, `pcg-nginx.newrelic.svc.cluster.local` | NGINX service DNS ([`reverse-proxy-within-cluster/nginx`](../../../3-ingress/reverse-proxy-within-cluster/nginx/)) |
| `pcg-kong-kong-proxy`, `pcg-kong-kong-proxy.newrelic.svc.cluster.local` | Kong proxy service DNS ([`reverse-proxy-within-cluster/kong`](../../../3-ingress/reverse-proxy-within-cluster/kong/)) |
| `pcg.newrelic.internal`, `pcg` | Legacy names, kept for backward compat / BYO-DNS scenarios |

Add more via `additional_dns_names = ["extra.example"]`.

## Next step

Step 5: [`5-pcg/flux`](../../../5-pcg/flux/) — deploys the gateway itself via Agent Control. Order matters: The gateway **before** NGINX (Step 6) so NGINX's upstream DNS resolves on first boot.

## Troubleshooting

**Apply hangs at "Still creating..."** — cert-manager is slow. `kubectl get certificaterequest -n newrelic` shows progress; `kubectl logs -n cert-manager -l app=cert-manager` shows errors.

**Namespace already exists** — should not happen with current defaults: this module owns the `newrelic` namespace, and Step 5 ([`5-pcg/flux`](../../../5-pcg/flux/)) leaves it alone (`create_pcg_namespace = false` by default). If you do hit the error, either (a) an old apply of [`5-pcg/flux`](../../../5-pcg/flux/) put the namespace in that module's state — remove it there with `terraform state rm 'kubernetes_namespace_v1.pcg[0]'`; or (b) you flipped `create_pcg_namespace = true` in Step 5's tfvars — set it back to `false`.

## Cleanup

```bash
terraform destroy -var-file=../../../intra-cluster.tfvars
```

Removes the Certificate, the TLS Secret, and the CA-bundle Secret. Apps mounting the CA bundle will lose the CA cert.

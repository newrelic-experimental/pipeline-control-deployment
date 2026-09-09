# 4.2-out-of-cluster-tls

**out-of-cluster** — issues a gateway server cert from an AWS Private CA, and distributes the CA root so senders outside the gateway's cluster can trust it. As written it writes that root into a second EKS cluster; senders elsewhere need the same root delivered by whatever mechanism suits them.

> ⚠️ **AWS Private CA bills a flat monthly rate whether idle or busy** ([pricing](https://aws.amazon.com/private-ca/pricing/)). This module creates one by default. Destroy when not actively testing.

## What it does

1. Creates an AWS ACM Private CA (or reuses an existing one via `private_ca_arn`)
2. Generates an RSA private key + CSR for the gateway hostname (default `pcg.internal.newrelic`)
3. Issues a server cert from the CA (~13-month validity)
4. Writes the server cert + key as a K8s Secret in **pcg-cluster** (`newrelic` namespace) — the ALB Ingress consumes this
5. Writes the CA root cert as a K8s Secret in **apps-cluster** (`default` namespace) — your app pods consume this via init container

## BYO — reuse an existing Private CA

**You still apply this module** (it does the cert issuance + out-of-cluster Secret distribution), but tell it to reuse your existing CA instead of creating a new one. Set in `aws/out-of-cluster-private-dns-pcg.tfvars`:

```hcl
private_ca_arn = "arn:aws:acm-pca:eu-west-1:123456789012:certificate-authority/xxx-xxx"
```

This is the recommended path for anyone who already runs an AWS Private CA: you drop the flat monthly CA charge and pay only the per-certificate issuance fee.

### What your existing CA must have

| Requirement | Detail |
|---|---|
| ACM Private CA in the same AWS region as the clusters | Cross-region CA usage not supported by this module |
| CA in ACTIVE state | Verify: `aws acm-pca describe-certificate-authority --certificate-authority-arn <arn>` |
| IAM permission to issue certs from that CA | `acm-pca:IssueCertificate`, `acm-pca:GetCertificate` |

### Alternative BYO — skip the module entirely

If you're bringing your own gateway server cert AND CA bundle as pre-made K8s Secrets (e.g., issued by your corporate PKI), skip this module and instead:

1. Create your `pcg-tls-secret` (`kubernetes.io/tls`) manually in pcg-cluster:newrelic
2. Create your `pcg-ca-bundle` (Opaque with `ca.crt`) manually in apps-cluster:default
3. Downstream `5-pcg/*` modules read secret names from `tls_secret_name` + `apps_ca_bundle_secret_name` in tfvars

## Why out-of-cluster?

Trust manager, cert-manager, and every other in-cluster CA distribution mechanism works within **one** cluster. The gateway in cluster A and apps in cluster B can't share trust without an out-of-cluster CA + external distribution — which is what this module does.

The distribution mechanism is Terraform itself: two `kubernetes` provider aliases (one per cluster) write the two halves of the trust story.

## Novel patterns in this module

Three patterns don't exist anywhere else in the repo:

- **Two Kubernetes provider aliases** — see `providers.tf`. Every other module targets one cluster.
- **`resource "kubernetes_secret_v1"`** — first Secret-write in the repo. Every other module reads Secrets, doesn't create them.
- **ACM Private CA lifecycle (activation dance)** — a Private CA needs `aws_acmpca_certificate_authority` → `aws_acmpca_certificate.root` (self-sign) → `aws_acmpca_certificate_authority_certificate` (import) to become ACTIVE.

## Where it fits in the out-of-cluster pattern

```
3-ingress/alb              ALB Controller Helm chart on pcg-cluster
4.1-route53-private-zone   private hosted zone for your internal domain
4.2-out-of-cluster-tls     ← THIS MODULE: Private CA + server cert + trust distribution
5-pcg/{flux,fluxless}      gateway install (Agent Control) + ALB Ingress + Route53 alias record
your app Deployments       mount the CA-root Secret via init container
```

## Prerequisites

- pcg-cluster and apps-cluster exist in the same region (both discoverable via `aws_eks_cluster` data source)
- IAM identity has `acm-pca:*` permissions (create CA, issue certs)
- kubectl auth works against both clusters (the aws-iam-authenticator / STS flow must be current)
- No prior version of `pcg-tls-secret` in `pcg-cluster:newrelic` (or delete it first — this module won't overwrite external Secrets)

## Usage

Applied once from the module directory using the gateway-side tfvars:

```bash
cd aws/4-dns-tls/private/4.2-out-of-cluster-tls
terraform init
terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars
```

The tfvars file must define `pcg_cluster_name` + `apps_cluster_name` — see `out-of-cluster-private-dns-pcg.tfvars.example`.

## Verification (once applied)

**Server cert exists + covers pcg.internal.newrelic:**

```bash
kubectl --context arn:aws:eks:eu-west-1:123456789012:cluster/pcg-cluster \
  get secret pcg-tls-secret -n newrelic -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -issuer -ext subjectAltName
```

Expected:
- Subject: `CN = pcg.internal.newrelic, O = New Relic`
- Issuer: `CN = New Relic PCG Root CA, ...`
- X509v3 Subject Alternative Name: `DNS:pcg.internal.newrelic`

**CA bundle exists in apps-cluster:**

```bash
kubectl --context arn:aws:eks:eu-west-1:123456789012:cluster/apps-cluster \
  get secret pcg-ca-bundle -n default -o jsonpath='{.data.ca\.crt}' \
  | base64 -d | openssl x509 -noout -subject
```

Expected: `subject=CN = New Relic PCG Root CA, ...`

**Critical: apps-side CA verifies the pcg-side server cert:**

```bash
CTX_PCG=arn:aws:eks:eu-west-1:123456789012:cluster/pcg-cluster
CTX_APPS=arn:aws:eks:eu-west-1:123456789012:cluster/apps-cluster

kubectl --context $CTX_PCG  get secret pcg-tls-secret -n newrelic -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/server.crt
kubectl --context $CTX_APPS get secret pcg-ca-bundle  -n default  -o jsonpath='{.data.ca\.crt}'  | base64 -d > /tmp/ca.crt

openssl verify -CAfile /tmp/ca.crt /tmp/server.crt
```

Expected: `/tmp/server.crt: OK`

This is the whole point of 4.2-out-of-cluster-tls: **apps in apps-cluster, using the distributed CA, can validate the server cert the gateway serves.**

## Inputs

Required:

| Name | Description |
|---|---|
| `pcg_cluster_name` | EKS cluster where the gateway runs |
| `apps_cluster_name` | EKS cluster where apps run |
| `aws_region` | AWS region for both clusters + the CA |

Optional (defaults sensible for the reference architecture):

| Name | Description | Default |
|---|---|---|
| `private_ca_arn` | BYO existing CA — bypasses CA creation | `""` (create) |
| `pcg_hostname` | Server cert Common Name + SAN | `pcg.internal.newrelic` |
| `cert_validity_days` | Server cert lifespan | `397` |
| `ca_common_name` | CA cert subject CN | `"New Relic PCG Root CA"` |
| `ca_validity_years` | Root CA lifespan | `10` |
| `pcg_tls_secret_name` | Secret name in pcg-cluster | `pcg-tls-secret` |
| `pcg_namespace` | Namespace in pcg-cluster | `newrelic` |
| `create_pcg_namespace` | Create the newrelic namespace | `true` |
| `apps_ca_bundle_secret_name` | Secret name in apps-cluster | `pcg-ca-bundle` |
| `apps_namespace` | Namespace in apps-cluster | `default` |

## Outputs

| Name | Description |
|---|---|
| `ca_arn` | The CA's ARN (BYO or created) |
| `ca_certificate_pem` | CA root cert as PEM (same as apps-cluster Secret) |
| `pcg_hostname` | The hostname the server cert covers |
| `pcg_tls_secret_ref` | `{namespace, name}` for the 5-pcg module's Ingress spec |
| `apps_ca_bundle_secret_ref` | `{namespace, name}` for your application's Deployment spec |
| `server_cert_arn` | ACM-PCA cert ARN |
| `cost_reminder` | Prints the Private CA cost warning or the BYO note |

## Costs

- **Fresh CA path**: a flat monthly charge for the Private CA, plus a per-certificate issuance fee.
- **BYO CA path**: the per-certificate issuance fee only.

See the [AWS Private CA pricing page](https://aws.amazon.com/private-ca/pricing/) for current rates.
- **Both K8s Secrets**: free.

Destroy when idle:

```bash
terraform destroy -var-file=../../../out-of-cluster-private-dns-pcg.tfvars
```

Terraform destroys the server cert first, then the CA. The CA's `permanent_deletion_time_in_days = 7` (minimum AWS allows) means the CA record lingers 7 days in DELETED state but stops billing immediately.

## Known limitations

- **No cert rotation.** Server cert lives ~13 months. Re-apply this module to rotate; downstream (the 5-pcg module) will pick up the new cert automatically via the Secret reference.
- **`certificate_chain` is empty for a root CA.** For self-signed root CAs, `aws_acmpca_certificate.server.certificate_chain` may be empty. The Secret's `tls.crt` will just be the leaf cert followed by an empty line — harmless.
- **CA name is fixed at CA creation.** If you want to change `ca_common_name` after apply, you must destroy + recreate the CA. Server cert can be re-issued freely.
- **Regional.** The Private CA lives in one region. Cross-region CA usage requires additional setup out of scope for this module.

## Troubleshooting

**`InvalidArgsException: The certificate authority is not in the ACTIVE state`** — CA activation failed. Look at `aws_acmpca_certificate.root` and `aws_acmpca_certificate_authority_certificate.root` in state. Usually retried by `terraform apply` again.

**`Unauthorized` from Kubernetes** — the EKS auth token from `aws_eks_cluster_auth` expired mid-apply (they're valid ~15 min). Re-run apply; Terraform regenerates.

**`Error: secrets "pcg-tls-secret" already exists`** — a prior version exists in the cluster. Delete it manually: `kubectl delete secret pcg-tls-secret -n newrelic`.

**`context "arn:aws:eks:..." not found`** in the verification steps — you haven't run `aws eks update-kubeconfig --region eu-west-1 --name <cluster-name>` for that cluster yet.

# 4-dns-tls/ — DNS + TLS options

DNS and TLS bundled by variant. Pick ONE subdirectory based on your topology:

## `cert-manager/` — the intra-cluster pattern

In-cluster CA machinery. No external DNS involved. Apps reach the gateway via K8s Service DNS names.
- **`4.1-installer/`** — cert-manager Helm install + CRDs
- **`4.2-cluster-issuer/`** — selfsigned issuer, internal CA cert, CA `ClusterIssuer`
- **`4.3-pcg-certificate/`** — requests a cert from cert-manager for the gateway + CA bundle as K8s Secret

Apply order: `4.1` → `4.2` → `4.3`.

## `private/` — out-of-cluster

Private DNS + private CA. Apps in the apps-cluster resolve the gateway's hostname via VPC-scoped Route53, trust an ACM Private CA.
- **`4.1-route53-private-zone/`** — private hosted zone associated with the shared VPC
- **`4.2-out-of-cluster-tls/`** — ACM Private CA + server cert + K8s Secret distribution to both clusters

Apply order: `4.1` → `4.2`.

**⚠️ Cost warning:** `4.2` creates an AWS Private CA, which bills a flat monthly rate whether idle or busy ([pricing](https://aws.amazon.com/private-ca/pricing/)). Destroy when not actively testing.

## Which variant to pick

- Intra-cluster deployment → `cert-manager/`
- Out-of-cluster (private DNS only — no public variant supported here) → `private/`

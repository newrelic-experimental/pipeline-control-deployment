# BYO Infrastructure

Almost every module in this repo supports **Bring Your Own** (BYO) infrastructure. If you already have a VPC, an EKS cluster, an ingress controller, cert-manager, a private CA, a Route53 zone — set a few tfvars and skip that module entirely.

This doc is a **map** — the details of each BYO option live in the per-module README, linked below. The pattern is always the same: skip the module's `terraform apply`, set 1–3 variables in your tfvars, run downstream modules normally.

## Skip matrix

| Module | BYO variable(s) in tfvars | Detailed README |
|---|---|---|
| `1-vpc/` | `vpc_id`, `subnet_ids` (or `vpc_name` for tag-based lookup) | [aws/1-vpc/README.md](../aws/1-vpc/README.md#byo--reuse-an-existing-vpc) |
| `2-eks/` | `cluster_name` (data source looks it up fresh) | [aws/2-eks/README.md](../aws/2-eks/README.md#byo--reuse-an-existing-eks-cluster) |
| `3-ingress/alb/` | Nothing — downstream Ingress uses `ingressClassName: alb` | [aws/3-ingress/alb/README.md](../aws/3-ingress/alb/README.md#byo--reuse-an-existing-aws-load-balancer-controller) |
| `3-ingress/reverse-proxy-within-cluster/nginx/` | Nothing (skip entirely, use your own ingress) OR `nginx_tls_enabled = false` for out-of-cluster layered mode | [aws/3-ingress/reverse-proxy-within-cluster/nginx/README.md](../aws/3-ingress/reverse-proxy-within-cluster/nginx/README.md#byo--reuse-your-own-ingress--reverse-proxy) |
| `3-ingress/reverse-proxy-within-cluster/kong/` | Nothing (skip entirely) OR `proxy_tls_enabled = false` for out-of-cluster layered mode | [aws/3-ingress/reverse-proxy-within-cluster/kong/README.md](../aws/3-ingress/reverse-proxy-within-cluster/kong/README.md#byo--reuse-an-existing-kong-installation) |
| `4-dns-tls/cert-manager/4.1-installer/` | `issuer_name`, `ca_secret_name`, `ca_secret_namespace` | [aws/4-dns-tls/cert-manager/4.1-installer/README.md](../aws/4-dns-tls/cert-manager/4.1-installer/README.md#byo--reuse-an-existing-cert-manager) |
| `4-dns-tls/cert-manager/4.3-pcg-certificate/` | `tls_secret_name` | [aws/4-dns-tls/cert-manager/4.3-pcg-certificate/README.md](../aws/4-dns-tls/cert-manager/4.3-pcg-certificate/README.md#byo--reuse-an-existing-tls-cert-for-the-gateway) |
| `4-dns-tls/private/4.1-route53-private-zone/` | Skip entirely; set `route53_zone_id` + `pcg_hostname` in tfvars (consumed by downstream `5-pcg/*` modules) | [aws/4-dns-tls/private/4.1-route53-private-zone/README.md](../aws/4-dns-tls/private/4.1-route53-private-zone/README.md#byo--reuse-an-existing-route53-private-zone) |
| `4-dns-tls/private/4.2-out-of-cluster-tls/` | `private_ca_arn` (still apply the module — it does cert issuance + Secret distribution) | [aws/4-dns-tls/private/4.2-out-of-cluster-tls/README.md](../aws/4-dns-tls/private/4.2-out-of-cluster-tls/README.md#byo--reuse-an-existing-private-ca) |
| `5-pcg/flux/` | Can't skip — the gateway itself. Can't skip — pick one of the two modes. | [aws/5-pcg/flux/README.md](../aws/5-pcg/flux/README.md#byo--you-cant-skip-this-module) |
| `5-pcg/fluxless/` | Can't skip — the gateway itself. Can't skip — pick one of the two modes. | [aws/5-pcg/fluxless/README.md](../aws/5-pcg/fluxless/README.md#byo--you-cant-skip-this-module) |

## Common BYO scenarios

### "I already have a VPC and EKS cluster"

Most common enterprise case. Set in your tfvars:
```hcl
vpc_id       = "vpc-0abcdef1234567890"
subnet_ids   = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
cluster_name = "my-existing-cluster"
```
Skip `1-vpc/` and `2-eks/`. Continue from `3-ingress/` onward.

### "I have my own ingress (NGINX Ingress Controller / Traefik / Istio)"

Skip `3-ingress/reverse-proxy-within-cluster/*` entirely. Create an `Ingress` resource yourself pointing to the gateway's Service (`pipeline-control-gateway` in the `newrelic` namespace) on the right ports (`4318` OTLP HTTP, `4317` OTLP gRPC, `80` NR-proprietary).

### "I have cert-manager with a working ClusterIssuer"

Skip `4-dns-tls/cert-manager/4.1-installer/`. In [`4.3-pcg-certificate`](../aws/4-dns-tls/cert-manager/4.3-pcg-certificate/)'s tfvars, set `issuer_name = "your-clusterissuer"`.

### "I have my own gateway server cert as a K8s Secret"

Skip both `4-dns-tls/cert-manager/*` submodules. Set `tls_secret_name = "your-tls-secret"` in downstream tfvars. Your Secret must be `kubernetes.io/tls` type with keys `tls.crt` + `tls.key`, and SANs must cover the Service DNS names the gateway uses.

### "I have an AWS Private CA I want to reuse"

Apply [`4.2-out-of-cluster-tls`](../aws/4-dns-tls/private/4.2-out-of-cluster-tls/) with `private_ca_arn = "arn:aws:acm-pca:..."`. Avoids the flat monthly CA charge; certificate issuance still runs and still bills per certificate.

### "I have my own Route53 private zone"

Skip `4-dns-tls/private/4.1-route53-private-zone/`. Set `route53_zone_id` in downstream tfvars. Your zone must be associated with the VPC that the gateway and its senders resolve DNS in.

## Prerequisites for any BYO path

Regardless of which modules you skip, your existing infra must meet the requirements listed in each module's BYO section. Common ones:

- **VPC:** private subnets in ≥ 2 AZs, subnets tagged `kubernetes.io/role/internal-elb=1`, subnets tagged `kubernetes.io/cluster/<cluster-name>=shared` for each cluster
- **EKS:** Kubernetes 1.29+, OIDC provider enabled
- **Ingress:** IngressClass registered matching what downstream Ingress resources reference (default `alb`, `nginx`, or `kong`)
- **cert-manager:** version 1.13+, ClusterIssuer (not namespace-scoped Issuer)
- **ACM Private CA:** state `ACTIVE`, same region as clusters
- **Route53:** private hosted zone associated with the shared VPC

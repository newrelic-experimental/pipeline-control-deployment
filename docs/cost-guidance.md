# Cost Guidance

What each module creates + what to monitor. **No hard dollar amounts** — AWS prices change, and per-region variance is high. This doc gives relative magnitude so you know where to look in Cost Explorer.

## Cost drivers by module

### `1-vpc/` — moderate ongoing cost

Primary line item: **NAT gateways**. One per AZ by default (up to 3 in most regions). Each NAT gateway has a fixed hourly cost plus data-transfer charges.

- **Fixed cost per NAT:** medium — comparable to a small EC2 instance running 24/7
- **Data transfer:** proportional to how much traffic your gateway + agents push
- **Elastic IPs (1 per NAT):** small
- **VPC + subnets + IGW + route tables:** effectively free

**Cost trimming for dev:** modify `main.tf` to use a single NAT gateway across all AZs instead of one per AZ. Loses AZ isolation but cuts NAT cost by ~66 % in a 3-AZ region.

### `2-eks/` — moderate ongoing cost

- **EKS control plane:** fixed hourly charge per cluster
- **Managed node group:** proportional to instance type + node count (default: 2× `t3.medium`)
- **EBS volumes on nodes:** small
- **IAM roles + OIDC provider:** free

**If your senders run in a second EKS cluster you also provision, this doubles** — two clusters means 2× the control-plane and node-group cost. Senders that already exist (EC2, ECS, another VPC, on-prem) add nothing here.

### `3-ingress/alb/` — negligible + per-ALB cost downstream

- **ALB Controller Helm release:** free (runs on existing nodes)
- **IAM role for IRSA:** free

The actual ALB gets provisioned by `5-pcg/*` when `create_alb_ingress = true`. **AWS ALB:** medium fixed hourly cost + small per-LCU charge.

### `3-ingress/reverse-proxy-within-cluster/*` — negligible

- **NGINX or Kong pods:** proportional to replicas × node capacity. Default 2 replicas of `nginx:1.25-alpine` fit on any t3.medium node with room to spare.

### `4-dns-tls/cert-manager/*` — free

cert-manager Helm release runs on existing nodes. Certificate resources are free.

### `4-dns-tls/private/4.1-route53-private-zone/` — tiny fixed cost

Private hosted zone: small fixed monthly charge + tiny per-query charge (the first billion queries per month are very cheap).

### `4-dns-tls/private/4.2-out-of-cluster-tls/` — **⚠️ large fixed cost**

- **ACM Private CA:** **flat rate per month, active or idle** — this is the single most expensive line item in the out-of-cluster topology
- **Cert issuance:** small per-cert charge

**BYO to avoid the flat monthly charge:** if your org already runs an ACM Private CA, set `private_ca_arn = "..."` in tfvars. Certificates still bill per issuance, but there is no additional CA charge.

**Deletion caveat:** `terraform destroy` deletes the CA record but AWS keeps it in `PENDING_DELETION` state for 7 days minimum (billing stops immediately at destroy).

### `5-pcg/flux/` and `5-pcg/fluxless/` — proportional to workload

- **Gateway pods:** proportional to replicas × pod spec. Recommended sizing is 1 CPU + 2 GiB RAM per pod, minimum 2 replicas
- **ALB (if `create_alb_ingress = true`):** medium fixed cost + per-LCU
- **Route53 alias record:** free (query cost lands in the zone total)

## Total cost of the two topologies

Relative magnitude, largest impact on the bill first:

**Intra-cluster:**
- EKS control plane (medium)
- NAT gateways × AZs (medium each, biggest line item for a small deployment)
- Nodes (proportional to instance type, small at t3.medium)
- Everything else negligible

**Out-of-cluster (with private CA):**
- ACM Private CA (**dominates the bill** — flat rate)
- 2× EKS control plane (medium each)
- NAT gateways × AZs in the shared VPC (medium each)
- Internal ALB (medium)
- 2× node groups (proportional to instance types)
- Everything else negligible

**Out-of-cluster with public DNS:**
- No Private CA (saves the biggest line item)
- Everything else same as the private-DNS variant, minus the CA

## Monitoring costs

- **Set an AWS Budget alert** for the account you deploy into. The first 30 days will show you the actual burn rate.
- **Cost Explorer, grouped by Service** — look for `Amazon Elastic Compute Cloud`, `AWS Certificate Manager Private Certificate Authority`, `AWS Elastic Load Balancing`, `Amazon Elastic Container Service for Kubernetes`, `Amazon Route 53`
- **CloudWatch metrics for gateway pods** — under-utilized replicas mean you're overpaying for nodes

## Teardown reminders

**Always tear down when idle.** Every module has a `terraform destroy` step in its README.

**Destroy order matters** — reverse of apply. From `aws/README.md`:
1. `5-pcg/*` (removes ALB + Route53 record)
2. `3-ingress/*`
3. `4-dns-tls/*` (Private CA billing stops here for out-of-cluster)
4. [`2-eks`](../aws/2-eks/) (removes both workspaces for out-of-cluster)
5. [`1-vpc`](../aws/1-vpc/)

If you skip a module during apply (BYO), skip it during destroy too — otherwise Terraform will complain about state it doesn't own.

**Common orphans after failed destroy:**
- **ENIs** stuck on subnets after EKS teardown — `aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc>`
- **Load balancers** if K8s Service or Ingress deletion timed out — `aws elbv2 describe-load-balancers`
- **NAT gateway Elastic IPs** if NAT destroy fails — `aws ec2 describe-addresses`

Clean these manually before re-applying — otherwise you'll hit "resource already exists" errors and pay for orphaned resources.

# 4.1-route53-private-zone

**out-of-cluster** — private DNS for the Pipeline Control gateway. Creates an empty Route53 private hosted zone associated with the shared VPC so apps in `apps-cluster` can resolve the gateway hostname without any public DNS.

## What it creates

- A private hosted zone (default name: `internal.newrelic`)
- One VPC association at zone creation (the shared VPC, auto-discovered by `<vpc_name>-vpc` tag)
- Zero or more additional VPC associations via `additional_vpc_ids` (empty for the same-VPC out-of-cluster default)

**No DNS records.** The A/alias record for `pcg.<zone_name>` is created later by whichever module provisions the ALB, once the ALB DNS name is known.

## BYO — reuse an existing Route53 private zone

**Skip this module entirely** if you already have a Route53 private hosted zone. This module itself takes no BYO input — you just don't apply it. Downstream `5-pcg/*` modules read `route53_zone_id` and `pcg_hostname` from the shared tfvars and create the A-record for `pcg.<your-zone-name>` inside your existing zone.

Set these in `aws/out-of-cluster-private-dns-pcg.tfvars` (the values are consumed by [`5-pcg/flux`](../../../5-pcg/flux/) or [`5-pcg/fluxless`](../../../5-pcg/fluxless/), NOT by this module — this module isn't applied at all):

```hcl
route53_zone_id = "Z0EXAMPLE1234567"    # your existing private zone's ID
pcg_hostname    = "pcg.internal.example.com" # matches your zone name + subdomain
```

Look up the ID via: `aws route53 list-hosted-zones-by-vpc --vpc-id <your-vpc> --vpc-region <region>`.

### What your existing zone must have

| Requirement | Detail |
|---|---|
| Private hosted zone type | Not public — apps-cluster resolves via VPC DNS resolver |
| Associated with the shared VPC | Where pcg-cluster + apps-cluster live. If not: `aws route53 associate-vpc-with-hosted-zone --hosted-zone-id <zone> --vpc <vpc>` |
| Zone name matches your `pcg_hostname` | Zone `internal.example.com` + hostname `pcg.internal.example.com` |

Skipping this module removes the per-zone charge. Apply order becomes: VPC → EKS → ALB Controller → [`4.2-out-of-cluster-tls`](../4.2-out-of-cluster-tls/) → gateway (creates the A-record in your zone).

## Where it fits in the out-of-cluster pattern

```
3-ingress/alb              ALB Controller on pcg-cluster (IRSA + Helm)
4.1-route53-private-zone   ← THIS MODULE: private zone associated with the shared VPC
4.2-out-of-cluster-tls     ACM Private CA + server cert + CA-root Secret to apps-cluster
5-pcg/{flux,fluxless}      gateway install + ALB Ingress + the Route53 alias record
your app Deployments       mount the CA-root Secret via init container
```

## Prerequisites

- [`1-vpc`](../../../1-vpc/) applied — the shared VPC exists and is tagged `Name = "<vpc_name>-vpc"`
- AWS credentials with `route53:CreateHostedZone`, `route53:AssociateVPCWithHostedZone`
- No permissions boundary constraints on Route53 in most orgs; this module creates no IAM

## Usage

Applied once against the out-of-cluster tfvars:

```bash
cd aws/4-dns-tls/private/4.1-route53-private-zone
terraform init
terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars
```

Which tfvars? Either `out-of-cluster-private-dns-pcg.tfvars` or `out-of-cluster-private-dns-apps.tfvars` works — this module only reads `aws_region`, `vpc_name`, `zone_name`, `tags`. Use the pcg-cluster one for consistency; conceptually the zone belongs to the gateway side.

## Out-of-cluster DNS resolution — how it works

AWS Route53 private hosted zones are resolved by the **VPC's DNS resolver** (the .2 address of each subnet's CIDR) — not by CoreDNS in the cluster. Both clusters are in the same VPC, so both pods automatically inherit VPC DNS.

Verify from any pod in either cluster:

```bash
kubectl run dnstest --rm -it --restart=Never --image=busybox -- \
  nslookup pcg.internal.newrelic
```

Before the 5-pcg module (no A record yet) → `NXDOMAIN` for the record but the zone SOA resolves.
After the 5-pcg module → returns the ALB's private IPs.

## Cross-VPC case (future)

If the gateway cluster and apps cluster end up in **different VPCs** (e.g., a customer with separate accounts using VPC peering), pass the apps VPC ID in `additional_vpc_ids`:

```hcl
additional_vpc_ids = ["vpc-0appscluster..."]
```

The module attaches the extra VPC to the zone via `aws_route53_zone_association`. The apps VPC must be **peered** with the gateway VPC AND the peering must have DNS resolution enabled — otherwise Route53 private zone lookups from the apps VPC still fail.

## Inputs

| Name | Description | Default |
|---|---|---|
| `aws_region` | AWS region | `us-west-1` (override in tfvars) |
| `cluster_name` | Only used as VPC-lookup fallback if `vpc_name` is empty | `pcg-cluster` |
| `vpc_name` | VPC Name tag prefix. Set to `pcg-shared` for the out-of-cluster pattern. | `""` (falls back to `cluster_name`) |
| `vpc_id` | Explicit VPC ID; bypasses tag lookup | `""` |
| `additional_vpc_ids` | Extra VPCs to associate | `[]` |
| `zone_name` | Private zone name | `internal.newrelic` |
| `zone_comment` | Free-text comment on the zone | See variables.tf |
| `tags` | Extra tags on the zone | `{}` |
| `environment` | Env label for default_tags | `dev` |

## Outputs

| Name | Description |
|---|---|
| `zone_id` | Route53 hosted zone ID. The 5-pcg module consumes this. |
| `zone_name` | Zone name (e.g. `internal.newrelic`) |
| `zone_arn` | Zone ARN for scoped IAM policies |
| `primary_vpc_id` | The VPC associated at zone creation |
| `associated_vpc_ids` | Full list of associated VPCs |
| `example_pcg_hostname` | Derived `pcg.<zone_name>` — for agent config previews |

## Costs

Route53 private hosted zones carry a very small fixed monthly charge per zone plus a per-query charge, both negligible at this scale. See the [Route 53 pricing page](https://aws.amazon.com/route53/pricing/) for current rates.

## Cleanup

```bash
terraform destroy -var-file=../../../out-of-cluster-private-dns-pcg.tfvars
```

Removes the zone and all VPC associations. `force_destroy = true` in the resource — the zone is deletable even if downstream records exist (the 5-pcg module's A record will be destroyed with it if you tear down in reverse order).

## Known limitations

- **`vpc_region` is set to `var.aws_region`.** If you want to associate a VPC from a DIFFERENT region, you'd need a per-association override — not supported by this module today. Cross-region private DNS is out of scope for this reference architecture.
- **No records created here.** Any consumer must depend on this module and create their records with the zone_id output.

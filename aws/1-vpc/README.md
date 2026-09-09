# 1-vpc

Creates the VPC and networking infrastructure that EKS runs on. **Step 1** of every pattern.

## What it creates

- 1 VPC (default CIDR `10.0.0.0/16`, override via `vpc_cidr`)
- Up to 3 public subnets, one per available AZ (2 in `us-west-1` since that region only has 2 AZs; 3 in most other regions)
- Up to 3 private subnets, one per AZ — EKS nodes run here
- 1 Internet Gateway (for public subnet egress)
- 1 NAT Gateway per AZ, each with an Elastic IP (for private subnet egress — needed so EKS nodes can pull images)
- Route tables + associations wiring everything together
- All resources tagged `kubernetes.io/cluster/${cluster_name} = shared` so EKS auto-discovers them in Step 2

The module uses `slice(azs, 0, min(3, length(azs)))` — it takes up to 3 AZs, so behaviour differs by region.

## Cost note

NAT gateways are the single biggest AWS line item this module creates. Each NAT gateway carries a fixed hourly charge plus data-transfer charges; see the [VPC pricing page](https://aws.amazon.com/vpc/pricing/). In dev, you can safely trim to a single NAT gateway to save money — modify `main.tf` if needed. Production reference architectures typically use one per AZ for HA.

## BYO — reuse an existing VPC

**Skip this module entirely** if your team already has a VPC + private subnets. Don't run `terraform apply` here. Instead set the right variables in your tfvars (intra-cluster: `aws/intra-cluster.tfvars`; out-of-cluster: `aws/out-of-cluster-private-dns-pcg.tfvars` **and** `-apps.tfvars`). Downstream modules ([`2-eks`](../2-eks/), [`3-ingress/alb`](../3-ingress/alb/), `4-dns-tls/private/*`) read them directly.

Pick the option that matches how your VPC is tagged. **Option 3 is the most reliable** — it needs zero tags to work, so it's the recommended starting point if you're unsure. Options 1 and 2 are shortcuts when your VPC already carries the expected tags.

### Option 1 — auto-discover by Name tag (least tfvars, most fragile)

Works when your VPC has a Name tag exactly matching `<vpc_name>-vpc`.

```hcl
vpc_name = "my-existing"    # module looks up VPC with Name tag = "my-existing-vpc"
                            # subnets auto-discovered via tag kubernetes.io/role/internal-elb = 1
```

If `vpc_name` is left empty, the code falls back to `<cluster_name>-vpc`. If neither tag exists you'll hit **`Error: no matching EC2 VPC found`** — use Option 2 or 3 instead.

### Option 2 — pin VPC by ID, auto-discover subnets

Works when your VPC doesn't have a matching Name tag but your subnets ARE tagged.

```hcl
vpc_id = "vpc-0abcdef1234567890"    # subnets still auto-discovered inside this VPC
                                    # via tag kubernetes.io/role/internal-elb = 1
```

### Option 3 — full explicit BYO (Recommended — no tag reliance, no failure modes)

Works regardless of tags. This is what your team should default to if they hit `no matching EC2 VPC found`.

```hcl
vpc_id     = "vpc-0abcdef1234567890"
subnet_ids = ["subnet-0aaa...", "subnet-0bbb...", "subnet-0ccc..."]  # PRIVATE subnets only
```

### Requirements your existing VPC must meet (all options)

| Requirement | Why |
|---|---|
| Private subnets in ≥ 2 AZs | EKS control plane requires multi-AZ |
| Subnet tag `kubernetes.io/role/internal-elb = 1` on each private subnet | ALB Controller uses this to pick subnets for internal LBs. Also used by Options 1/2 subnet auto-discovery |
| Subnet tag `kubernetes.io/cluster/<cluster-name> = shared` on each subnet | EKS auto-discovery. For out-of-cluster (two clusters), tag with BOTH `pcg-cluster` AND `apps-cluster` names |
| DNS resolution + DNS hostnames enabled on VPC | Required for private Route53 zones (out-of-cluster only) |
| Egress to internet (NAT gateway or VPC endpoints) | So EKS nodes can pull container images |

## Prerequisites

- AWS CLI configured (`aws sts get-caller-identity` works)
- Terraform ≥ 1.0
- Sufficient IAM permissions to create VPC/subnets/EIPs/NAT gateways (the default PowerUser role has these; only `iam:CreateRole` is the sticking point — and that's Step 2's problem, not this module's)

## Usage

```bash
cd aws/1-vpc
terraform init
terraform plan  -var-file=../intra-cluster.tfvars
terraform apply -var-file=../intra-cluster.tfvars
```

Apply takes 2–3 min. Most of that is waiting on NAT gateways.

## Verify

```bash
VPC_ID=$(terraform output -raw vpc_id)

aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].{id:VpcId,cidr:CidrBlock,state:State}'

# Should show private + public subnets across your region's AZs
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{az:AvailabilityZone,cidr:CidrBlock,name:Tags[?Key==`Name`].Value|[0]}'
```

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| `cluster_name` | Name used for VPC tagging and EKS auto-discovery | `pcg-cluster` | Yes (via shared tfvars) |
| `aws_region` | AWS region | `us-west-1` | Yes |
| `vpc_cidr` | VPC CIDR block | `10.0.0.0/16` | No |
| `environment` | Environment tag | `dev` | No |
| `tags` | Extra tags applied to all resources | `{}` | No |

## Outputs

| Name | Description | Consumer |
|---|---|---|
| `vpc_id` | VPC ID | Reference (Step 2 auto-discovers, doesn't need to be passed) |
| `vpc_cidr` | CIDR block | Reference |
| `private_subnet_ids` | Private subnet IDs (for EKS worker nodes) | Reference |
| `public_subnet_ids` | Public subnet IDs (for external load balancers) | Reference |
| `availability_zones` | AZs used | Reference |
| `cluster_name`, `aws_region` | Passthrough of shared tfvars values | Reference |

## Troubleshooting

**`UnauthorizedOperation`** — your AWS credentials don't have `ec2:*`. Fix credentials before proceeding.

**CIDR conflict** — change `vpc_cidr` to a non-overlapping /16 (e.g. `10.42.0.0/16`) in `intra-cluster.tfvars`.

**"only 2 subnets created, expected 3"** — you're in a region with fewer than 3 AZs (e.g. `us-west-1`). Expected. EKS needs ≥2 AZs, so this still works.

## Cleanup

```bash
terraform destroy -var-file=../intra-cluster.tfvars
```

If destroy hangs, check for orphaned ENIs from EKS (`aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc_id>`) — EKS's CNI sometimes leaves them behind. Delete manually and retry.

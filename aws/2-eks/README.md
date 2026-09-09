# 2-eks

Creates an EKS cluster + managed node group + IAM roles + OIDC provider. **Step 2** of either pattern — every topology needs a cluster.

## What it creates

- IAM role for the EKS control plane (with `AmazonEKSClusterPolicy` + `AmazonEKSVPCResourceController`)
- IAM role for worker nodes (with `AmazonEKSWorkerNodePolicy` + `AmazonEKS_CNI_Policy` + `AmazonEC2ContainerRegistryReadOnly`)
- Security group for the cluster control plane, with an **all-protocol egress rule to `0.0.0.0/0`** (see "About the egress rule" below)
- EKS cluster (default Kubernetes 1.31)
- OIDC provider (for IRSA — IAM Roles for Service Accounts)
- Launch template with encrypted EBS volumes + proper resource tagging
- 1 managed node group with 2× t3.medium (auto-scales 1–4)

Auto-discovers the VPC and private subnets from Step 1 by their `Name` tag — no manual VPC ID copy.

### About the egress rule

The cluster control-plane security group has a single egress rule that allows all protocols to `0.0.0.0/0`. This is the AWS-recommended default for EKS: the control plane needs to reach worker nodes' ENIs (which get private IPs assigned dynamically by the VPC CNI) plus AWS service endpoints (STS, ECR, CloudWatch, EC2 for tag reads).

Restricting egress is possible but fragile — you'd need to keep the allowed CIDRs in sync with (a) your VPC's private subnet CIDRs, (b) every AWS service endpoint the control plane uses, and (c) whatever the CNI plugin assigns to pods. Most operators leave this alone. If your security posture requires narrower egress, replace the rule with explicit destination CIDRs matching (a)–(c), and expect to revisit it whenever AWS adds a new dependency.

## BYO — reuse an existing EKS cluster

**Skip this module entirely** if you already have an EKS cluster. Don't run `terraform apply` here. Downstream modules ([`3-ingress/alb`](../3-ingress/alb/), [`5-pcg/flux`](../5-pcg/flux/), [`5-pcg/fluxless`](../5-pcg/fluxless/), `4-dns-tls/*`) look the cluster up fresh via `data "aws_eks_cluster"` — they don't consume this module's outputs.

Minimum tfvars to point everything at your existing cluster:

```hcl
cluster_name = "my-existing-eks-cluster"    # exact EKS cluster name (data source looks it up)
aws_region   = "eu-west-1"                  # region the cluster lives in
```

Combine with a BYO-VPC option from [`1-vpc/README.md`](../1-vpc/README.md) if you're also reusing a VPC.

### What your existing cluster must have

| Requirement | Why |
|---|---|
| Kubernetes 1.29+ (1.31 is the module default) | Chart / provider compatibility |
| OIDC provider enabled | Needed for IRSA ([`3-ingress/alb`](../3-ingress/alb/)) |
| Node group with 1 CPU + 2 GB RAM per gateway pod, min 2 replicas | Recommended gateway sizing |
| Private subnets tagged `kubernetes.io/role/internal-elb = 1` | Internal ALB provisioning |
| If sharing VPC with another cluster: subnets tagged `kubernetes.io/cluster/<name> = shared` for each cluster name | EKS auto-discovery |
| Your IAM identity has kubectl access | Either you created the cluster or you're in its `aws-auth` ConfigMap |

Skipping this module avoids the EKS control-plane charge for that cluster. You take responsibility for the prerequisites above.

## IAM prerequisites — read this FIRST if in a restricted AWS account

Some AWS accounts (including many New Relic-managed ones and other enterprise setups) **do not grant `iam:CreateRole` to the default SSO/PowerUser role.** `terraform apply` will fail with:

```
AccessDenied: User: ... is not authorized to perform: iam:CreateRole
```

**Two options depending on your account:**

### Option A — Permissive account (personal AWS / dev sandbox)

Do nothing special. Leave `permissions_boundary = ""` in the shared tfvars. Terraform runs as your current identity, creates IAM roles freely.

### Option B — Restricted account (must assume a delegated role + attach a boundary)

Two mandatory pieces:

**1. Assume a role that HAS `iam:CreateRole`** (typically a `resource-provisioner`-style role your admin set up). Run this in your shell **before** `terraform apply`:

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/resource-provisioner \
  --role-session-name $(date +%Y%m%d-%H%M%S) > response.json
export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId' response.json)
export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' response.json)
export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken' response.json)
aws sts get-caller-identity   # confirm you're now the assumed role
```

Terraform reads the exported credentials from your environment; no tfvars variable is needed. STS credentials typically expire in ~1 hour — re-run the block when you hit `ExpiredToken`.

**2. Attach the boundary policy to every role this module creates.** The provisioner role typically has its own boundary that requires new roles it creates to also carry a boundary. Set in `intra-cluster.tfvars`:

```hcl
permissions_boundary = "arn:aws:iam::<ACCOUNT_ID>:policy/resource-provisioner-boundary"
```

You'd know you need this because the apply fails with `explicit deny in a permissions boundary`. The exact policy name varies by account — confirm with your admin.

**Both pieces required.** Without the assumed role, you can't create IAM roles at all. Without the boundary in tfvars, the assumed role refuses to create unbounded roles.

## Prerequisites

- Step 1 (VPC) applied — this module auto-discovers by `Name = ${cluster_name}-vpc` tag
- Terraform ≥ 1.0, AWS CLI, kubectl

## Usage

```bash
cd aws/2-eks
terraform init
terraform plan  -var-file=../intra-cluster.tfvars
terraform apply -var-file=../intra-cluster.tfvars
```

Apply takes **12–15 minutes** — the EKS control plane provisions in ~10 min, then the node group boots in ~3 min. Don't kill it if you see long "Still creating..." spans.

## Verify

```bash
# Point kubectl at the new cluster
CLUSTER=$(terraform output -raw cluster_name)
REGION=$(terraform output -raw aws_region)
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"

kubectl cluster-info
kubectl get nodes         # 2 nodes, STATUS=Ready
kubectl get pods -A       # aws-node, coredns, kube-proxy all Running
```

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| `cluster_name` | EKS cluster name | `pcg-cluster` | Yes (via shared tfvars) |
| `aws_region` | AWS region | `us-west-1` | Yes |
| `kubernetes_version` | K8s version | `1.31` | No |
| `vpc_id` | VPC ID (empty = auto-discover by tag) | `""` | No |
| `subnet_ids` | Private subnet IDs (empty = auto-discover) | `[]` | No |
| `node_groups` | Node group config (see variables.tf) | 2× t3.medium ON_DEMAND | No |
| `permissions_boundary` | IAM boundary ARN for created roles | `""` (no boundary) | No — required in restricted accounts |
| `endpoint_private_access` | EKS API reachable from inside the VPC | `true` | No |
| `endpoint_public_access` | EKS API reachable from the public internet | `true` | No |
| `public_access_cidrs` | CIDRs allowed to reach the public API endpoint | `["0.0.0.0/0"]` | No |
| `environment` | Environment tag | `dev` | No |
| `tags` | Extra tags applied to all resources | `{}` | No |

## Outputs

| Name | Description | Consumer |
|---|---|---|
| `cluster_name` | EKS cluster name | Downstream module data sources |
| `cluster_endpoint` | Kubernetes API endpoint | Reference |
| `cluster_oidc_issuer_url` | OIDC issuer URL | ALB controller / IRSA setup |
| `cluster_oidc_provider_arn` | OIDC provider ARN | ALB controller / IRSA setup |
| `vpc_id`, `subnet_ids` | Discovered/passed VPC + subnets | Reference |
| `configure_kubectl` | Ready-to-run `aws eks update-kubeconfig` command | Print + copy |

## Cluster endpoint access

The EKS control-plane API is reachable from two places, controlled independently:

- **Private endpoint** (`endpoint_private_access`, default `true`) — from workloads inside the VPC. Terraform itself doesn't use this, but the in-cluster components installed by later modules (ALB Controller, cert-manager, gateway pods) do. Leave this on.
- **Public endpoint** (`endpoint_public_access`, default `true`) — from the public internet. This is how your workstation reaches the API to run `kubectl` and `terraform` from outside the VPC.

The defaults make the API reachable from anywhere on the internet (`public_access_cidrs = ["0.0.0.0/0"]`). That's convenient for getting a fresh cluster up, but **not** a good production posture.

**Recommended production hardening**, in decreasing order of restrictiveness:

1. **Private only** — set `endpoint_public_access = false`. Requires that your workstation can reach the VPC privately (VPN, Direct Connect, VPC Peering, or a bastion inside the VPC). Terraform runs from your workstation, so you need private connectivity before you flip this or you'll lock yourself out on the next apply.
2. **Public, allowlisted** — leave `endpoint_public_access = true` and set `public_access_cidrs = ["<your-admin-CIDR>/32"]`. Simpler than option 1 but still narrows the exposure from the whole internet to your egress CIDR.
3. **Public, open** (the default) — fine for a sandbox or a short-lived demo cluster.

Whichever you pick, `kubectl` access still requires an IAM identity that's in the `aws-auth` ConfigMap (see the next section) — the endpoint controls *network reachability*, not authorization.

## kubectl access to the cluster

**Only the IAM identity that created the cluster has admin access by default.** EKS grants this via a hidden `system:masters` mapping to the creator identity — it's not in the `aws-auth` ConfigMap you can inspect.

Consequences:
- If you created the cluster as the assumed `resource-provisioner` role, only that role has kubectl access
- Your regular SSO identity will get `Unauthorized` from kubectl
- To fix: either re-assume the creator role every session, or add your SSO role to the `aws-auth` ConfigMap in `kube-system`. This module does not manage that ConfigMap; see the known limitations in the [root README](../../README.md#known-limitations).

## Troubleshooting

**`AccessDenied: iam:CreateRole`** — see IAM prerequisites above. Assume `resource-provisioner` (or your org's equivalent).

**`explicit deny in a permissions boundary`** — your assumed role requires new roles to carry a boundary. Set `permissions_boundary` in tfvars to the ARN your admin gave you.

**Nodes stuck `NotReady` > 5 min** — `kubectl describe node <name>`. Most common cause: NAT gateway not routing (nodes can't pull the CNI image). Re-check Step 1.

**kubectl `Unauthorized` after previously working** — assumed-role creds expired (~1 hour lifetime). Re-run the assume-role block, then `aws eks update-kubeconfig` again.

## Cleanup

```bash
terraform destroy -var-file=../intra-cluster.tfvars
```

Takes ~10 min. If it hangs on the node group, check `aws eks list-nodegroups` and delete manually. If it hangs on the cluster, check for orphaned ENIs from CNI teardown (`aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc>`).

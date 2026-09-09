# 3-ingress/alb

Installs the AWS Load Balancer Controller in the EKS cluster via Helm with IRSA (IAM Roles for Service Accounts). Used by the [out-of-cluster pattern](../../../docs/pattern-out-of-cluster.md) so senders outside the gateway's cluster can reach it through an ALB. Not used by the [intra-cluster pattern](../../../docs/pattern-intra-cluster.md), which needs no external ingress.

## What it creates

- IAM policy for the ALB Controller (~200 lines of AWS permissions — includes v2.6+ additions)
- IAM role with IRSA trust policy targeting the EKS cluster's OIDC provider
- Kubernetes ServiceAccount annotated with the role ARN (magic IRSA line)
- Helm release of `aws-load-balancer-controller` chart (v1.13.0) into `kube-system`
- Registered `IngressClass alb` — this is what Ingress resources reference

Once installed, ALB Controller watches for Ingress objects and provisions real AWS ALBs.

## About the IAM policy — scope and how to tighten it

The inline policy is the AWS-recommended one for ALB Controller v2.6+ (from [`iam_policy.json`](https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/main/docs/install/iam_policy.json) in the upstream project). It contains ~10 statements with `Resource = "*"` or wildcard ARNs — including `elasticloadbalancing:*`, `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`, `iam:CreateServiceLinkedRole`, `wafv2:*`, `shield:*`, and `cognito-idp:DescribeUserPoolClient`.

The wildcards are unavoidable for the controller to work — it creates ALBs whose ARNs aren't known ahead of time. AWS mitigates the blast radius by scoping most destructive actions with condition keys on `elbv2.k8s.aws/cluster` — the controller can only touch resources it (or another AWS-LB-Controller on this cluster) has tagged.

**If you're deploying into an account with a stricter posture, you have three tightenings available:**

1. **Delete `wafv2:*` and `shield:*` blocks** if you don't use AWS WAF or Shield with your ALBs. The controller only calls those APIs when Ingress annotations request WAF/Shield integration — nothing in this repo does.
2. **Delete `cognito-idp:DescribeUserPoolClient`** if you don't use Cognito authentication on ALBs. Again, this repo doesn't.
3. **Replace `Resource = "*"` on the `elasticloadbalancing:*` write actions** with the ALB ARN pattern for your specific cluster (`arn:aws:elasticloadbalancing:<region>:<account>:loadbalancer/app/<cluster>-*`). This is more work — the controller creates load-balancer, target-group, listener, and rule ARNs — but it stops the role from being usable against other clusters' ALBs.

If you take any of these on, fork the policy JSON, drop the statements you don't need, and load it via `data "aws_iam_policy_document"` instead of the inline block in this module. Confirm each change against the [ALB Controller's own tightening guide](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/security_groups/).

The existing IAM prerequisites documentation in [`../../2-eks/README.md`](../../2-eks/README.md#iam-prerequisites) covers permissions needed to *run* Terraform in a restricted account. This section covers permissions the module *grants* — a separate question.

## BYO — reuse an existing AWS Load Balancer Controller

**Skip this module entirely** if your cluster already has ALB Controller installed. Downstream modules ([`5-pcg/flux`](../../5-pcg/flux/), [`5-pcg/fluxless`](../../5-pcg/fluxless/)) create `Ingress` resources with `ingressClassName: alb` — any conforming ALB Controller picks them up.

No tfvars change needed — the downstream Ingress just uses `ingressClassName = "alb"`.

### What your existing ALB Controller must have

| Requirement | Why |
|---|---|
| Version 2.6+ | Older versions miss newer IAM permissions the Ingress resources need |
| IAM role with AWS-recommended policy including `DescribeListenerAttributes`, `ModifyListenerAttributes`, `DescribeTrustStores`, `DescribeCapacityReservation`, `ModifyCapacityReservation` | ALB Controller v2.6+ requires these; omitting them surfaces as missing-permission errors at reconcile time |
| Configured for the correct VPC (`vpcId` in the controller's Helm values) | ALB provisions in the same VPC as the controller |
| IngressClass `alb` registered (default) | Downstream Ingress selects this class |

You own keeping the controller current with new IAM requirements.

## Prerequisites

- Step 1 (VPC) + Step 2 (EKS) applied — OR you're bringing your own EKS with the OIDC provider enabled
- kubectl configured to hit the cluster
- The EKS cluster's OIDC provider (auto-discovered from `cluster_name`)

## Usage

```bash
cd aws/3-ingress/alb
terraform init

# For the out-of-cluster pattern (uses workspaces):
terraform workspace new pcg-cluster
terraform apply -var-file=../../out-of-cluster-private-dns-pcg.tfvars

# For the intra-cluster pattern (single cluster):
terraform apply -var-file=../../intra-cluster.tfvars
```

## Cleanup

```bash
terraform destroy -var-file=../../out-of-cluster-private-dns-pcg.tfvars
```

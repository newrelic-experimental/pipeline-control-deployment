# 4.1-installer

Installs [cert-manager](https://cert-manager.io/) and its CRDs. **Step 3** of the intra-cluster pattern.

The bootstrap ClusterIssuer, the internal CA Certificate, and the CA ClusterIssuer that this module used to create all live in the sibling [`4.2-cluster-issuer`](../4.2-cluster-issuer/) module now. See its README for why the split.

## What it creates

- `cert-manager` namespace (opt-out via `create_namespace = false`)
- cert-manager Helm release (v1.14.4 by default, waits for pods Ready)
- The cert-manager CRDs (via the chart's `installCRDs = true` — the actual issuers and CA use these in Step 4a)
- 30-second `time_sleep` after the Helm install so the webhook stabilizes before Step 4a creates the first custom resources

## When to use

| Scenario | Use? |
|---|---|
| No cert-manager in cluster | ✅ |
| Already have cert-manager | ❌ Skip; see BYO below |

## BYO — reuse an existing cert-manager

**Skip this module entirely** if your cluster already has cert-manager installed. You still need a `ClusterIssuer` for downstream cert requests — either apply Step 4a ([`4.2-cluster-issuer`](../4.2-cluster-issuer/)) to create one, or reuse an existing one and point Step 4b ([`4.3-pcg-certificate`](../4.3-pcg-certificate/)) at it via its `issuer_name` variable.

### What your existing cert-manager must have

| Requirement | Why |
|---|---|
| cert-manager 1.13+ | Older versions have webhook + CRD-schema issues |
| A **ClusterIssuer** (not namespace-scoped Issuer) | Cross-namespace cert issuance requires cluster scope |
| Issuer can issue certs for the SAN list the gateway uses | Otherwise cert request will fail |
| CA cert available as a K8s Secret you can reference | Needed to distribute CA trust to workloads |

## Prerequisites

- EKS cluster running (from Steps 1 + 2)
- kubectl configured
- Terraform ≥ 1.0

## Usage

```bash
cd aws/4-dns-tls/cert-manager/4.1-installer
terraform init
terraform plan  -var-file=../../../intra-cluster.tfvars
terraform apply -var-file=../../../intra-cluster.tfvars
```

The shared `intra-cluster.tfvars` already sets `cluster_name` and `aws_region`. Terraform will emit "Values for undeclared variables" warnings for other tfvars entries — harmless, they belong to other modules.

## Verify

```bash
# All 3 cert-manager pods Running
kubectl get pods -n cert-manager

# CRDs installed
kubectl get crd | grep cert-manager.io
```

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| `cluster_name` | EKS cluster name | — | Yes |
| `aws_region` | AWS region | — | Yes |
| `namespace` | Namespace for cert-manager | `cert-manager` | No |
| `create_namespace` | Create namespace if not exists | `true` | No |
| `cert_manager_version` | Helm chart version | `v1.14.4` | No |

## Outputs

| Name | Description |
|---|---|
| `namespace` | cert-manager namespace (referenced by 4.2-cluster-issuer) |

## Next step

Step 4a: [`4.2-cluster-issuer`](../4.2-cluster-issuer/) — creates the internal CA and the `ClusterIssuer` that downstream cert requests use.

## Troubleshooting

**Webhook pod CrashLoopBackOff on first apply** — normal for ~30-60s while cert-manager installs its CRDs. The module's `time_sleep` covers this.

## Cleanup

```bash
terraform destroy -var-file=../../../intra-cluster.tfvars
```

Removes cert-manager and every certificate it manages. Don't run this while any downstream cert (like `pcg-tls`) is still in use. Run the sibling 4.2 and 4.3 destroys first.

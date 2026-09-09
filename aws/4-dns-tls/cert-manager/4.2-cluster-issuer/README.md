# 4.2-cluster-issuer

Bootstraps the internal CA that in-cluster TLS is signed by. Three cert-manager custom resources:

1. `selfsigned-issuer` **ClusterIssuer** — the seed issuer, used only to sign the CA below.
2. `internal-ca` **Certificate** — the actual CA cert. 10-year validity, auto-renews 30 days before expiry.
3. `internal-ca-issuer` **ClusterIssuer** — the CA issuer that downstream `Certificate` resources (like `4.3-pcg-certificate`) request certs from.

## Why this is a separate module from 4.1-installer

`hashicorp/kubernetes`'s `kubernetes_manifest` resource resolves a resource's schema at **plan time**. Custom resources whose CRDs don't yet exist can't be planned. Since `4.1-installer` creates the cert-manager CRDs at **apply time** (via `installCRDs = true`), putting the three CRs above into the same apply doesn't work.

Splitting the CRD install from the CR creation into two applies means the CRDs from 4.1 already exist by the time 4.2 plans, so `kubernetes_manifest` can resolve their schema against the live cluster. This is why cert-manager needs 4.1 → 4.2 → 4.3 rather than a single-shot module — same pattern any Terraform-managed CRD+CR chain needs.

## Apply order

```bash
# After 4.1-installer applied, and before 4.3-pcg-certificate:
cd aws/4-dns-tls/cert-manager/4.2-cluster-issuer
terraform init
terraform apply -var-file=../../../intra-cluster.tfvars
cd -
```

## BYO — skip if you already have a ClusterIssuer

If your cluster already has a `ClusterIssuer` you want to use (e.g. Let's Encrypt, an existing internal CA), skip this module and point `4.3-pcg-certificate` at your issuer via its `issuer_name` variable. See [`../4.3-pcg-certificate/README.md`](../4.3-pcg-certificate/README.md) for the BYO section.

You can also skip just the CA creation while still using the module (e.g. to bring in your own CA certificate but let this module wire up a `ClusterIssuer`): set `create_internal_ca = false`.

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| `cluster_name` | EKS cluster name | — | Yes |
| `aws_region` | AWS region | — | Yes |
| `namespace` | Namespace where cert-manager is installed (matches 4.1) | `cert-manager` | No |
| `create_internal_ca` | Create the CA + ClusterIssuer | `true` | No |
| `ca_name` | Name of the CA Certificate resource | `internal-ca` | No |
| `ca_secret_name` | Secret cert-manager populates with the CA cert + key | `internal-ca-secret` | No |
| `ca_common_name` | CN on the CA certificate subject | `Pipeline Control Internal CA` | No |
| `issuer_name` | ClusterIssuer name downstream modules reference | `internal-ca-issuer` | No |

## Outputs

- `issuer_name` — for downstream `Certificate` resources
- `ca_secret_name`, `ca_secret_namespace` — for exporting the CA bundle to app pods

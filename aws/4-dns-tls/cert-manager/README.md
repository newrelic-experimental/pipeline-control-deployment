# cert-manager/ — intra-cluster TLS

In-cluster CA machinery for the intra-cluster pattern. cert-manager handles cert issuance + renewal automatically inside the cluster. No external DNS setup needed.

## Two submodules — apply in order

### `4.1-installer/`
- Installs cert-manager Helm chart
- Creates `selfsigned-issuer` (bootstrap) + `internal-ca-issuer` `ClusterIssuer`
- The `ClusterIssuer` is the "notary" that will sign the gateway's cert in 4.2

### `4.3-pcg-certificate/`
- Requests a TLS `Certificate` from `4.1`'s ClusterIssuer for the gateway's Service DNS names
- Emits `pcg-tls-secret` (type `kubernetes.io/tls`) for the ingress module to reference
- Emits `pcg-ca-bundle` Secret (type `Opaque`) for app pods to mount and trust the gateway

## Apply order

```bash
cd 4.1-installer && terraform init && terraform apply -var-file=../../../intra-cluster.tfvars
cd ../4.3-pcg-certificate && terraform init && terraform apply -var-file=../../../intra-cluster.tfvars
```

## Future work

These two submodules will be merged into a single `cert-manager/` module (no submodules) after end-to-end validation of the restructured layout. Kept split for now to preserve the tested state of each independently. Tracked as a deferred task.

## BYO

If you already have cert-manager installed with a working `ClusterIssuer`:
- Skip `4.1-installer/` entirely
- In `4.3-pcg-certificate/`'s tfvars, set `issuer_name` to your existing `ClusterIssuer` name

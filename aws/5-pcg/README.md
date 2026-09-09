# 5-pcg/ — gateway install

Installs the Pipeline Control gateway. Pick ONE mode based on your k8s requirements.

The two modes differ in **who owns the gateway's infrastructure lifecycle**. Your pipeline configuration (sampling, filters, transforms) arrives from the New Relic UI either way. What changes is whether New Relic can also manage the gateway's scaling and version for you.

## `flux/` — Agent Control in Flux mode

- Installs `agent-control-bootstrap` Helm chart (single chart)
- Agent Control installs Flux inside the cluster, and Flux manages the gateway's Deployment and Service
- Replicas, CPU target and gateway version are managed for you from the New Relic UI, and version upgrades are rolled out by New Relic
- **Requires cluster-admin RBAC**, because Flux manages Helm releases cluster-wide

**Use when:** you can grant cluster-admin in this cluster and you want New Relic to manage the gateway's scaling and version.

## `fluxless/` — Agent Control Deployment + gateway chart directly

- Installs TWO Helm charts (no Flux):
  1. `agent-control-deployment`
  2. `pipeline-control-gateway`
- Namespace-scoped RBAC: ConfigMap write in one namespace, no cluster-admin
- Co-locates with other workloads
- You own the gateway's scaling and version, in `pcg-values.yaml` and your own deployment tooling
- The gateway can run as `Deployment` OR `DaemonSet` — controlled by the values.yaml file (no Terraform-level branching)

**Use when:** you need namespace-scoped RBAC, the gateway shares a cluster with other workloads, or your change process requires you to own gateway upgrades.

> **Scaling fields are seeded once.** In Fluxless mode the replica and CPU-target values you enter in the install wizard seed the HPA at install time only. Later changes in the New Relic UI do not reach the cluster, and those fields render read-only with a note that they are Helm-managed. Change them in `pcg-values.yaml` and re-apply.

## Identical out-of-cluster interface

Both modules support the same out-of-cluster flags (`create_alb_ingress`, `create_route53_record`, `pcg_hostname`, `tls_secret_name`, `acm_certificate_arn`, etc.) — drop-in replacements for each other.

Both modules also work for the intra-cluster pattern (leave the `create_*` flags at default false → module just installs the gateway, no external ingress).

## Which to pick

The mode is a property of the **gateway fleet**, and which way round it works depends on whether that fleet already exists.

**Creating a new gateway fleet** (most first-time deployments): you choose the pattern in the install wizard, and the fleet is created using it. So decide from your own constraints. If you want New Relic to manage the gateway's scaling and version for you, and you can grant cluster-admin, choose Flux. If you need namespace-scoped RBAC, or your change process requires you to own gateway upgrades, choose Fluxless.

**Reusing an existing gateway fleet:** the pattern is already fixed by that fleet, and you have to match it. You can tell which one it uses by how many `values.yaml` files the wizard offers:

| Wizard offers | Mode | Module |
|---|---|---|
| One `values.yaml` | Flux | `flux/` |
| Two (`agent-control-deployment` + `pipeline-control-gateway`) | Fluxless | `fluxless/` |

The download count is how you *identify* the mode, not how you choose it.

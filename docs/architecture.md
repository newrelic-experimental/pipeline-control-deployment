# Architecture

The New Relic Pipeline Control gateway is a self-hosted, OpenTelemetry-based collector that receives OTLP and NR-proprietary telemetry from your agents, applies your fleet's data-processing rules, and forwards to New Relic.

This repo deploys the gateway on AWS EKS in one of two topologies. **You pick the topology; the module structure is the same.**

This document is cloud-agnostic: it describes the shape of each topology and the role every component plays. For specific guidance on AWS, see the [AWS deployment guide](../aws/README.md).

## The two topologies

### Intra-cluster

In the intra-cluster pattern, agents and telemetry workloads are deployed in the same k8s cluster as your Pipeline Control gateway. In this pattern, we can use both an in-cluster ingress controller and an in-cluster CA to provide TLS for New Relic APM agents.

This pattern is generally both the simplest and cheapest to deploy. 


```
┌────────────────────── EKS cluster ──────────────────────┐
│                                                         │
│   ┌──────────┐    ┌───────────────┐    ┌─────────────┐  │
│   │  Apps    │───►│ NGINX or Kong │───►│   gateway   │──┼──► New Relic
│   │ (agents) │    │ (in-cluster   │    │ (Deployment)│  │      (443)
│   └──────────┘    │  TLS termin.) │    └─────────────┘  │
│                   └───────────────┘                     │
│                       ▲   ▲                             │
│               ┌───────┘   └────────┐                    │
│               │                    │                    │
│      ┌────────────────┐   ┌──────────────────┐          │
│      │  cert-manager  │   │  internal CA     │          │
│      │  ClusterIssuer │   │  self-signed     │          │
│      └────────────────┘   └──────────────────┘          │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

Traffic path: Apps → in-cluster proxy Service DNS name (e.g. `pcg-nginx.newrelic.svc.cluster.local`) → gateway → New Relic.

Modules involved:

- [`1-vpc`](../aws/1-vpc/) — VPC, subnets, NAT gateways
- [`2-eks`](../aws/2-eks/) — the cluster, its node group, IAM and OIDC
- [`4-dns-tls/cert-manager/4.1-installer`](../aws/4-dns-tls/cert-manager/4.1-installer/) — cert-manager and the internal CA
- [`4-dns-tls/cert-manager/4.3-pcg-certificate`](../aws/4-dns-tls/cert-manager/4.3-pcg-certificate/) — the gateway certificate and CA bundle
- [`3-ingress/reverse-proxy-within-cluster/nginx`](../aws/3-ingress/reverse-proxy-within-cluster/nginx/) or [`kong`](../aws/3-ingress/reverse-proxy-within-cluster/kong/) — the in-cluster proxy
- [`5-pcg/flux`](../aws/5-pcg/flux/) or [`5-pcg/fluxless`](../aws/5-pcg/fluxless/) — Agent Control and the gateway itself

### Out-of-cluster

In the out-of-cluster pattern, agents and telemetry workloads are deployed outside the k8s cluster running your Pipeline Control gateway. In this pattern, we need a resolvable hostname for the gateway, a load balancer in front of it, and a way to distribute CA trust to your agents, because senders outside the cluster cannot use in-cluster Service DNS.

This pattern has more moving parts and costs more to run than intra-cluster, but it is the only option once anything sends telemetry from outside the gateway's cluster. Nothing in the telemetry path is publicly resolvable: the hostname resolves only inside your VPC, and the load balancer is internal.

Senders can be another EKS cluster, EC2 instances, ECS tasks, a peered VPC, or on-prem hosts reaching AWS over Direct Connect or VPN. The diagram below shows a second EKS cluster in the same VPC, which is the case this repo provisions end to end.

```
┌─ sender side (e.g. apps-cluster) ──┐   ┌─ pcg-cluster (EKS) ───────────────┐
│                                    │   │                                   │
│  ┌──────────┐                      │   │  ┌──────────┐   ┌─────────────┐   │
│  │   Apps   │──── HTTPS to ────────┼───┼─►│ internal │──►│   gateway   │───┼──► New Relic
│  │ (agents) │     pcg.internal…    │   │  │   ALB    │   │ (Deployment)│   │      (443)
│  └────┬─────┘                      │   │  └────▲─────┘   └─────────────┘   │
│       │ mounts, to trust           │   │       │                           │
│       │ the server cert            │   │       │ A-record aliases          │
│  ┌────▼─────────┐                  │   │       │ the ALB                   │
│  │ pcg-ca-bundle│                  │   │       │                           │
│  └───────▲──────┘                  │   │       │                           │
└──────────┼─────────────────────────┘   └───────┼───────────────────────────┘
           │      both clusters sit in one VPC   │
           │                                     │
┌──────────┴─────────────────────────┐   ┌───────┴───────────────────────────┐
│ ACM Private CA                     │   │ Route53 private zone              │
│ issues the ALB's server cert; its  │   │ associated with the VPC; resolves │
│ root becomes the bundle apps mount │   │ pcg.internal… inside it only      │
└────────────────────────────────────┘   └───────────────────────────────────┘
```

Traffic path: apps-cluster pod → Route53 private-zone hostname (e.g. `pcg.internal.newrelic`) → internal ALB (TLS with cert from Private CA) → gateway Service → New Relic.

Modules involved:

- [`1-vpc`](../aws/1-vpc/) — the shared VPC, with subnets tagged for both clusters
- [`2-eks`](../aws/2-eks/) — applied **twice** via Terraform workspaces, once per cluster
- [`3-ingress/alb`](../aws/3-ingress/alb/) — the AWS Load Balancer Controller, on the gateway cluster only
- [`4-dns-tls/private/4.1-route53-private-zone`](../aws/4-dns-tls/private/4.1-route53-private-zone/) — the private hosted zone
- [`4-dns-tls/private/4.2-out-of-cluster-tls`](../aws/4-dns-tls/private/4.2-out-of-cluster-tls/) — the Private CA, the server cert, and CA distribution
- [`5-pcg/flux`](../aws/5-pcg/flux/) or [`5-pcg/fluxless`](../aws/5-pcg/fluxless/) — Agent Control, the gateway, the ALB Ingress and the Route53 record

**Optional layered variant:** you can add an in-cluster NGINX or Kong **between** the ALB and the gateway (ALB → proxy → gateway). Useful when you need proxy-layer plugins. Both proxies are validated in this position.

### Out-of-cluster with public DNS (experimental)

Same shape as the private-DNS variant, but with a public Route53 zone and a public ACM certificate, so there is no Private CA and no CA-bundle distribution. **Not validated end to end** — see the limitations in the [root README](../README.md#known-limitations).

## Component walkthrough

| Component | What it does | Why it's needed |
|---|---|---|
| VPC | Network fabric for EKS | EKS worker nodes need a VPC with private subnets in ≥ 2 AZs |
| Private subnets tagged `kubernetes.io/role/internal-elb=1` | Where ALB Controller provisions internal ALBs | AWS ALB Controller uses this tag to discover eligible subnets |
| NAT gateways | Egress for EKS nodes | Nodes must pull container images from public registries (Helm, NR chart, base images) |
| EKS control plane | Kubernetes API + etcd | Managed by AWS; you don't operate it |
| OIDC provider | Identity federation for IRSA | ALB Controller uses IRSA (IAM Roles for Service Accounts) instead of node-role permissions |
| ALB Controller (out-of-cluster) | Watches K8s Ingress objects, provisions AWS ALBs | Bridges Kubernetes and AWS load-balancer APIs |
| cert-manager (intra-cluster) | In-cluster CA + auto-renewing certs | Issues TLS cert for the in-cluster proxy without any public DNS |
| ACM Private CA (out-of-cluster) | AWS-managed private CA | Issues the server cert for the ALB. Bills a flat monthly rate while it exists ([pricing](https://aws.amazon.com/private-ca/pricing/)) |
| Route53 private zone (out-of-cluster) | Private DNS for the gateway hostname | Apps resolve `pcg.internal.newrelic` inside the VPC only |
| CA-bundle Secret in apps-cluster (out-of-cluster) | K8s Secret with `ca.crt` | Apps in apps-cluster mount this to trust the gateway's private cert |
| Agent Control (`5-pcg/*`) | The workload that manages the gateway lifecycle + fleet config | Two modes: `flux/` (Flux-based, cluster-admin) or `fluxless/` (namespace-scoped) |
| Pipeline Control gateway | The actual telemetry collector | Deployment or DaemonSet, configured by the values.yaml you download from the New Relic UI |

## Sizing guidance

Recommended starting point:

- **The gateway requests:** 1 CPU + 2 GiB RAM per pod
- **Minimum replicas:** 2 (for HA)
- **Recommended node type:** `t3.xlarge` or larger (4 vCPU / 16 GiB) — fits 2–3 gateway pods per node comfortably
- **For higher throughput:** scale replicas horizontally (Helm chart supports HPA)

Node pool sizing depends on your telemetry volume. Start with 2× `t3.xlarge` nodes, watch CPU + memory in CloudWatch, scale up if the gateway hits > 70 % sustained CPU.

## Ingress choice matrix

| Pattern | External ingress | In-cluster proxy | TLS terminates at | Use when |
|---|---|---|---|---|
| intra-cluster pure-NGINX | none | NGINX | NGINX | Intra-cluster, cert-manager in charge |
| intra-cluster pure-Kong | none | Kong | Kong | Intra-cluster, you want Kong plugins |
| out-of-cluster direct ALB | ALB (internal) | none | ALB (ACM cert) | Out-of-cluster, no proxy layer needed |
| out-of-cluster ALB + NGINX | ALB (internal) | NGINX (TLS-off) | ALB | Out-of-cluster, and you want NGINX plugins in-cluster |
| out-of-cluster ALB + Kong | ALB (internal) | Kong (TLS-off) | ALB | Out-of-cluster, and your platform already standardises on Kong |

## Gateway install mode: Flux vs Fluxless

Both modes install the same gateway, and the choice is independent of the topology: either mode works with either topology.

The difference is **who owns the gateway's infrastructure lifecycle**. Your pipeline configuration (sampling, filters, transforms) reaches the gateway from the New Relic UI in both modes. What changes is whether New Relic can also manage the gateway's scaling and version for you, or whether that stays with your own deployment tooling.

| | Flux mode (`5-pcg/flux/`) | Fluxless mode (`5-pcg/fluxless/`) |
|---|---|---|
| Pipeline configuration from the New Relic UI | Yes | Yes |
| Replicas and CPU target | Managed for you from the New Relic UI | Yours, in `pcg-values.yaml` |
| Gateway version upgrades | New Relic rolls them out | Your deployment tooling rolls them out |
| RBAC required | cluster-admin | ConfigMap write in one namespace |
| Charts installed | 1 (`agent-control-bootstrap`) | 2 (`agent-control-deployment` + `pipeline-control-gateway`) |
| Installs Flux? | Yes | No |

**One consequence of Fluxless mode worth knowing before you pick it.** The scaling values you enter in the install wizard seed the gateway's HPA once, at install time. Later changes in the New Relic UI do not reach the cluster, and those fields render read-only with a note that they are Helm-managed. Change them in `pcg-values.yaml` and re-apply instead.

The mode belongs to the **gateway fleet**. When you create a new fleet you select the mode in the install wizard and the fleet is created with it. When you reuse an existing fleet, its mode is already set and you match it.

Both modes support out-of-cluster ingress flags identically (`create_alb_ingress`, `create_route53_record`, `pcg_hostname`, `tls_secret_name`, `acm_certificate_arn`, etc.).

## Providers

Almost entirely official HashiCorp providers:

- `hashicorp/aws`
- `hashicorp/kubernetes`, pinned to `~> 2.36` (later 2.x releases have an identity-tracking bug against state written by older providers)
- `hashicorp/helm`
- `hashicorp/tls`
- `hashicorp/time`

The one exception is `gavinbunney/kubectl`, used only by `aws/4-dns-tls/cert-manager/4.1-installer/` to create cert-manager custom resources in the same apply that installs their CRDs. See the [root README](../README.md#known-limitations).

## Where to go next

- [AWS deployment guide](../aws/README.md) — the commands
- [Intra-cluster pattern](pattern-intra-cluster.md) — that topology in depth
- [Out-of-cluster pattern](pattern-out-of-cluster.md) — that topology in depth
- [TLS options](tls-options.md) — choosing a certificate path

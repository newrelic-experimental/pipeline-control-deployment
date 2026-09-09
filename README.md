[![Experimental header](https://github.com/newrelic/opensource-website/raw/main/src/images/categories/Experimental.png)](https://opensource.newrelic.com/oss-category/#new-relic-experimental)

# Pipeline Control gateway — Terraform reference architecture

> **Experimental.** A reference architecture meant as a baseline to adapt, not a supported product. Review and adjust it against your own network, IAM, and security model before any production use.

Terraform modules for deploying the New Relic **Pipeline Control gateway** into your own cloud account. The gateway is a self-hosted, OpenTelemetry-based collector: your agents send to it, it applies your fleet's data-processing rules, and it forwards to New Relic.

The deployment here is complete and works end to end, which makes it a reference you can read and run rather than a product you should ship unmodified. Expect to adapt it: every module accepts bring-your-own inputs, so you can skip any layer you already operate and replace the defaults that do not match how your organization runs AWS.

## Start here

**→ [`aws/README.md`](aws/README.md) — the AWS deployment guide.** Pick one of the two topologies below and follow it end to end.

Read [`docs/architecture.md`](docs/architecture.md) first if you want to understand the shape of the deployment before running anything.

## The two topologies

| | Intra-cluster | Out-of-cluster |
|---|---|---|
| Where the senders are | In the same k8s cluster as the gateway | Outside the gateway's k8s cluster: another cluster, EC2, ECS, on-prem, anywhere that can route to it |
| How senders reach it | In-cluster Service DNS | Private DNS name resolved inside your VPC |
| TLS | cert-manager with an in-cluster CA | ACM Private CA, terminated at an internal load balancer |
| Public exposure of the gateway endpoint | None | None |
| Deep dive | [`docs/pattern-intra-cluster.md`](docs/pattern-intra-cluster.md) | [`docs/pattern-out-of-cluster.md`](docs/pattern-out-of-cluster.md) |

In the intra-cluster pattern, agents and telemetry workloads are deployed in the same k8s cluster as your Pipeline Control gateway. In the out-of-cluster pattern, they are deployed outside it, and reach the gateway over private DNS through an internal load balancer.

Pick on where your telemetry workloads run, not on whether the gateway has a cluster to itself. Intra-cluster is generally the simplest and cheapest to deploy, with fewer moving parts and no load-balancer or private-CA costs. Once anything sends telemetry from outside the gateway's cluster, you need the out-of-cluster path.

## Documentation

| Doc | What's in it |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Diagrams, component-by-component walkthrough, sizing, and the choice matrices for ingress and gateway install mode. Cloud-agnostic. |
| [`docs/pattern-intra-cluster.md`](docs/pattern-intra-cluster.md) | The intra-cluster topology in depth, with verification steps. |
| [`docs/pattern-out-of-cluster.md`](docs/pattern-out-of-cluster.md) | The out-of-cluster topology in depth, including how CA trust is distributed to the apps cluster, and its verification proofs. |
| [`docs/tls-options.md`](docs/tls-options.md) | Decision tree across cert-manager, ACM Private CA, public ACM, and bring-your-own certificates. |
| [`docs/byo-infrastructure.md`](docs/byo-infrastructure.md) | Which modules you can skip when you already have a VPC, cluster, ingress, certificate, or DNS zone. |
| [`docs/cost-guidance.md`](docs/cost-guidance.md) | Which modules drive ongoing cost, and how to avoid the expensive ones. |

## Prerequisites

- Terraform >= 1.0
- AWS CLI, authenticated (`aws sts get-caller-identity` succeeds)
- `kubectl`
- Helm 3
- `jq` and `python3` (used by the helper and test scripts)
- A New Relic ingest license key, and a Pipeline Control fleet configured in the New Relic UI
- Recommended: the New Relic infrastructure agent on the gateway's cluster, for the host metrics the [Pipeline Control gateway quickstart](https://newrelic.com/instant-observability/pipeline-control-gateway) dashboard and alerts read

## Repository layout

```
├── README.md                                   # this file
├── docs/                                       # architecture, patterns, TLS, BYO, cost
└── aws/
    ├── README.md                               # the AWS deployment guide  <- start here
    ├── intra-cluster.tfvars.example                    # shared inputs, intra-cluster
    ├── out-of-cluster-private-dns-pcg.tfvars.example   # shared inputs, gateway side
    ├── out-of-cluster-private-dns-apps.tfvars.example  # shared inputs, apps side
    ├── 1-vpc/                                  # VPC, subnets, NAT gateways
    ├── 2-eks/                                  # EKS cluster, IAM, OIDC provider
    ├── 3-ingress/
    │   ├── alb/                                # AWS Load Balancer Controller
    │   └── reverse-proxy-within-cluster/
    │       ├── nginx/                          # in-cluster NGINX reverse proxy
    │       └── kong/                           # in-cluster Kong reverse proxy
    ├── 4-dns-tls/
    │   ├── cert-manager/                       # in-cluster CA
    │   │   ├── 4.1-installer/                  # cert-manager + ClusterIssuer
    │   │   └── 4.3-pcg-certificate/            # gateway certificate + CA bundle Secret
    │   └── private/                            # private DNS + private CA
    │       ├── 4.1-route53-private-zone/       # private hosted zone
    │       └── 4.2-out-of-cluster-tls/         # ACM Private CA + two-cluster trust
    ├── 5-pcg/
    │   ├── flux/                               # Agent Control, Flux mode
    │   └── fluxless/                           # Agent Control, Fluxless mode
    ├── scripts/                                # deploy.sh + teardown.sh helpers
    └── tests/                                  # send test telemetry through the gateway
```

## Shared variable files

Rather than a `terraform.tfvars` per module, each topology uses one shared file passed to every module with `-var-file`:

- **Intra-cluster:** one file, `aws/intra-cluster.tfvars`.
- **Out-of-cluster:** two files, `aws/out-of-cluster-private-dns-pcg.tfvars` and `aws/out-of-cluster-private-dns-apps.tfvars`. The EKS module is applied twice using Terraform workspaces, once per cluster.

Copy the matching `.example` file to drop the suffix, then edit. Terraform will warn about undeclared variables in individual modules; that is expected and harmless, since one file serves every module.

## Known limitations

- **The Kubernetes provider is pinned to `~> 2.37.1`.** 2.37.0 shipped with a missing `GetResourceIdentitySchemas` implementation that crashed with Terraform >= 1.12.1; 2.37.1 patched it. The `~> 2.37.1` constraint allows any 2.37.x >= 2.37.1 — this is what we've tested; later minors and the 3.x major exist and may be worth adopting later.
- **The EKS module does not manage the `aws-auth` ConfigMap**, so only the identity that created the cluster gets `kubectl` access. Add your own role to that ConfigMap if others need access. See [`aws/2-eks/README.md`](aws/2-eks/README.md#kubectl-access-to-the-cluster).
- **Per-language agent CA-trust configuration is not collected in one place.** Mounting the CA bundle into a pod is covered in the pattern guides, and [`docs/pattern-intra-cluster.md`](docs/pattern-intra-cluster.md) shows the Node.js + Java environment variables inline; a comprehensive per-language reference across Python, Ruby, .NET, Go, and PHP is not gathered yet.
- **The ingest license key and the out-of-cluster TLS private key land in `terraform.tfstate` in plaintext.** Neither the Helm provider nor the `tls` provider supports marking those attributes sensitive. See [`aws/README.md`](aws/README.md#secrets-in-terraform-state) for mitigations (remote backend with encryption, strict IAM on state).

## Support

New Relic Experimental projects are provided without an expectation of ongoing support or maintenance. Issues and pull requests are welcome, but may not receive a timely response.

## License

Apache-2.0. See [`LICENSE`](LICENSE).

This repository declares its dependencies rather than bundling them: Terraform, Helm, and Kubernetes fetch the providers, charts, and images from their own upstream registries at apply time. [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) lists them, along with the one upstream file that is vendored into the tree.

Contributors are expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

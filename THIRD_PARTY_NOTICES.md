# Third-party notices

This repository is licensed under Apache-2.0 (see [`LICENSE`](LICENSE)).

Almost everything listed below is **referenced, not redistributed**. This repository contains Terraform configuration and Kubernetes manifests that declare dependencies; Terraform, Helm, and Kubernetes fetch them from their own upstream registries when you run `terraform init` and `terraform apply`. No provider binary, chart archive, or container image is stored here. The one exception is called out first.

Versions below are the defaults as configured in this repository. Several are overridable, so what you actually deploy may differ.

## Redistributed in this repository

One upstream file is vendored into the tree:

| File | Upstream | Version | License |
|---|---|---|---|
| [`aws/3-ingress/reverse-proxy-within-cluster/kong/kong-crds.yaml`](aws/3-ingress/reverse-proxy-within-cluster/kong/kong-crds.yaml) | [Kong/kubernetes-ingress-controller](https://github.com/Kong/kubernetes-ingress-controller) | v3.1.0 | Apache-2.0 |

It holds the Kong Ingress Controller CustomResourceDefinitions, generated with `kubectl kustomize 'github.com/kong/kubernetes-ingress-controller/config/crd?ref=v3.1.0'` (recorded in the file's own first line). It is vendored rather than fetched so that `terraform apply` does not depend on a network call to GitHub. Refresh instructions are in the Kong module's README.

## Terraform providers

Fetched from the Terraform Registry by `terraform init`.

| Provider | Constraint | License |
|---|---|---|
| [hashicorp/aws](https://github.com/hashicorp/terraform-provider-aws) | `~> 5.0` | MPL-2.0 |
| [hashicorp/kubernetes](https://github.com/hashicorp/terraform-provider-kubernetes) | `~> 2.37.1` | MPL-2.0 |
| [hashicorp/helm](https://github.com/hashicorp/terraform-provider-helm) | `~> 2.17` | MPL-2.0 |
| [hashicorp/tls](https://github.com/hashicorp/terraform-provider-tls) | `~> 4.0` | MPL-2.0 |
| [hashicorp/time](https://github.com/hashicorp/terraform-provider-time) | `~> 0.9` | MPL-2.0 |

All providers are official HashiCorp.

## Helm charts

Fetched from their upstream chart repositories by the `helm` provider during `terraform apply`.

| Chart | Repository | Version as configured | License |
|---|---|---|---|
| `aws-load-balancer-controller` | `https://aws.github.io/eks-charts` | 1.13.0 | Apache-2.0 |
| `cert-manager` | `https://charts.jetstack.io` | v1.14.4 | Apache-2.0 |
| `kong` | `https://charts.konghq.com` | 2.38.0 | Apache-2.0 |
| `agent-control-bootstrap` | `https://helm-charts.newrelic.com` | 1.8.12 (overridable) | Apache-2.0 |
| `agent-control-deployment` | `https://helm-charts.newrelic.com` | 1.7.17 (overridable) | Apache-2.0 |
| `pipeline-control-gateway` | `https://helm-charts.newrelic.com` | 2.5.0 (overridable) | Apache-2.0 |

In Flux install mode, the `agent-control-bootstrap` chart in turn installs [Flux](https://github.com/fluxcd/flux2) (Apache-2.0). This repository does not install Flux directly and does not pin its version.

## Container images

Pulled by Kubernetes at pod start. Each image bundles an operating system layer and further components under their own licenses; the license named here is that of the primary project. A complete component manifest would require scanning the images themselves.

| Image | Where | License of the primary project |
|---|---|---|
| `nginx:1.25-alpine` | default for the NGINX reverse-proxy module | BSD-2-Clause |
| `kong:3.7` | default image tag for the Kong module | Apache-2.0 |
| `node:22-alpine` | the sample application manifests under `aws/tests/` | MIT |
| `curlimages/curl:8.10.1` | the connectivity test scripts | curl license (MIT/X derivative) |
| `busybox` | DNS lookup examples in the documentation only | GPL-2.0 |

Images for cert-manager, the AWS Load Balancer Controller, Agent Control, and the gateway itself are selected by their respective Helm charts and are neither pinned nor overridden here.

## npm packages

Installed at pod start by the sample application manifests in `aws/tests/`. They are not vendored.

| Package | Version | License |
|---|---|---|
| [newrelic](https://github.com/newrelic/node-newrelic) | 14.3.4 | Apache-2.0 |
| [express](https://github.com/expressjs/express) | 4.22.2 | MIT |

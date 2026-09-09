# 3-ingress/ — Ingress options

Ingress choices split by role. Pick based on your topology:

## `alb/` — external AWS ALB (the out-of-cluster pattern)

Installs the AWS Load Balancer Controller. Provisions a real external AWS ALB when an `Ingress` resource is created downstream. Traffic path: **external world → AWS ALB → gateway pod**.

Used when telemetry reaches the gateway from outside the cluster the gateway runs in: workloads on another cluster, on EC2 or ECS, or anywhere else that can route to the load balancer.

## `reverse-proxy-within-cluster/` — intra-cluster reverse proxy

In-cluster reverse proxy that terminates TLS and forwards to the gateway. Traffic path: **app pod → NGINX/Kong pod → gateway pod (all in the same cluster)**.

Used when the workloads sending telemetry run in the same cluster as the gateway.

Pick one:
- **`nginx/`** — static NGINX Deployment, hand-configured
- **`kong/`** — Kong Ingress Controller, dynamic

Not to be confused with `alb/` — these live inside the cluster and don't provision any external LB. See each subdirectory's README.

## Why the split

`alb/` and `reverse-proxy-within-cluster/` are structurally different even though the word "ingress" applies to both. The split makes it visually obvious which one you want. If you're picking between them by category name alone: **external LB → `alb/`. In-cluster proxy → `reverse-proxy-within-cluster/`.**

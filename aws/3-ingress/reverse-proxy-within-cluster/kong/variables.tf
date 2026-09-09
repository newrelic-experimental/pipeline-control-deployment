# Kong Ingress Deployment Variables

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# Kong Configuration
# ─────────────────────────────────────────────────────────────────────────────

variable "namespace" {
  description = "Namespace to install Kong into. Defaults to `newrelic` so Kong lives alongside the gateway."
  type        = string
  default     = "newrelic"
}

variable "release_name" {
  description = "Helm release name"
  type        = string
  default     = "pcg-kong"
}

variable "kong_chart_version" {
  description = "Version of the Kong Helm chart"
  type        = string
  default     = "2.38.0"
}

variable "kong_image_tag" {
  description = "Kong container image tag"
  type        = string
  default     = "3.7"
}

variable "replicas" {
  description = "Number of Kong proxy replicas"
  type        = number
  default     = 2
}

# ─────────────────────────────────────────────────────────────────────────────
# TLS / Hostname
# ─────────────────────────────────────────────────────────────────────────────

variable "tls_secret_name" {
  description = "Name of the Kubernetes Secret holding the gateway TLS cert (from 4.3-pcg-certificate module)"
  type        = string
  default     = "pcg-tls-secret"
}

variable "pcg_hostname" {
  description = "Hostname apps use to reach the gateway (via Kong). Defaults to the k8s-native Service DNS name of the Kong proxy — no CoreDNS trickery needed. If you override `release_name` or `namespace`, update this to match `<release_name>-kong-proxy.<namespace>.svc.cluster.local`."
  type        = string
  default     = "pcg-kong-kong-proxy.newrelic.svc.cluster.local"
}

# ─────────────────────────────────────────────────────────────────────────────
# Gateway Backend Configuration
# ─────────────────────────────────────────────────────────────────────────────

variable "pcg_namespace" {
  description = "Namespace where the gateway is deployed"
  type        = string
  default     = "newrelic"
}

# ─────────────────────────────────────────────────────────────────────────────
# Kong's UPSTREAM = the gateway. These describe the Service that Kong's own K8s
# Ingress resources route to (i.e., where Kong forwards requests). Almost
# always the gateway Service on its default receiver ports.
#
# Naming note: these variables are DELIBERATELY named `pcg_upstream_*` and
# NOT the shorter `pcg_service_name` / `pcg_otlp_http_port` / etc. The
# 5-pcg/{flux,fluxless} modules use the shorter names to describe what
# the ALB Ingress routes to — which in out-of-cluster layered mode is Kong itself,
# not the gateway. Reusing the same tfvars variable name across both modules with
# opposite meanings caused an out-of-cluster layered bug where Kong routed requests
# to its own Service instead of to the gateway.
# ─────────────────────────────────────────────────────────────────────────────
variable "pcg_upstream_service_name" {
  description = "K8s Service name that Kong's own Ingress routes to. Almost always the gateway Service (default 'pipeline-control-gateway'). Do NOT confuse with 5-pcg/*'s pcg_service_name, which describes what the ALB routes to."
  type        = string
  default     = "pipeline-control-gateway"
}

variable "pcg_upstream_otlp_http_port" {
  description = "Gateway OTLP HTTP receiver port (target of Kong's own Ingress routes for /v1/traces, /v1/metrics, /v1/logs)."
  type        = number
  default     = 4318
}

variable "pcg_upstream_otlp_grpc_port" {
  description = "Gateway OTLP gRPC receiver port (target of Kong's own gRPC Ingress)."
  type        = number
  default     = 4317
}

variable "pcg_upstream_nr_receiver_port" {
  description = "Gateway NR-proprietary receiver port (target of Kong's own Ingress routes for /metric/v1, /v1/accounts/events, /agent_listener, /)."
  type        = number
  default     = 80
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

variable "proxy_tls_enabled" {
  description = "Whether Kong's proxy Service exposes port 443 (TLS). Default true (intra-cluster: Kong terminates TLS directly). Set to false when Kong is fronted by an ALB (ALB terminates TLS, ALB→Kong hop uses plain HTTP inside the VPC). When false, kong_tls_ingress is not created either — routing happens via kong_http_ingress on port 80/8000."
  type        = bool
  default     = true
}

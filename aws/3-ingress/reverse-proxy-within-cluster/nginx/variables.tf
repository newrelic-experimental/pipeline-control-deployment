# Custom NGINX Deployment Variables

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# NGINX Configuration
# ─────────────────────────────────────────────────────────────────────────────

variable "namespace" {
  description = "Namespace for NGINX deployment"
  type        = string
  default     = "newrelic"
}

variable "service_name" {
  description = "Name of the NGINX service"
  type        = string
  default     = "pcg-nginx"
}

variable "replicas" {
  description = "Number of NGINX replicas"
  type        = number
  default     = 2
}

variable "nginx_image" {
  description = "NGINX Docker image"
  type        = string
  default     = "nginx:1.25-alpine"
}

variable "resources" {
  description = "Resource requests and limits"
  type = object({
    requests = object({
      cpu    = string
      memory = string
    })
    limits = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    requests = {
      cpu    = "100m"
      memory = "128Mi"
    }
    limits = {
      cpu    = "500m"
      memory = "512Mi"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# TLS Configuration
# ─────────────────────────────────────────────────────────────────────────────

variable "tls_secret_name" {
  description = "Name of the Kubernetes secret containing TLS certificate"
  type        = string
  default     = "pcg-tls-secret"
}

variable "pcg_hostname" {
  description = "Hostname that apps use to reach the gateway. Defaults to the Kubernetes-native Service DNS name — no CoreDNS trickery needed. Used in nginx.conf server_name (for TLS SNI matching) and in outputs shown to apps."
  type        = string
  default     = "pcg-nginx.newrelic.svc.cluster.local"
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
# NGINX's UPSTREAM = the gateway. These are the gateway Service ports that NGINX's
# upstream directives target. Almost always the gateway defaults.
#
# Naming note: `pcg_upstream_*` (not the shorter `pcg_otlp_http_port` etc.)
# is deliberate. 5-pcg/{flux,fluxless} modules use the shorter names to
# describe what the ALB Ingress routes to — which in out-of-cluster layered mode is
# NGINX's Service port, not the gateway's. Reusing the same tfvars variable name
# across both modules with opposite meanings caused an out-of-cluster layered bug
# where Kong routed to its own Service (same class of bug for NGINX if
# the vars were shared).
# ─────────────────────────────────────────────────────────────────────────────
variable "pcg_upstream_service_name" {
  description = "K8s Service name that NGINX's upstream directives forward to. Almost always the gateway Service (default 'pipeline-control-gateway'). Composed with pcg_namespace into the in-cluster FQDN. Do NOT confuse with 5-pcg/*'s pcg_service_name, which describes what the ALB routes to."
  type        = string
  default     = "pipeline-control-gateway"
}

variable "pcg_upstream_otlp_http_port" {
  description = "Gateway OTLP HTTP receiver port (target of NGINX's upstream `pcg_otlp_http` directive)."
  type        = number
  default     = 4318
}

variable "pcg_upstream_otlp_grpc_port" {
  description = "Gateway OTLP gRPC receiver port (target of NGINX's upstream `pcg_otlp_grpc` directive)."
  type        = number
  default     = 4317
}

variable "pcg_upstream_nr_receiver_port" {
  description = "Gateway NR-proprietary receiver port (target of NGINX's upstream `pcg_nr_proprietary` directive)."
  type        = number
  default     = 80
}

variable "pcg_health_port" {
  description = "Gateway health check port"
  type        = number
  default     = 13133
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

variable "nginx_tls_enabled" {
  description = "Whether NGINX exposes port 443 (TLS termination). Default true (intra-cluster: NGINX terminates TLS directly with the cert-manager cert). Set to false when NGINX is fronted by an ALB (ALB terminates TLS, ALB→NGINX hop uses plain HTTP inside the VPC). When false: the 443 server block is omitted from nginx.conf, the tls-certs volume is not mounted, and the Service does not expose port 443."
  type        = bool
  default     = true
}

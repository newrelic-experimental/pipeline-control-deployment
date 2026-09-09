# Gateway Certificate Variables

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# Issuer Configuration
# ─────────────────────────────────────────────────────────────────────────────

variable "issuer_name" {
  description = "Name of the ClusterIssuer or Issuer to use"
  type        = string
  default     = "internal-ca-issuer"
}

variable "issuer_kind" {
  description = "Kind of issuer (ClusterIssuer or Issuer)"
  type        = string
  default     = "ClusterIssuer"
}

# ─────────────────────────────────────────────────────────────────────────────
# Certificate Configuration
# ─────────────────────────────────────────────────────────────────────────────

variable "certificate_name" {
  description = "Name of the Certificate resource"
  type        = string
  default     = "pcg-tls"
}

variable "secret_name" {
  description = "Name of the secret to store the certificate"
  type        = string
  default     = "pcg-tls-secret"
}

variable "certificate_duration" {
  description = "Duration of the certificate (e.g., 8760h = 1 year)"
  type        = string
  default     = "8760h"
}

variable "certificate_renew_before" {
  description = "Renew the certificate before this duration"
  type        = string
  default     = "720h"
}

# ─────────────────────────────────────────────────────────────────────────────
# Domain Configuration
# ─────────────────────────────────────────────────────────────────────────────

variable "internal_domain" {
  description = "Internal domain suffix (e.g., newrelic.internal)"
  type        = string
  default     = "newrelic.internal"
}

variable "pcg_subdomain" {
  description = "Subdomain for the gateway (e.g., pcg -> pcg.newrelic.internal)"
  type        = string
  default     = "pcg"
}

variable "additional_dns_names" {
  description = "Additional DNS names to include in the certificate"
  type        = list(string)
  default     = []
}

# ─────────────────────────────────────────────────────────────────────────────
# Namespace Configuration
# ─────────────────────────────────────────────────────────────────────────────

variable "pcg_namespace" {
  description = "Namespace where the certificate secret will be created"
  type        = string
  default     = "newrelic"
}

variable "create_namespace" {
  description = "Create the gateway namespace if it doesn't exist"
  type        = bool
  default     = true
}

variable "nginx_namespace" {
  description = "Namespace where NGINX will be deployed"
  type        = string
  default     = "newrelic"
}

variable "nginx_service_name" {
  description = "Name of the NGINX Service (from reverse-proxy-within-cluster/nginx). Its k8s DNS name is added to the cert SANs so apps can hit NGINX by that name with valid TLS."
  type        = string
  default     = "pcg-nginx"
}

variable "kong_service_name" {
  description = "Name of the Kong proxy Service (from reverse-proxy-within-cluster/kong). Its k8s DNS name is added to the cert SANs so apps hitting Kong get valid TLS. Kong's Helm chart names its proxy Service `<release_name>-kong-proxy` — default here matches the default release_name of `pcg-kong`."
  type        = string
  default     = "pcg-kong-kong-proxy"
}

variable "kong_namespace" {
  description = "Namespace where Kong is deployed. Defaults to nginx_namespace since intra-cluster deployments typically use one namespace for the reverse proxy (NGINX OR Kong). Override if Kong lives in a different namespace than NGINX would."
  type        = string
  default     = ""
}

# ─────────────────────────────────────────────────────────────────────────────
# CA Bundle Export
# ─────────────────────────────────────────────────────────────────────────────

variable "ca_secret_name" {
  description = "Name of the CA secret (to export CA bundle). Leave empty to skip."
  type        = string
  default     = "internal-ca-secret"
}

variable "ca_secret_namespace" {
  description = "Namespace of the CA secret"
  type        = string
  default     = "cert-manager"
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

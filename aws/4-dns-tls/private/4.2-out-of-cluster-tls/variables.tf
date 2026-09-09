# Out-of-cluster TLS Module Variables

# ─────────────────────────────────────────────────────────────────────────────
# Cluster identity — the module needs BOTH cluster names because it writes
# Secrets to each. Provided by the caller (typically
# out-of-cluster-private-dns-pcg.tfvars).
# ─────────────────────────────────────────────────────────────────────────────

variable "pcg_cluster_name" {
  description = "Name of the EKS cluster that runs the gateway. The server cert Secret is written to this cluster's newrelic namespace."
  type        = string
}

variable "apps_cluster_name" {
  description = "Name of the EKS cluster that runs application workloads. The CA bundle Secret is written to this cluster's apps namespace."
  type        = string
}

variable "aws_region" {
  description = "AWS region where the Private CA is created and both EKS clusters live."
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# Private CA — leave private_ca_arn empty to create a new CA, or provide it
# for BYO (bring your own CA).
# ─────────────────────────────────────────────────────────────────────────────

variable "private_ca_arn" {
  description = "ARN of an existing ACM Private CA to reuse (BYO). Leave empty to create a fresh CA."
  type        = string
  default     = ""
}

variable "ca_common_name" {
  description = "Common Name for the CA's root certificate subject. Only used when creating a new CA."
  type        = string
  default     = "New Relic PCG Root CA"
}

variable "ca_organization" {
  description = "Organization field in the CA cert subject. Only used when creating a new CA."
  type        = string
  default     = "New Relic"
}

variable "ca_country" {
  description = "Country code (ISO 3166-1 alpha-2) in the CA cert subject. Only used when creating a new CA."
  type        = string
  default     = "US"
}

variable "ca_validity_years" {
  description = "Root CA cert validity in years. Only used when creating a new CA. 10 years matches AWS's default."
  type        = number
  default     = 10
}

# ─────────────────────────────────────────────────────────────────────────────
# Server cert (issued FROM the CA, served BY the gateway ALB in the 5-pcg module)
# ─────────────────────────────────────────────────────────────────────────────

variable "pcg_hostname" {
  description = "The hostname apps use to reach the gateway (e.g. 'pcg.internal.newrelic'). This is what the server cert's Common Name + SAN entry will be. Must match the Route53 private zone record 5-pcg creates."
  type        = string
  default     = "pcg.internal.newrelic"
}

variable "cert_validity_days" {
  description = "Server cert validity in days. 397 = max lifespan for public trust; fine for private. Reapply this module to rotate before expiry."
  type        = number
  default     = 397
}

# ─────────────────────────────────────────────────────────────────────────────
# Secret destinations — pcg-cluster side
# ─────────────────────────────────────────────────────────────────────────────

variable "pcg_tls_secret_name" {
  description = "Name of the K8s Secret in pcg-cluster that holds the server TLS cert + key. The ALB Ingress references this via `spec.tls[].secretName`."
  type        = string
  default     = "pcg-tls-secret"
}

variable "pcg_namespace" {
  description = "Namespace in pcg-cluster where the TLS Secret is written. Matches the intra-cluster newrelic namespace by convention."
  type        = string
  default     = "newrelic"
}

variable "create_pcg_namespace" {
  description = "Create the pcg_namespace if it doesn't exist. Set to false if a prior module (e.g. the gateway install module) already creates it."
  type        = bool
  default     = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Secret destinations — apps-cluster side
# ─────────────────────────────────────────────────────────────────────────────

variable "apps_ca_bundle_secret_name" {
  description = "Name of the K8s Secret in apps-cluster that holds the CA root certificate. App pods mount this via init container so their language runtimes trust the gateway's TLS."
  type        = string
  default     = "pcg-ca-bundle"
}

variable "apps_namespace" {
  description = "Namespace in apps-cluster where the CA bundle Secret is written. `default` requires no pre-creation."
  type        = string
  default     = "default"
}

# ─────────────────────────────────────────────────────────────────────────────
# Standard vars
# ─────────────────────────────────────────────────────────────────────────────

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod). Used in default_tags."
  type        = string
  default     = "dev"
}

variable "tags" {
  description = "Additional tags applied to all AWS resources. Merged with default_tags."
  type        = map(string)
  default     = {}
}


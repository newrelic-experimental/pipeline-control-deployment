# cert-manager Cluster Issuer Variables

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "namespace" {
  description = "Namespace where cert-manager is installed. Must match 4.1-installer's namespace so the CA Secret is created in the right place."
  type        = string
  default     = "cert-manager"
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal CA Configuration
# ─────────────────────────────────────────────────────────────────────────────

variable "create_internal_ca" {
  description = "Create a self-signed internal CA and ClusterIssuer. Set to false if you're bringing your own ClusterIssuer via a different mechanism."
  type        = bool
  default     = true
}

variable "ca_name" {
  description = "Name of the CA Certificate resource"
  type        = string
  default     = "internal-ca"
}

variable "ca_secret_name" {
  description = "Name of the Secret cert-manager will populate with the CA cert + key"
  type        = string
  default     = "internal-ca-secret"
}

variable "ca_common_name" {
  description = "Common Name (CN) for the CA certificate subject"
  type        = string
  default     = "Pipeline Control Internal CA"
}

variable "issuer_name" {
  description = "Name of the ClusterIssuer downstream modules will reference to request certs"
  type        = string
  default     = "internal-ca-issuer"
}

variable "tags" {
  description = "Additional tags (informational — no AWS resources are tagged by this module)"
  type        = map(string)
  default     = {}
}

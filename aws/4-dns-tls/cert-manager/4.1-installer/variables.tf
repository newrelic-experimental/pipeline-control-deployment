# Cert Manager Installer Variables
#
# CA-related variables (create_internal_ca, ca_name, ca_secret_name,
# ca_common_name, issuer_name) live in the sibling 4.2-cluster-issuer
# module now.

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "namespace" {
  description = "Namespace for cert-manager"
  type        = string
  default     = "cert-manager"
}

variable "create_namespace" {
  description = "Create the namespace if it doesn't exist"
  type        = bool
  default     = true
}

variable "cert_manager_version" {
  description = "Version of cert-manager Helm chart"
  type        = string
  default     = "v1.14.4"
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

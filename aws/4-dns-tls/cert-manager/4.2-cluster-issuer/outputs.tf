# cert-manager Cluster Issuer Outputs

output "issuer_name" {
  description = "Name of the ClusterIssuer for downstream cert requests"
  value       = var.create_internal_ca ? var.issuer_name : null
}

output "ca_secret_name" {
  description = "Name of the Secret containing the CA cert + key"
  value       = var.create_internal_ca ? var.ca_secret_name : null
}

output "ca_secret_namespace" {
  description = "Namespace of the CA Secret (needed to export the CA bundle)"
  value       = var.namespace
}

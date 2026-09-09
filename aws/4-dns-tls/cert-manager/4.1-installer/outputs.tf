# Cert Manager Installer Outputs

output "namespace" {
  description = "Namespace where cert-manager is installed"
  value       = var.create_namespace ? kubernetes_namespace_v1.cert_manager[0].metadata[0].name : var.namespace
}

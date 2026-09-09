# Gateway Certificate Outputs

output "tls_secret_name" {
  description = "Name of the Kubernetes Secret containing the gateway TLS certificate. Pass to reverse-proxy-within-cluster/nginx as `tls_secret_name`."
  value       = var.secret_name
}

output "tls_secret_namespace" {
  description = "Namespace of the TLS secret"
  value       = var.create_namespace ? kubernetes_namespace_v1.pcg[0].metadata[0].name : var.pcg_namespace
}

output "pcg_fqdn" {
  description = "Full internal FQDN for the gateway (e.g., pcg.newrelic.internal)"
  value       = local.pcg_fqdn
}

output "ca_bundle_secret" {
  description = "Name of the Secret containing CA bundle for app trust. Apps mount this via volumeMount + subPath (ca.crt or pcg-ca.pem)."
  value       = var.ca_secret_name != "" ? kubernetes_secret_v1.ca_bundle[0].metadata[0].name : null
}

output "dns_names" {
  description = "All DNS names included in the certificate"
  value       = local.dns_names
}

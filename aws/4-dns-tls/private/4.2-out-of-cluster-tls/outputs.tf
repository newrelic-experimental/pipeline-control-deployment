# Out-of-cluster TLS Module Outputs

output "ca_arn" {
  description = "ARN of the Private CA (either newly created or BYO). Downstream modules can use this to issue additional certs from the same CA."
  value       = local.ca_arn
}

output "ca_certificate_pem" {
  description = "The CA root certificate as PEM. Same content as apps-cluster's Secret. Useful for one-off verification without kubectl."
  value       = local.ca_cert_pem
  sensitive   = false # public cert material; not sensitive
}

output "pcg_hostname" {
  description = "The hostname the server cert is valid for. The Route53 record and the Ingress spec must use this same name."
  value       = var.pcg_hostname
}

output "pcg_tls_secret_ref" {
  description = "The K8s Secret in pcg-cluster holding the server cert + key. The ALB Ingress references this via `spec.tls[].secretName`."
  value = {
    namespace = kubernetes_secret_v1.pcg_tls.metadata[0].namespace
    name      = kubernetes_secret_v1.pcg_tls.metadata[0].name
  }
}

output "apps_ca_bundle_secret_ref" {
  description = "The K8s Secret in apps-cluster holding the CA root cert. Your application Deployments should mount this via init container or projected volume."
  value = {
    namespace = kubernetes_secret_v1.apps_ca_bundle.metadata[0].namespace
    name      = kubernetes_secret_v1.apps_ca_bundle.metadata[0].name
  }
}

output "server_cert_arn" {
  description = "ARN of the issued server cert in ACM-PCA. Useful for cross-referencing in AWS Console."
  value       = aws_acmpca_certificate.server.arn
}

output "acm_certificate_arn" {
  description = "ARN of the server cert IMPORTED into ACM. This is what the ALB Ingress annotation alb.ingress.kubernetes.io/certificate-arn references. The 5-pcg module needs this."
  value       = aws_acm_certificate.pcg_server_imported.arn
}

output "cost_reminder" {
  description = "Reminder about the ongoing cost of this module's resources."
  value       = var.private_ca_arn == "" ? "⚠ AWS Private CA bills a flat monthly rate whether idle or busy. Run 'terraform destroy' when not actively testing." : "Using BYO CA (${var.private_ca_arn}) — no CA creation cost from this module."
}

# Fluxless gateway Deployment Outputs
#
# Output names match 5-pcg/flux so downstream consumers can swap
# modules without changing their code.

output "pcg_namespace" {
  description = "Namespace where the gateway is deployed"
  value       = var.pcg_namespace
}

output "agent_control_release_name" {
  description = "Name of the Agent Control Helm release"
  value       = helm_release.agent_control.name
}

output "pcg_release_name" {
  description = "Name of the gateway Helm release"
  value       = helm_release.pcg.name
}

# ─────────────────────────────────────────────────────────────────────────────
# Out-of-cluster outputs — null when create_alb_ingress = false
# ─────────────────────────────────────────────────────────────────────────────

output "alb_hostname" {
  description = "The ALB's DNS name (e.g. internal-k8s-newrelic-pcgalb-...eu-west-1.elb.amazonaws.com). Null when create_alb_ingress = false."
  value       = var.create_alb_ingress && var.create_route53_record ? data.kubernetes_ingress_v1.pcg_alb[0].status[0].load_balancer[0].ingress[0].hostname : null
}

output "pcg_url" {
  description = "The full HTTPS URL apps use to reach the gateway. Only meaningful when create_alb_ingress + create_route53_record are both true."
  value       = var.create_alb_ingress ? "https://${var.pcg_hostname}" : null
}

output "route53_record_fqdn" {
  description = "The FQDN of the Route53 A-record created by this module (with trailing dot as Route53 stores it). Null when create_route53_record = false."
  value       = var.create_route53_record ? aws_route53_record.pcg_alias[0].fqdn : null
}

# Gateway Deployment Outputs (Flux mode)

output "agent_control_namespace" {
  description = "Namespace where Agent Control is deployed"
  value       = var.create_agent_control_namespace ? kubernetes_namespace_v1.agent_control[0].metadata[0].name : var.agent_control_namespace
}

output "pcg_namespace" {
  description = "Namespace where the gateway is deployed"
  value       = var.create_pcg_namespace ? kubernetes_namespace_v1.pcg[0].metadata[0].name : var.pcg_namespace
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

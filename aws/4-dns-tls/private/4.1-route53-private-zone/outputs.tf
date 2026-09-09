# Route53 Private Zone Module Outputs

output "zone_id" {
  description = "The Route53 hosted zone ID. The 5-pcg module uses this to create the ALB alias record."
  value       = aws_route53_zone.main.zone_id
}

output "zone_name" {
  description = "The private hosted zone name (e.g. 'internal.newrelic'). the gateway's full hostname will be a subdomain of this."
  value       = aws_route53_zone.main.name
}

output "zone_arn" {
  description = "The zone's ARN. Useful for IAM policies that must scope to a specific hosted zone."
  value       = aws_route53_zone.main.arn
}

output "primary_vpc_id" {
  description = "The primary VPC associated with the zone at creation."
  value       = local.primary_vpc_id
}

output "associated_vpc_ids" {
  description = "All VPCs currently associated with the zone (primary + additional_vpc_ids)."
  value       = concat([local.primary_vpc_id], var.additional_vpc_ids)
}

output "example_pcg_hostname" {
  description = "The hostname apps will use to reach the gateway once 5-pcg creates the DNS record. Deterministic from zone_name — use it to configure agents in advance if desired."
  value       = "pcg.${aws_route53_zone.main.name}"
}

# Route53 Private Zone Module Variables

variable "aws_region" {
  description = "AWS region where the private hosted zone is scoped"
  type        = string
  default     = "us-west-1"
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "Name of the gateway-side cluster. Only used for auto-discovery fallback if vpc_name is empty. Not tied to the zone itself."
  type        = string
  default     = "pcg-cluster"
}

variable "vpc_name" {
  description = "VPC name to look up (matches the '<vpc_name>-vpc' Name tag set by 1-vpc). Leave empty to default to cluster_name. Set to the shared VPC name (e.g. 'pcg-shared') when both clusters share a VPC."
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "Explicit VPC ID for the primary VPC association. Leave empty to auto-discover by vpc_name/cluster_name tag."
  type        = string
  default     = ""
}

variable "additional_vpc_ids" {
  description = "Extra VPC IDs to associate with the private zone. Use when the gateway cluster and apps cluster live in DIFFERENT VPCs. Empty for the same-VPC case (out-of-cluster default)."
  type        = list(string)
  default     = []
}

variable "zone_name" {
  description = "Private hosted zone name (e.g. 'internal.newrelic', 'pcg.internal.acme'). Customer-picked, private-only, no public registration required."
  type        = string
  default     = "internal.newrelic"
}

variable "zone_comment" {
  description = "Description written into the hosted zone's Comment field. Helps operators identify what the zone is for."
  type        = string
  default     = "Private DNS zone for New Relic Pipeline Control gateway (out-of-cluster)"
}

variable "tags" {
  description = "Additional tags applied to the hosted zone. Merged with the provider's default_tags."
  type        = map(string)
  default     = {}
}


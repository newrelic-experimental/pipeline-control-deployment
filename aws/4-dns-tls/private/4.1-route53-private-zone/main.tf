# Route53 Private Hosted Zone Module
#
# Creates a private DNS zone associated with the shared VPC that hosts the gateway
# cluster + apps cluster. The zone is empty at creation — DNS records
# (specifically the A/alias record for the gateway hostname) get added later by
# whichever module provisions the ALB/NLB (the 5-pcg module).
#
#   > "creates a Route 53 private hosted zone associated with the gateway VPC and
#      the apps VPC."
#
# In the current same-VPC layout, "the gateway VPC and the apps VPC" are the same
# VPC. `additional_vpc_ids` exists for the future case where the two clusters
# live in separate VPCs and both need to resolve the gateway hostname.

# VPC discovery (only runs when vpc_id is not provided).
# Same pattern as 2-eks and 3-ingress/alb:
# - vpc_name_lookup defaults to cluster_name for single-cluster setups
# - Set var.vpc_name explicitly when the VPC is shared (e.g. "pcg-shared")
data "aws_vpc" "primary" {
  count = var.vpc_id == "" ? 1 : 0

  tags = {
    Name = "${local.vpc_name_lookup}-vpc"
  }
}

locals {
  vpc_name_lookup = var.vpc_name != "" ? var.vpc_name : var.cluster_name
  primary_vpc_id  = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.primary[0].id
}

# Private hosted zone associated with the primary VPC.
# Route53 requires at least one VPC association at creation; extra VPCs are
# attached below via aws_route53_zone_association resources so Terraform can
# manage them independently of the zone itself.
resource "aws_route53_zone" "main" {
  name          = var.zone_name
  comment       = var.zone_comment
  force_destroy = true

  vpc {
    vpc_id     = local.primary_vpc_id
    vpc_region = var.aws_region
  }

  tags = merge(
    {
      Name = var.zone_name
    },
    var.tags
  )
}

# Attach any extra VPCs (empty by default, when both clusters share one VPC).
resource "aws_route53_zone_association" "extra" {
  for_each = toset(var.additional_vpc_ids)

  zone_id    = aws_route53_zone.main.zone_id
  vpc_id     = each.value
  vpc_region = var.aws_region
}

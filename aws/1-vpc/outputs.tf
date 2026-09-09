# VPC Deployment Module Outputs

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = aws_subnet.public[*].id
}

output "availability_zones" {
  description = "List of availability zones"
  value       = local.azs
}

output "cluster_name" {
  description = "Cluster name for reference"
  value       = var.cluster_name
}

output "vpc_name" {
  description = "VPC name (used in the Name tag). Downstream modules use this to look up the VPC when it hosts multiple clusters."
  value       = local.vpc_name
}

output "shared_cluster_names" {
  description = "List of clusters that share this VPC (from either var.shared_cluster_names or [var.cluster_name])."
  value       = local.shared_cluster_names
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

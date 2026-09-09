# VPC Module Variables

variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "us-west-1"
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "Name of the EKS cluster (used for tagging). For single-cluster setups, this also drives the VPC Name tag. For multi-cluster (2 clusters sharing 1 VPC), set vpc_name + shared_cluster_names instead."
  type        = string
  default     = "pcg-cluster"
}

variable "vpc_name" {
  description = "Name for the VPC (used as the Name tag: '<vpc_name>-vpc'). Leave empty to default to cluster_name. Set explicitly (e.g. 'pcg-shared') when the VPC hosts more than one EKS cluster."
  type        = string
  default     = ""
}

variable "shared_cluster_names" {
  description = "List of EKS cluster names that will share this VPC's subnets. Each name gets a 'kubernetes.io/cluster/<name>=shared' tag on all subnets so both clusters + their ALB Controllers can discover them. Leave empty to default to [cluster_name] for single-cluster use."
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

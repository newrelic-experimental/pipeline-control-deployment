# ALB Controller Module Variables

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
  description = "Name of the EKS cluster from Step 2"
  type        = string
  default     = "pcg-cluster"
}

variable "vpc_id" {
  description = "VPC ID (leave empty to auto-discover by tag)"
  type        = string
  default     = ""
}

variable "vpc_name" {
  description = "VPC name to look up (matches the '<vpc_name>-vpc' Name tag). Leave empty to default to cluster_name. Set explicitly when the VPC is shared across multiple clusters (e.g. 'pcg-shared')."
  type        = string
  default     = ""
}

variable "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL from Step 2 (leave empty to auto-discover)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# IAM Security Variables
variable "permissions_boundary" {
  description = "Optional IAM permissions boundary ARN to attach to IAM roles. Required in some organizations to allow IAM role creation with limited permissions. Example: 'arn:aws:iam::123456789012:policy/resource-provisioner-boundary'. Leave empty if not needed."
  type        = string
  default     = ""
}


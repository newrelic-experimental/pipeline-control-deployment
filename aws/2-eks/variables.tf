# EKS Module Variables

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
  description = "Name of the EKS cluster"
  type        = string
  default     = "pcg-cluster"
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.31"
}

# VPC Configuration - Can be provided or auto-discovered
variable "vpc_id" {
  description = "VPC ID from Step 1 (leave empty to auto-discover by tag)"
  type        = string
  default     = ""
}

variable "vpc_name" {
  description = "VPC name to look up (matches the '<vpc_name>-vpc' Name tag set by 1-vpc). Leave empty to default to cluster_name. Set explicitly when the VPC is shared across multiple clusters (e.g. 'pcg-shared')."
  type        = string
  default     = ""
}

variable "subnet_ids" {
  description = "Private subnet IDs from Step 1 (leave empty to auto-discover)"
  type        = list(string)
  default     = []
}

variable "node_groups" {
  description = "EKS node group configurations"
  type = map(object({
    desired_size   = number
    min_size       = number
    max_size       = number
    instance_types = list(string)
    capacity_type  = string
    disk_size      = number
  }))
  default = {
    general = {
      desired_size   = 2
      min_size       = 1
      max_size       = 4
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
      disk_size      = 20
    }
  }
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# ── Cluster endpoint access ──────────────────────────────────────────────────
# The EKS control plane API can be reachable from the VPC (private) and/or the
# public internet. Defaults preserve historical behavior (both enabled, public
# open to 0.0.0.0/0) so upgrades don't lock existing operators out.
#
# Recommended production posture: endpoint_public_access = false OR
# public_access_cidrs = ["<your-admin-CIDR>/32"]. See aws/2-eks/README.md.

variable "endpoint_private_access" {
  description = "Whether the EKS API is reachable from inside the VPC. Defaults to true. Leave true unless you have a good reason — Terraform itself talks to the API from your workstation, but downstream modules (ALB Controller, cert-manager, pcg install) that run *in* the cluster need this to be true."
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Whether the EKS API is reachable from the public internet. Defaults to true so a fresh apply works from any workstation. Set to false once your workstation IAM is set up to reach the API privately (via VPN, Direct Connect, VPC Peering, etc.) — this is the recommended production posture."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the EKS API from the public internet. Only meaningful when endpoint_public_access = true. Defaults to 0.0.0.0/0 (open). Restrict to your admin CIDR/VPN egress in production: [\"203.0.113.0/24\"]."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# IAM Security Variables
variable "permissions_boundary" {
  description = "Optional IAM permissions boundary ARN to attach to IAM roles. Required in some organizations to allow IAM role creation with limited permissions. Example: 'arn:aws:iam::123456789012:policy/resource-provisioner-boundary'. Leave empty if not needed."
  type        = string
  default     = ""
}


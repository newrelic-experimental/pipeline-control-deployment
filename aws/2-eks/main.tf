# EKS Deployment Module
# Self-contained module for creating EKS cluster

# Get current AWS account ID dynamically
data "aws_caller_identity" "current" {}

# Data sources for VPC discovery (if not provided)
#
# The Name tag comes from 1-vpc's `local.vpc_name`, which defaults to
# `cluster_name` for single-cluster setups but can be overridden to a shared name
# (e.g. "pcg-shared") when 2 clusters live in the same VPC. We do the same
# fallback here so both patterns work with the same module.
data "aws_vpc" "selected" {
  count = var.vpc_id == "" ? 1 : 0

  tags = {
    Name = "${local.vpc_name_lookup}-vpc"
  }
}

data "aws_subnets" "private" {
  count = length(var.subnet_ids) == 0 ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [var.vpc_id != "" ? var.vpc_id : data.aws_vpc.selected[0].id]
  }

  tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

locals {
  vpc_name_lookup = var.vpc_name != "" ? var.vpc_name : var.cluster_name
  vpc_id          = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.selected[0].id
  subnet_ids      = length(var.subnet_ids) > 0 ? var.subnet_ids : data.aws_subnets.private[0].ids
  account_id      = data.aws_caller_identity.current.account_id
  # Permissions boundary is an OPTIONAL IAM guardrail.
  # - If your org requires a specific boundary ARN, set var.permissions_boundary.
  # - Otherwise leave it empty and no boundary is attached (the default for most accounts).
  permissions_boundary = var.permissions_boundary != "" ? var.permissions_boundary : null
}

# IAM Role for EKS Cluster
resource "aws_iam_role" "cluster" {
  name                 = "${var.cluster_name}-cluster-role"
  permissions_boundary = local.permissions_boundary

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })

  tags = merge(
    {
      Name = "${var.cluster_name}-cluster-role"
    },
    var.tags
  )
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSVPCResourceController" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster.name
}

# Security Group for EKS Cluster
resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "Security group for EKS cluster control plane"
  vpc_id      = local.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    {
      Name = "${var.cluster_name}-cluster-sg"
    },
    var.tags
  )
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = local.subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.cluster_AmazonEKSVPCResourceController,
  ]

  tags = merge(
    {
      Name = var.cluster_name
    },
    var.tags
  )
}

# OIDC Provider for IRSA (IAM Roles for Service Accounts)
data "tls_certificate" "cluster" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = merge(
    {
      Name = "${var.cluster_name}-oidc-provider"
    },
    var.tags
  )
}

# IAM Role for Node Groups
resource "aws_iam_role" "node_group" {
  name                 = "${var.cluster_name}-node-group-role"
  permissions_boundary = local.permissions_boundary

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = merge(
    {
      Name = "${var.cluster_name}-node-group-role"
    },
    var.tags
  )
}

resource "aws_iam_role_policy_attachment" "node_group_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_group.name
}

resource "aws_iam_role_policy_attachment" "node_group_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_group.name
}

resource "aws_iam_role_policy_attachment" "node_group_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_group.name
}

# Launch Template for EKS Nodes (for proper EC2 instance tagging)
resource "aws_launch_template" "node_group" {
  for_each = var.node_groups

  name_prefix = "${var.cluster_name}-${each.key}-"
  description = "Launch template for ${var.cluster_name} ${each.key} node group"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = each.value.disk_size
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      {
        Name = "${var.cluster_name}-${each.key}-node"
      },
      var.tags
    )
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(
      {
        Name = "${var.cluster_name}-${each.key}-volume"
      },
      var.tags
    )
  }

  tag_specifications {
    resource_type = "network-interface"
    tags = merge(
      {
        Name = "${var.cluster_name}-${each.key}-eni"
      },
      var.tags
    )
  }

  tags = merge(
    {
      Name = "${var.cluster_name}-${each.key}-lt"
    },
    var.tags
  )
}

# EKS Node Groups
resource "aws_eks_node_group" "main" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-${each.key}"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = local.subnet_ids

  capacity_type  = each.value.capacity_type
  instance_types = each.value.instance_types
  # disk_size is specified in the launch template

  scaling_config {
    desired_size = each.value.desired_size
    max_size     = each.value.max_size
    min_size     = each.value.min_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node_group[each.key].id
    version = "$Latest"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_group_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_group_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_group_AmazonEC2ContainerRegistryReadOnly,
  ]

  tags = merge(
    {
      Name = "${var.cluster_name}-${each.key}"
    },
    var.tags
  )
}

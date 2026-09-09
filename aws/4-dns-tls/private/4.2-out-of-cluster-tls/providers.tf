# Provider configuration for 4.2-out-of-cluster-tls
#
# This is the first module in the repo that touches TWO Kubernetes clusters,
# so it defines TWO `kubernetes` provider instances distinguished by alias.
# Resources declare their target with `provider = kubernetes.pcg` or
# `provider = kubernetes.apps`.

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  # For restricted-IAM environments, run `aws sts assume-role` in your shell
  # before running terraform. See aws/README.md.

  default_tags {
    tags = merge(
      {
        Environment = var.environment
        Project     = "pipeline-control-gateway"
        ManagedBy   = "terraform"
        Component   = "out-of-cluster-tls"
      },
      var.tags
    )
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Cluster discovery — one data source pair per cluster
# ─────────────────────────────────────────────────────────────────────────────

data "aws_eks_cluster" "pcg" {
  name = var.pcg_cluster_name
}

data "aws_eks_cluster_auth" "pcg" {
  name = var.pcg_cluster_name
}

data "aws_eks_cluster" "apps" {
  name = var.apps_cluster_name
}

data "aws_eks_cluster_auth" "apps" {
  name = var.apps_cluster_name
}

# ─────────────────────────────────────────────────────────────────────────────
# Kubernetes provider — pcg-cluster
# ─────────────────────────────────────────────────────────────────────────────

provider "kubernetes" {
  alias                  = "pcg"
  host                   = data.aws_eks_cluster.pcg.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.pcg.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.pcg.token
}

# ─────────────────────────────────────────────────────────────────────────────
# Kubernetes provider — apps-cluster
# ─────────────────────────────────────────────────────────────────────────────

provider "kubernetes" {
  alias                  = "apps"
  host                   = data.aws_eks_cluster.apps.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.apps.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.apps.token
}

# Provider configuration for EKS deployment module

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Optional: Remote state backend for production
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "pcg/eks/terraform.tfstate"
  #   region = "us-west-1"
  # }
}

provider "aws" {
  region = var.aws_region
  # profile can be set via AWS_PROFILE environment variable or AWS credentials configuration
  # For restricted-IAM environments where your default role lacks iam:CreateRole,
  # run `aws sts assume-role` in your shell and export the temp credentials
  # BEFORE running terraform. See aws/README.md.

  default_tags {
    tags = merge(
      {
        Environment = var.environment
        Project     = "pipeline-control-gateway"
        ManagedBy   = "terraform"
        Component   = "eks"
      },
      var.tags
    )
  }
}

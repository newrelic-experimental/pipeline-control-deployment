# Provider configuration for the Route53 private zone module

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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
        Component   = "route53-private-zone"
      },
      var.tags
    )
  }
}

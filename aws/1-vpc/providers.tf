# Provider configuration for VPC module

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Optional: Remote state backend for production
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "pcg/vpc/terraform.tfstate"
  #   region = "us-west-1"
  # }
}

provider "aws" {
  region = var.aws_region
  # profile can be set via AWS_PROFILE environment variable or AWS credentials configuration

  default_tags {
    tags = merge(
      {
        Environment = var.environment
        Project     = "pipeline-control-gateway"
        ManagedBy   = "terraform"
        Component   = "vpc"
      },
      var.tags
    )
  }
}

# ALB Controller Deployment Module Outputs

output "alb_controller_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller"
  value       = aws_iam_role.alb_controller.arn
}

output "alb_controller_namespace" {
  description = "Kubernetes namespace where ALB controller is installed"
  value       = "kube-system"
}

output "alb_controller_service_account" {
  description = "Name of the Kubernetes service account"
  value       = kubernetes_service_account.alb_controller.metadata[0].name
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = var.cluster_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = local.vpc_id
}

# Custom NGINX Deployment Outputs

output "service_name" {
  description = "Name of the NGINX service"
  value       = kubernetes_service_v1.nginx.metadata[0].name
}

output "service_namespace" {
  description = "Namespace of the NGINX service"
  value       = kubernetes_service_v1.nginx.metadata[0].namespace
}

output "cluster_ip" {
  description = "ClusterIP of the NGINX service"
  value       = kubernetes_service_v1.nginx.spec[0].cluster_ip
}

output "http_endpoint" {
  description = "HTTP endpoint for NGINX"
  value       = "${kubernetes_service_v1.nginx.metadata[0].name}.${var.namespace}.svc.cluster.local:80"
}

output "https_endpoint" {
  description = "HTTPS endpoint for NGINX"
  value       = "${kubernetes_service_v1.nginx.metadata[0].name}.${var.namespace}.svc.cluster.local:443"
}

output "grpc_endpoint" {
  description = "gRPC endpoint for NGINX"
  value       = "${kubernetes_service_v1.nginx.metadata[0].name}.${var.namespace}.svc.cluster.local:4317"
}

output "pcg_hostname" {
  description = "Kubernetes-native Service DNS name apps use to reach the gateway (via NGINX). Resolvable inside the cluster with no CoreDNS trickery."
  value       = var.pcg_hostname
}

output "pcg_https_url" {
  description = "HTTPS URL for the gateway (via NGINX TLS termination)"
  value       = "https://${var.pcg_hostname}"
}

output "pcg_grpc_endpoint" {
  description = "gRPC endpoint for the gateway (via NGINX, port 4317)"
  value       = "${var.pcg_hostname}:4317"
}

output "agent_config_example" {
  description = "Example NR agent configuration for apps in this cluster"
  value       = <<-EOT
    # Add to your app deployment:
    env:
      - name: NEW_RELIC_HOST
        value: "${var.pcg_hostname}"
      - name: NEW_RELIC_PORT
        value: "443"
    # If using OTLP exporter:
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: "https://${var.pcg_hostname}:443"   # or "${var.pcg_hostname}:4317" for gRPC
    # Mount the CA bundle (Secret pcg-ca-bundle in 'newrelic' namespace):
      - name: NODE_EXTRA_CA_CERTS
        value: "/etc/ssl/certs/pcg-ca.crt"
  EOT
}

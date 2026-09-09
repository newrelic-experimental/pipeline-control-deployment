# Kong Ingress Deployment Outputs

output "namespace" {
  description = "Namespace where Kong is installed"
  value       = var.namespace
}

output "release_name" {
  description = "Helm release name"
  value       = helm_release.kong.name
}

output "ingress_class" {
  description = "IngressClass name (annotate app Ingress resources with this)"
  value       = "kong"
}

output "proxy_service_name" {
  description = "Name of the Kong proxy Service (Kong Helm chart convention: <release>-kong-proxy). Use this + namespace to build the k8s Service DNS name apps hit."
  value       = "${var.release_name}-kong-proxy"
}

output "pcg_hostname" {
  description = "Kubernetes-native Service DNS name apps use to reach the gateway (via Kong). Resolvable inside the cluster with no CoreDNS trickery."
  value       = var.pcg_hostname
}

output "pcg_https_url" {
  description = "HTTPS URL for the gateway (via Kong TLS termination)"
  value       = "https://${var.pcg_hostname}"
}

output "pcg_grpc_endpoint" {
  description = "gRPC endpoint for the gateway (via Kong, port 443 with grpcs protocol)"
  value       = "${var.pcg_hostname}:443"
}

output "agent_config_example" {
  description = "Example NR agent configuration for apps in this cluster"
  value       = <<-EOT
    env:
      - name: NEW_RELIC_HOST
        value: "${var.pcg_hostname}"
      - name: NEW_RELIC_PORT
        value: "443"
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: "https://${var.pcg_hostname}:443"
      - name: NODE_EXTRA_CA_CERTS
        value: "/etc/ssl/certs/pcg-ca.crt"
  EOT
}

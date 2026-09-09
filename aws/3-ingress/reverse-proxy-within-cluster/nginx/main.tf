# Custom NGINX Deployment Module
# Deploys custom NGINX proxy for the gateway with gRPC support
# Uses your nginx.conf template with proper routing for NR agents

# ─────────────────────────────────────────────────────────────────────────────
# Data Sources - EKS Cluster Discovery
# ─────────────────────────────────────────────────────────────────────────────

data "aws_eks_cluster" "selected" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "selected" {
  name = var.cluster_name
}

locals {
  common_labels = {
    "app.kubernetes.io/name"       = "pcg-nginx"
    "app.kubernetes.io/component"  = "proxy"
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/part-of"    = "pipeline-control-gateway"
  }

  # Gateway backend service
  pcg_service = "${var.pcg_upstream_service_name}.${var.pcg_namespace}.svc.cluster.local"

  # HTTPS server block — only included when nginx_tls_enabled = true.
  # In out-of-cluster (ALB-fronted), ALB terminates TLS with the ACM cert and forwards
  # plain HTTP to NGINX on port 80. NGINX has no TLS cert to load in that mode.
  #
  # Note: port-80 server block below already handles all paths in both modes.
  # The 443 block is only added when NGINX itself needs to terminate TLS.
  https_server_block_full = <<-EOT
    # Port 443 - HTTPS endpoints (TLS termination)
    server {
        listen 443 ssl;
        http2 on;
        server_name ${var.pcg_hostname} localhost;

        ssl_certificate /etc/nginx/certs/tls.crt;
        ssl_certificate_key /etc/nginx/certs/tls.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;

        # Health check — static response (see Port 80 server block)
        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }

        # OTLP HTTP endpoints
        location /v1/traces {
            proxy_pass http://pcg_otlp_http;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location /v1/metrics {
            proxy_pass http://pcg_otlp_http;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location /v1/logs {
            proxy_pass http://pcg_otlp_http;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # NR metric ingest endpoint
        location /metric/v1 {
            proxy_pass http://pcg_nr_proprietary;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # NR events ingest endpoint
        location /v1/accounts/events {
            proxy_pass http://pcg_nr_proprietary;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # NR agent listener
        location /agent_listener {
            proxy_pass http://pcg_nr_proprietary;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # Default - NR proprietary
        location / {
            proxy_pass http://pcg_nr_proprietary;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
    EOT

  nginx_https_server_block = var.nginx_tls_enabled ? local.https_server_block_full : ""
}

# ─────────────────────────────────────────────────────────────────────────────
# NGINX ConfigMap
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_config_map_v1" "nginx_config" {
  metadata {
    name      = "pcg-nginx-config"
    namespace = var.namespace
    labels    = local.common_labels
  }

  data = {
    "nginx.conf" = <<-EOF
      worker_processes auto;
      error_log /var/log/nginx/error.log warn;
      pid /tmp/nginx.pid;

      events {
          worker_connections 1024;
      }

      http {
          include       /etc/nginx/mime.types;
          default_type  application/octet-stream;

          log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                          '$status $body_bytes_sent "$http_referer" '
                          '"$http_user_agent" "$http_x_forwarded_for"';

          access_log /var/log/nginx/access.log main;
          sendfile on;
          keepalive_timeout 65;

          # Upstream definitions
          upstream pcg_otlp_http {
              server ${local.pcg_service}:${var.pcg_upstream_otlp_http_port};
          }

          upstream pcg_otlp_grpc {
              server ${local.pcg_service}:${var.pcg_upstream_otlp_grpc_port};
          }

          upstream pcg_nr_proprietary {
              server ${local.pcg_service}:${var.pcg_upstream_nr_receiver_port};
          }

          # Port 80 - HTTP endpoints (OTLP HTTP + NR proprietary)
          # In ALB-fronted mode this is the only server block used; ALB
          # terminates TLS and forwards HTTP to NGINX on 80. In intra-cluster mode this
          # block is still enabled for local health checks / diagnostics.
          server {
              listen 80;
              server_name ${var.pcg_hostname} localhost;

              # Health check — static response from NGINX itself.
              # The kubelet probe only needs to know NGINX is up; checking the gateway's
              # health is a separate concern (and the gateway's health port isn't
              # exposed via the cluster Service anyway).
              location /health {
                  access_log off;
                  return 200 "healthy\n";
                  add_header Content-Type text/plain;
              }

              # OTLP HTTP endpoints
              location /v1/traces {
                  proxy_pass http://pcg_otlp_http;
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto $scheme;
              }

              location /v1/metrics {
                  proxy_pass http://pcg_otlp_http;
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto $scheme;
              }

              location /v1/logs {
                  proxy_pass http://pcg_otlp_http;
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto $scheme;
              }

              # NR metric ingest endpoint (used in ALB-fronted mode; harmless in intra-cluster)
              location /metric/v1 {
                  proxy_pass http://pcg_nr_proprietary;
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto $scheme;
              }

              # NR events ingest endpoint (used in ALB-fronted mode)
              location /v1/accounts/events {
                  proxy_pass http://pcg_nr_proprietary;
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto $scheme;
              }

              # NR agent listener (used in ALB-fronted mode)
              location /agent_listener {
                  proxy_pass http://pcg_nr_proprietary;
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto $scheme;
              }

              # Default - NR proprietary agent traffic
              location / {
                  proxy_pass http://pcg_nr_proprietary;
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto $scheme;
              }
          }

${local.nginx_https_server_block}

          # Port 4317 - OTLP gRPC (separate server block)
          server {
              listen 4317;
              http2 on;
              server_name ${var.pcg_hostname} localhost;

              location / {
                  grpc_pass grpc://pcg_otlp_grpc;
                  grpc_set_header Host $host;
                  grpc_set_header X-Real-IP $remote_addr;
                  grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              }
          }
      }
    EOF
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# NGINX Deployment
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "nginx" {
  metadata {
    name      = var.service_name
    namespace = var.namespace
    labels    = local.common_labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "pcg-nginx"
      }
    }

    template {
      metadata {
        labels = local.common_labels
        annotations = {
          "checksum/config" = sha256(kubernetes_config_map_v1.nginx_config.data["nginx.conf"])
        }
      }

      spec {
        container {
          name  = "nginx"
          image = var.nginx_image

          port {
            name           = "http"
            container_port = 80
            protocol       = "TCP"
          }

          # HTTPS container port — omitted in ALB-fronted mode (nginx_tls_enabled=false)
          dynamic "port" {
            for_each = var.nginx_tls_enabled ? [1] : []
            content {
              name           = "https"
              container_port = 443
              protocol       = "TCP"
            }
          }

          port {
            name           = "grpc"
            container_port = 4317
            protocol       = "TCP"
          }

          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
            read_only  = true
          }

          # TLS cert mount — omitted in ALB-fronted mode. If mounted with no
          # pcg-tls-secret to back it, the Pod would fail to start.
          dynamic "volume_mount" {
            for_each = var.nginx_tls_enabled ? [1] : []
            content {
              name       = "tls-certs"
              mount_path = "/etc/nginx/certs"
              read_only  = true
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          volume_mount {
            name       = "var-log"
            mount_path = "/var/log/nginx"
          }

          # nginx:alpine writes proxy/client/fastcgi temp files here on startup.
          # With read_only_root_filesystem=true, we must mount an emptyDir
          # so the cache dirs are writable.
          volume_mount {
            name       = "var-cache"
            mount_path = "/var/cache/nginx"
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 80
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          resources {
            requests = {
              cpu    = var.resources.requests.cpu
              memory = var.resources.requests.memory
            }
            limits = {
              cpu    = var.resources.limits.cpu
              memory = var.resources.limits.memory
            }
          }

          security_context {
            run_as_non_root            = true
            run_as_user                = 101
            read_only_root_filesystem  = true
            allow_privilege_escalation = false
          }
        }

        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map_v1.nginx_config.metadata[0].name
          }
        }

        # Corresponding volume for the TLS cert Secret. Same conditional.
        dynamic "volume" {
          for_each = var.nginx_tls_enabled ? [1] : []
          content {
            name = "tls-certs"
            secret {
              secret_name = var.tls_secret_name
            }
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }

        volume {
          name = "var-cache"
          empty_dir {}
        }

        volume {
          name = "var-log"
          empty_dir {}
        }
      }
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# NGINX Service
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_service_v1" "nginx" {
  metadata {
    name      = var.service_name
    namespace = var.namespace
    labels    = local.common_labels
  }

  spec {
    type = "ClusterIP"

    selector = {
      "app.kubernetes.io/name" = "pcg-nginx"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 80
      protocol    = "TCP"
    }

    # HTTPS Service port — omitted in ALB-fronted mode (nginx_tls_enabled=false)
    dynamic "port" {
      for_each = var.nginx_tls_enabled ? [1] : []
      content {
        name        = "https"
        port        = 443
        target_port = 443
        protocol    = "TCP"
      }
    }

    port {
      name        = "grpc"
      port        = 4317
      target_port = 4317
      protocol    = "TCP"
    }
  }
}

# NOTE: We do NOT patch CoreDNS.
#
# Apps in the cluster reach the gateway directly via the Kubernetes-native Service DNS
# name — `pcg-nginx.newrelic.svc.cluster.local` (or `<service>.<ns>` short form).
# This is the standard k8s service-DNS mechanism, no per-cluster DNS rewriting
# needed.
#
# The 4.3-pcg-certificate module already includes these Service DNS names in the
# TLS certificate's SANs, so TLS termination on NGINX works against the same
# hostname the apps resolve.
#
# Removed: previous versions of this module patched the main coredns ConfigMap
# to add a newrelic.internal:53 block so apps could use `pcg.newrelic.internal`.
# That approach had a real destroy-safety bug: on `terraform destroy` the
# Corefile key was removed from the ConfigMap, breaking cluster-wide DNS until
# a manual kubectl-patch restored the EKS default. Using service DNS avoids
# the class of bug entirely — and is what the intra-cluster design
# calls for.

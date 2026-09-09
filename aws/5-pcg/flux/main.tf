# Gateway Deployment Module (Flux mode)
# Deploys Pipeline Control gateway using Agent Control Bootstrap.
# Apps reach the gateway via k8s Service DNS (`pipeline-control-gateway.newrelic.svc.cluster.local`)
# (apply order: this module first, then reverse-proxy-within-cluster/nginx).

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
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/part-of"    = "pipeline-control-gateway"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Namespaces
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "agent_control" {
  count = var.create_agent_control_namespace ? 1 : 0

  metadata {
    name = var.agent_control_namespace
    labels = merge(local.common_labels, {
      name = var.agent_control_namespace
    })
  }
}

# NOTE: The gateway namespace (`newrelic`) is owned by the `4.3-pcg-certificate` module
# (Step 4) — it creates the namespace so it can put the TLS Secret there. This
# module intentionally does NOT create it by default. Set
# `create_pcg_namespace = true` only if you're skipping Step 4 or bringing your
# own TLS setup that doesn't create the namespace.
resource "kubernetes_namespace_v1" "pcg" {
  count = var.create_pcg_namespace ? 1 : 0

  metadata {
    name = var.pcg_namespace
    labels = merge(local.common_labels, {
      name = var.pcg_namespace
    })
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Agent Control Bootstrap (deploys the gateway via Flux)
# ─────────────────────────────────────────────────────────────────────────────

resource "helm_release" "agent_control_bootstrap" {
  name       = "agent-control-bootstrap"
  repository = "https://helm-charts.newrelic.com"
  chart      = "agent-control-bootstrap"
  version    = var.agent_control_bootstrap_chart_version != "" ? var.agent_control_bootstrap_chart_version : null
  namespace  = var.create_agent_control_namespace ? kubernetes_namespace_v1.agent_control[0].metadata[0].name : var.agent_control_namespace

  values = [file(var.pcg_values_file)]

  timeout = 600
  wait    = true

  depends_on = [
    kubernetes_namespace_v1.agent_control,
    kubernetes_namespace_v1.pcg
  ]
}

# Wait for Flux to deploy gateway collector
resource "time_sleep" "wait_for_pcg" {
  depends_on      = [helm_release.agent_control_bootstrap]
  create_duration = var.pcg_wait_duration
}

# Note: pcg-ca-bundle Secret is created by 4.3-pcg-certificate (it owns the CA secret).
# Apps mount that Secret from the `newrelic` namespace.

# ─────────────────────────────────────────────────────────────────────────────
# Out-of-cluster — ALB Ingress + Route53 alias record
#
# All conditional on create_alb_ingress / create_route53_record. Intra-cluster
# users leave these vars at default (false) and see no diff.
#
# Prereqs: (checked implicitly at apply time)
#   - AWS Load Balancer Controller installed on this cluster (3-ingress/alb)
#   - pcg-tls-secret exists in pcg_namespace (created by 4.2-out-of-cluster-tls)
#   - gateway Service is up (waited for above via time_sleep.wait_for_pcg)
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_ingress_v1" "pcg_alb" {
  count = var.create_alb_ingress ? 1 : 0

  metadata {
    name      = "pcg-alb"
    namespace = var.create_pcg_namespace ? kubernetes_namespace_v1.pcg[0].metadata[0].name : var.pcg_namespace
    labels    = local.common_labels

    annotations = {
      # ALB scheme — "internal" for private-only (out-of-cluster default)
      "alb.ingress.kubernetes.io/scheme" = var.alb_scheme

      # target-type ip = ALB targets pod IPs directly instead of NodePorts.
      # Cheaper (skips a kube-proxy hop) and required for Fargate; fine on EC2 too.
      "alb.ingress.kubernetes.io/target-type" = "ip"

      # Listen on HTTPS:443 only. HTTP:80 could be added if you want redirects,
      # but internal traffic should already be HTTPS.
      "alb.ingress.kubernetes.io/listen-ports" = jsonencode([{ HTTPS = 443 }])

      # Force HTTPS. Any HTTP request gets 301 to HTTPS. Only relevant if you
      # also listen on 80, but harmless here.
      "alb.ingress.kubernetes.io/ssl-redirect" = "443"

      # Backend protocol between ALB and gateway pods is plain HTTP. TLS terminates
      # at the ALB using the cert from spec.tls[].secretName.
      "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"

      # Health check config — the gateway doesn't have a dedicated /health handler on the
      # NR proprietary port (it just returns "unknown request" for /health).
      # Accepting 200,404 as healthy prevents endless log spam while still
      # verifying the pod responds to HTTP. A cleaner fix would use
      # the gateway's OTel Collector health_check extension.
      "alb.ingress.kubernetes.io/healthcheck-port"             = tostring(var.pcg_nr_receiver_port)
      "alb.ingress.kubernetes.io/healthcheck-path"             = "/health"
      "alb.ingress.kubernetes.io/healthcheck-protocol"         = "HTTP"
      "alb.ingress.kubernetes.io/success-codes"                = "200,404"
      "alb.ingress.kubernetes.io/healthcheck-interval-seconds" = "30"

      # TLS certificate ARN — REQUIRED for ALB. AWS ALB does not read K8s TLS
      # Secrets; it needs the cert in ACM referenced by ARN. This ARN comes from
      # the `acm_certificate_arn` output of 4.2-out-of-cluster-tls.
      "alb.ingress.kubernetes.io/certificate-arn" = var.acm_certificate_arn
    }
  }

  spec {
    ingress_class_name = "alb"

    tls {
      hosts       = [var.pcg_hostname]
      secret_name = var.tls_secret_name
    }

    rule {
      host = var.pcg_hostname

      http {
        # OTLP HTTP endpoints → gateway:4318
        path {
          path      = "/v1/traces"
          path_type = "Prefix"
          backend {
            service {
              name = var.pcg_service_name
              port { number = var.pcg_otlp_http_port }
            }
          }
        }
        path {
          path      = "/v1/metrics"
          path_type = "Prefix"
          backend {
            service {
              name = var.pcg_service_name
              port { number = var.pcg_otlp_http_port }
            }
          }
        }
        path {
          path      = "/v1/logs"
          path_type = "Prefix"
          backend {
            service {
              name = var.pcg_service_name
              port { number = var.pcg_otlp_http_port }
            }
          }
        }

        # NR proprietary endpoints → gateway:80
        path {
          path      = "/metric/v1"
          path_type = "Prefix"
          backend {
            service {
              name = var.pcg_service_name
              port { number = var.pcg_nr_receiver_port }
            }
          }
        }
        path {
          path      = "/v1/accounts/events"
          path_type = "Prefix"
          backend {
            service {
              name = var.pcg_service_name
              port { number = var.pcg_nr_receiver_port }
            }
          }
        }
        path {
          path      = "/agent_listener"
          path_type = "Prefix"
          backend {
            service {
              name = var.pcg_service_name
              port { number = var.pcg_nr_receiver_port }
            }
          }
        }

        # Catch-all → gateway:80 (NR proprietary)
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = var.pcg_service_name
              port { number = var.pcg_nr_receiver_port }
            }
          }
        }
      }
    }
  }

  # Note: gRPC (gateway:4317) is NOT included here. AWS ALB gRPC support requires
  # a separate target group + backend-protocol-version annotation, deferred
  # (the Kong variant handles gRPC natively).

  depends_on = [time_sleep.wait_for_pcg]
}

# ALB Controller provisions the AWS ALB asynchronously after the Ingress is
# created. Wait for the ALB to come up before reading its hostname.
#
# The `triggers` map forces time_sleep to re-run whenever the Ingress's key
# annotations change — otherwise a second apply that changes the Ingress
# (e.g., adding certificate-arn) won't wait for ALB reconciliation and the
# subsequent data source read finds an empty status.
resource "time_sleep" "wait_for_alb" {
  count           = var.create_alb_ingress ? 1 : 0
  depends_on      = [kubernetes_ingress_v1.pcg_alb]
  create_duration = var.alb_wait_duration

  triggers = {
    ingress_resource_version = kubernetes_ingress_v1.pcg_alb[0].metadata[0].resource_version
    certificate_arn          = var.acm_certificate_arn
  }
}

# Read the Ingress back to get the ALB hostname that ALB Controller populated
# in ingress.status.loadBalancer.ingress[].hostname.
data "kubernetes_ingress_v1" "pcg_alb" {
  count = var.create_alb_ingress && var.create_route53_record ? 1 : 0

  metadata {
    name      = kubernetes_ingress_v1.pcg_alb[0].metadata[0].name
    namespace = kubernetes_ingress_v1.pcg_alb[0].metadata[0].namespace
  }

  depends_on = [time_sleep.wait_for_alb]
}

# AWS-provided data source: returns the canonical hosted zone ID for
# Application Load Balancers in the current region. Used as the alias target's
# zone_id — this is an AWS constant, not our own Route53 zone.
data "aws_elb_hosted_zone_id" "current" {
  count = var.create_route53_record ? 1 : 0
}

# Route53 A-record for pcg.internal.newrelic aliased to the ALB.
# Aliases (unlike CNAMEs) can be at the zone apex and don't count against
# query costs when resolved from within AWS.
resource "aws_route53_record" "pcg_alias" {
  count = var.create_route53_record ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.pcg_hostname
  type    = "A"

  alias {
    name                   = data.kubernetes_ingress_v1.pcg_alb[0].status[0].load_balancer[0].ingress[0].hostname
    zone_id                = data.aws_elb_hosted_zone_id.current[0].id
    evaluate_target_health = true
  }
}

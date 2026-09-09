# Kong Ingress Deployment Module
#
# Intra-cluster Kong ingress as an ALTERNATIVE to reverse-proxy-within-cluster/nginx.
# Deploys Kong in DB-less mode with ClusterIP service, TLS termination
# using the 4.3-pcg-certificate module's Secret, and Kubernetes Ingress
# resources routing to the gateway's 3 protocol ports.
#
# Mutually exclusive with reverse-proxy-within-cluster/nginx — use one or the other.

locals {
  common_labels = {
    "app.kubernetes.io/name"       = "pcg-kong"
    "app.kubernetes.io/component"  = "ingress"
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/part-of"    = "pipeline-control-gateway"
  }

  pcg_service_fqdn = "${var.pcg_upstream_service_name}.${var.pcg_namespace}.svc.cluster.local"

  # Kong CRDs vendored from the pinned chart version.
  #
  # WHY VENDORED, NOT INSTALLED VIA HELM:
  # Kong's Helm chart installs CRDs through a pre-install hook that does NOT
  # attach Helm ownership labels. Helm's post-install ownership check then
  # rejects the CRDs it just created — first `terraform apply` fails with
  # "invalid ownership metadata; label validation error: missing key
  # app.kubernetes.io/managed-by". A dedicated CRD-only Helm release hits the
  # same wall (hook behavior is per-chart, not per-release).
  #
  # Fix: apply the CRD YAML directly via kubernetes_manifest, entirely outside
  # Helm. Terraform owns the CRDs cleanly. The main Kong Helm release then
  # runs with `installCRDs = false` and references the already-existing CRDs.
  #
  # kong-crds.yaml was copied from
  #   https://raw.githubusercontent.com/Kong/charts/kong-2.38.0/charts/kong/crds/custom-resource-definitions.yaml
  # When bumping `kong_chart_version`, refresh this file from the matching
  # chart tag.
  # Split on `\n---\n` (a YAML doc separator on its own line), NOT bare "---",
  # because the CRD schemas' description fields contain literal "---" strings
  # (kubebuilder-generated boilerplate). A bare split on "---" would shred CRDs
  # into fragments mid-schema.
  kong_crd_docs = [
    for doc in split("\n---\n", file("${path.module}/kong-crds.yaml")) :
    yamldecode(doc)
    if length(trimspace(doc)) > 0 && can(yamldecode(doc)) && yamldecode(doc) != null
  ]
}

resource "kubernetes_manifest" "kong_crds" {
  for_each = { for c in local.kong_crd_docs : c.metadata.name => c }

  manifest = each.value
}

# ─────────────────────────────────────────────────────────────────────────────
# Kong Helm release
#
# DB-less mode (no Postgres/Cassandra): config comes from Kubernetes Ingress
# + KongPlugin CRDs only. ClusterIP service (no NLB — intra-cluster only).
# CRDs are already installed above via kubernetes_manifest.kong_crds, so we
# set `installCRDs=false` here to skip Kong's hook-based CRD install (which
# would trigger the ownership-mismatch trap described in the locals comment).
# ─────────────────────────────────────────────────────────────────────────────

resource "helm_release" "kong" {
  name       = var.release_name
  repository = "https://charts.konghq.com"
  chart      = "kong"
  namespace  = var.namespace
  version    = var.kong_chart_version

  depends_on = [kubernetes_manifest.kong_crds]

  # Ingress controller (watches Kubernetes Ingress resources and pushes config to Kong)
  set {
    name  = "ingressController.enabled"
    value = "true"
  }

  set {
    name  = "ingressController.installCRDs"
    value = "false"
  }

  set {
    name  = "ingressController.ingressClass"
    value = "kong"
  }

  # Proxy: internal ClusterIP only, no external LB
  set {
    name  = "proxy.type"
    value = "ClusterIP"
  }

  set {
    name  = "proxy.http.enabled"
    value = "true"
  }

  set {
    name  = "proxy.tls.enabled"
    value = var.proxy_tls_enabled ? "true" : "false"
  }

  # DB-less
  set {
    name  = "env.database"
    value = "off"
  }

  # Replicas
  set {
    name  = "replicaCount"
    value = tostring(var.replicas)
  }

  set {
    name  = "image.tag"
    value = var.kong_image_tag
  }

  # Admin API — enabled but ClusterIP only (for troubleshooting; not exposed)
  set {
    name  = "admin.enabled"
    value = "true"
  }

  set {
    name  = "admin.type"
    value = "ClusterIP"
  }

  # Mount the gateway TLS Secret so the Ingress can reference it for termination
  set {
    name  = "secretVolumes[0]"
    value = var.tls_secret_name
  }

  timeout = 600
  wait    = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Ingress resource — HTTP/HTTPS routing to gateway backends
#
# Kong reads standard Kubernetes Ingress objects and configures itself.
# Routing rules match the reverse-proxy-within-cluster/nginx configuration:
#   /v1/traces|metrics|logs   → gateway OTLP HTTP (4318)
#   /metric/v1, /v1/accounts/events, /agent_listener → gateway NR proprietary (80)
#   /  (catch-all)            → gateway NR proprietary (80)
#
# TLS terminates on Kong using pcg-tls-secret.
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_ingress_v1" "pcg_http" {
  metadata {
    name      = "pcg-kong-http"
    namespace = var.namespace
    labels    = local.common_labels

    annotations = {
      "konghq.com/strip-path" = "false"
      # When Kong terminates TLS itself (intra-cluster), advertise both http+https.
      # When fronted by ALB (out-of-cluster, proxy_tls_enabled=false), Kong only speaks HTTP.
      "konghq.com/protocols" = var.proxy_tls_enabled ? "http,https" : "http"
    }
  }

  spec {
    ingress_class_name = "kong"

    # TLS block only when Kong itself terminates TLS. In out-of-cluster (ALB-fronted),
    # ALB terminates TLS with the ACM cert; Kong→gateway is plain HTTP inside
    # the VPC, so Kong doesn't need pcg-tls-secret.
    dynamic "tls" {
      for_each = var.proxy_tls_enabled ? [1] : []
      content {
        hosts       = [var.pcg_hostname]
        secret_name = var.tls_secret_name
      }
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
              name = var.pcg_upstream_service_name
              port { number = var.pcg_upstream_otlp_http_port }
            }
          }
        }

        path {
          path      = "/v1/metrics"
          path_type = "Prefix"
          backend {
            service {
              name = var.pcg_upstream_service_name
              port { number = var.pcg_upstream_otlp_http_port }
            }
          }
        }

        path {
          path      = "/v1/logs"
          path_type = "Prefix"
          backend {
            service {
              name = var.pcg_upstream_service_name
              port { number = var.pcg_upstream_otlp_http_port }
            }
          }
        }

        # NR proprietary endpoints → gateway:80
        path {
          path      = "/metric/v1"
          path_type = "Prefix"
          backend {
            service {
              name = var.pcg_upstream_service_name
              port { number = var.pcg_upstream_nr_receiver_port }
            }
          }
        }

        path {
          path      = "/v1/accounts/events"
          path_type = "Prefix"
          backend {
            service {
              name = var.pcg_upstream_service_name
              port { number = var.pcg_upstream_nr_receiver_port }
            }
          }
        }

        path {
          path      = "/agent_listener"
          path_type = "Prefix"
          backend {
            service {
              name = var.pcg_upstream_service_name
              port { number = var.pcg_upstream_nr_receiver_port }
            }
          }
        }

        # Catch-all → gateway:80 (NR proprietary)
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = var.pcg_upstream_service_name
              port { number = var.pcg_upstream_nr_receiver_port }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.kong]
}

# Separate Ingress for gRPC — Kong needs `konghq.com/protocols: grpc,grpcs`
# annotation to enable gRPC forwarding. Routes port 4317 traffic to the gateway's
# OTLP gRPC receiver.
resource "kubernetes_ingress_v1" "pcg_grpc" {
  metadata {
    name      = "pcg-kong-grpc"
    namespace = var.namespace
    labels    = local.common_labels

    annotations = {
      # See pcg_http Ingress for rationale on the http/https vs grpc/grpcs
      # switch based on proxy_tls_enabled.
      "konghq.com/protocols"  = var.proxy_tls_enabled ? "grpc,grpcs" : "grpc"
      "konghq.com/strip-path" = "false"
    }
  }

  spec {
    ingress_class_name = "kong"

    dynamic "tls" {
      for_each = var.proxy_tls_enabled ? [1] : []
      content {
        hosts       = [var.pcg_hostname]
        secret_name = var.tls_secret_name
      }
    }

    rule {
      host = var.pcg_hostname

      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = var.pcg_upstream_service_name
              port { number = var.pcg_upstream_otlp_grpc_port }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.kong]
}

# NOTE: We do NOT patch CoreDNS.
#
# Apps in the cluster reach the gateway directly via the Kubernetes-native Service DNS
# name for the Kong proxy: `pcg-kong-kong-proxy.newrelic.svc.cluster.local`
# (default; adjust if you override `release_name` or `namespace`).
#
# The 4.3-pcg-certificate module includes the Kong proxy Service DNS name in the
# TLS certificate's SANs so TLS termination on Kong works against the same
# hostname apps resolve. If you change `release_name` here, also update
# `kong_service_name` in 4.3-pcg-certificate's tfvars.
#
# Removed: previous versions patched the main coredns ConfigMap to add a
# newrelic.internal:53 block so apps could use `pcg.newrelic.internal`. That
# approach had a destroy-safety bug — on destroy the Corefile key was removed
# from the ConfigMap, breaking cluster-wide DNS. Using service DNS avoids the
# bug entirely and matches the intra-cluster design.

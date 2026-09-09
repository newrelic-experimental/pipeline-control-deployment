# Gateway Certificate Module
# Creates a TLS certificate for Pipeline Control gateway using cert-manager
# Skip this module if you already have certificates for the gateway

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
  # Full internal FQDN for the gateway. Legacy — kept for BYO scenarios where a customer
  # still wants a friendly hostname via their own DNS (Route53 private zone,
  # etc.). Default intra-cluster usage relies on the k8s Service DNS SANs below.
  pcg_fqdn = "${var.pcg_subdomain}.${var.internal_domain}"

  # Kong namespace falls back to nginx_namespace when unset (intra-cluster
  # deployments typically use one namespace for whichever proxy is chosen).
  # Override kong_namespace explicitly when Kong lives in a different ns.
  kong_ns = var.kong_namespace != "" ? var.kong_namespace : var.nginx_namespace

  # DNS names (SANs) covered by the certificate.
  # Apps in-cluster hit the gateway through NGINX or Kong via the standard k8s Service
  # DNS name; the cert must cover those names so TLS handshakes verify cleanly.
  dns_names = concat(
    [
      local.pcg_fqdn,
      var.pcg_subdomain,
      "pipeline-control-gateway",
      "pipeline-control-gateway.${var.pcg_namespace}",
      "pipeline-control-gateway.${var.pcg_namespace}.svc",
      "pipeline-control-gateway.${var.pcg_namespace}.svc.cluster.local",
      # NGINX service names (short, ns-scoped, svc, full k8s DNS)
      var.nginx_service_name,
      "${var.nginx_service_name}.${var.nginx_namespace}",
      "${var.nginx_service_name}.${var.nginx_namespace}.svc",
      "${var.nginx_service_name}.${var.nginx_namespace}.svc.cluster.local",
      # Kong proxy service names (when using Kong instead of NGINX)
      var.kong_service_name,
      "${var.kong_service_name}.${local.kong_ns}",
      "${var.kong_service_name}.${local.kong_ns}.svc",
      "${var.kong_service_name}.${local.kong_ns}.svc.cluster.local",
    ],
    var.additional_dns_names
  )
}

# ─────────────────────────────────────────────────────────────────────────────
# Namespace (if not exists)
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "pcg" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.pcg_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "pipeline-control-gateway"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Gateway TLS Certificate
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_manifest" "pcg_certificate" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = var.certificate_name
      namespace = var.create_namespace ? kubernetes_namespace_v1.pcg[0].metadata[0].name : var.pcg_namespace
    }
    spec = {
      secretName  = var.secret_name
      duration    = var.certificate_duration
      renewBefore = var.certificate_renew_before
      commonName  = local.pcg_fqdn
      dnsNames    = local.dns_names
      issuerRef = {
        name  = var.issuer_name
        kind  = var.issuer_kind
        group = "cert-manager.io"
      }
    }
  }

  # Block until cert-manager reports the Certificate Ready=True. The provider
  # polls the cluster for this condition (no fixed sleep, no race).
  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }

  timeouts {
    create = "5m"
    update = "5m"
  }

  depends_on = [kubernetes_namespace_v1.pcg]
}

# ─────────────────────────────────────────────────────────────────────────────
# Export CA Bundle (for apps to trust)
# ─────────────────────────────────────────────────────────────────────────────

data "kubernetes_secret_v1" "ca_secret" {
  count = var.ca_secret_name != "" ? 1 : 0

  metadata {
    name      = var.ca_secret_name
    namespace = var.ca_secret_namespace
  }

  depends_on = [kubernetes_manifest.pcg_certificate]
}

# Create CA bundle Secret in gateway namespace for apps to mount.
# Uses Secret (not ConfigMap) to match the out-of-cluster module's CA Secret —
# apps in both scenarios use the same mount pattern (volumeMount + subPath).
resource "kubernetes_secret_v1" "ca_bundle" {
  count = var.ca_secret_name != "" ? 1 : 0

  metadata {
    name      = "pcg-ca-bundle"
    namespace = var.create_namespace ? kubernetes_namespace_v1.pcg[0].metadata[0].name : var.pcg_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "ca-bundle"
    }
  }

  type = "Opaque"

  data = {
    "ca.crt"     = data.kubernetes_secret_v1.ca_secret[0].data["tls.crt"]
    "pcg-ca.pem" = data.kubernetes_secret_v1.ca_secret[0].data["tls.crt"]
  }
}

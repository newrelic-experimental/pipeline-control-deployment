# cert-manager Cluster Issuer + Internal CA
#
# Creates the three cert-manager custom resources that bootstrap the internal CA:
#   1. selfsigned-issuer ClusterIssuer  — the trust anchor used to sign our CA
#   2. internal-ca Certificate          — the CA cert itself, signed by (1)
#   3. internal-ca-issuer ClusterIssuer — the CA issuer, referencing (2)'s Secret
#
# ── Why this is a separate module from 4.1-installer ──────────────────────
# hashicorp/kubernetes's `kubernetes_manifest` resolves a resource's schema at
# PLAN time. That means it cannot create a custom resource whose CRD does not
# exist yet.
#
# 4.1-installer's Helm chart creates the cert-manager CRDs at APPLY time
# (via `installCRDs = true`), so anything in the same apply that references
# those CRDs will fail at plan.
#
# The historical fix in this repo used `gavinbunney/kubectl` — a community
# provider that skips the plan-time schema lookup. The current fix mirrors
# how 4.2/4.3 already split: apply 4.1 to install the CRDs, then apply 4.2
# to create the custom resources. By the time this module plans, the CRDs
# exist, and the official provider works fine.
#
# See the Confluence release-cleanup action-items page §2c for the decision.

data "aws_eks_cluster" "selected" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "selected" {
  name = var.cluster_name
}

# ─────────────────────────────────────────────────────────────────────────────
# Self-Signed ClusterIssuer (Bootstrap)
# ─────────────────────────────────────────────────────────────────────────────
# The seed issuer. Signs the internal CA certificate. Not used for anything
# else — apps trust the CA that comes after it, not this one directly.

resource "kubernetes_manifest" "selfsigned_issuer" {
  count = var.create_internal_ca ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "selfsigned-issuer"
    }
    spec = {
      selfSigned = {}
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal CA Certificate
# ─────────────────────────────────────────────────────────────────────────────
# The actual CA cert, valid for 10 years, auto-renewed 30 days before expiry.
# Private key stays as a K8s Secret in the cert-manager namespace.

resource "kubernetes_manifest" "internal_ca_certificate" {
  count = var.create_internal_ca ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = var.ca_name
      namespace = var.namespace
    }
    spec = {
      isCA        = true
      commonName  = var.ca_common_name
      secretName  = var.ca_secret_name
      duration    = "87600h"
      renewBefore = "720h"
      privateKey = {
        algorithm = "ECDSA"
        size      = 256
      }
      issuerRef = {
        name  = "selfsigned-issuer"
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
    }
  }

  depends_on = [kubernetes_manifest.selfsigned_issuer]
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal CA ClusterIssuer
# ─────────────────────────────────────────────────────────────────────────────
# The issuer used by downstream Certificate resources (e.g. 4.3-pcg-certificate)
# to request TLS certs signed by our CA.

resource "kubernetes_manifest" "internal_ca_issuer" {
  count = var.create_internal_ca ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = var.issuer_name
    }
    spec = {
      ca = {
        secretName = var.ca_secret_name
      }
    }
  }

  depends_on = [kubernetes_manifest.internal_ca_certificate]
}

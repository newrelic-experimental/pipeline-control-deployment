# Cert Manager Installer Module
# Installs cert-manager (Helm chart, which includes the CRDs). The three
# cert-manager custom resources that bootstrap the internal CA — the
# selfsigned-issuer, the CA Certificate, and the CA ClusterIssuer — live in
# the sibling 4.2-cluster-issuer module and are applied AFTER this one, so
# the CRDs exist by the time they need planning.
#
# Skip this module if you already have cert-manager installed.

# ─────────────────────────────────────────────────────────────────────────────
# Data Sources - EKS Cluster Discovery
# ─────────────────────────────────────────────────────────────────────────────

data "aws_eks_cluster" "selected" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "selected" {
  name = var.cluster_name
}

# ─────────────────────────────────────────────────────────────────────────────
# Namespace
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "cert_manager" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/name"       = "cert-manager"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Helm Release - cert-manager
# ─────────────────────────────────────────────────────────────────────────────
# `installCRDs = true` puts the cert-manager CRDs into the cluster as part of
# the chart install. The custom resources that use those CRDs are in the
# sibling 4.2-cluster-issuer module.

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  namespace  = var.create_namespace ? kubernetes_namespace_v1.cert_manager[0].metadata[0].name : var.namespace
  version    = var.cert_manager_version

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "webhook.timeoutSeconds"
    value = "30"
  }

  timeout = 600
  wait    = true

  depends_on = [kubernetes_namespace_v1.cert_manager]
}

# Wait for cert-manager webhook to be ready before downstream 4.2 tries to
# create custom resources against it.
resource "time_sleep" "wait_for_cert_manager" {
  depends_on      = [helm_release.cert_manager]
  create_duration = "30s"
}

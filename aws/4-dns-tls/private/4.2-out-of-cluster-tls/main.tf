# Out-of-cluster TLS Deployment Module
#
# Out-of-cluster pattern implementation. Creates an AWS Private CA
# (or reuses an existing one), issues a server cert for the gateway hostname, and
# distributes the two halves to the two clusters:
#   - Server cert + key → pcg-cluster (for the ALB Ingress to serve TLS)
#   - CA root certificate → apps-cluster (for app pods to trust the server)
#
# ⚠️ COST WARNING: AWS Private CA bills a flat monthly rate whether idle or busy.
#    Destroy this module's resources when not actively testing.

# ─────────────────────────────────────────────────────────────────────────────
# Section 1 — AWS Private CA (create or reuse)
# ─────────────────────────────────────────────────────────────────────────────

# BYO path: read cert data from an existing CA
data "aws_acmpca_certificate_authority" "byo" {
  count = var.private_ca_arn != "" ? 1 : 0
  arn   = var.private_ca_arn
}

# Fresh-CA path: create a ROOT CA. Activation happens in 2 more steps below.
resource "aws_acmpca_certificate_authority" "pcg" {
  count = var.private_ca_arn == "" ? 1 : 0

  type = "ROOT"

  # SHORT_LIVED_CERTIFICATE mode is cheaper than GENERAL_PURPOSE for scenarios
  # where certs live under 7 days. Our server cert is 397 days, so we use
  # GENERAL_PURPOSE (the default). Explicitly set for clarity.
  usage_mode = "GENERAL_PURPOSE"

  # Allow terraform destroy to remove the CA immediately rather than the AWS
  # default 30-day soft-delete window. 7 is the minimum AWS accepts.
  permanent_deletion_time_in_days = 7

  certificate_authority_configuration {
    key_algorithm     = "RSA_2048"
    signing_algorithm = "SHA256WITHRSA"

    subject {
      common_name  = var.ca_common_name
      organization = var.ca_organization
      country      = var.ca_country
    }
  }
}

# Step 2 of CA activation: self-sign the CA's own CSR.
# The CA is CREATED in step 1 above but stays in PENDING_CERTIFICATE state
# until we submit a signed cert back. Since this is a ROOT CA, we sign it
# with itself.
resource "aws_acmpca_certificate" "root" {
  count = var.private_ca_arn == "" ? 1 : 0

  certificate_authority_arn   = aws_acmpca_certificate_authority.pcg[0].arn
  certificate_signing_request = aws_acmpca_certificate_authority.pcg[0].certificate_signing_request
  signing_algorithm           = "SHA256WITHRSA"
  template_arn                = "arn:aws:acm-pca:::template/RootCACertificate/V1"

  validity {
    type  = "YEARS"
    value = var.ca_validity_years
  }
}

# Step 3 of CA activation: import the signed root back to activate the CA.
# After this the CA moves to ACTIVE state and can issue certs.
resource "aws_acmpca_certificate_authority_certificate" "root" {
  count = var.private_ca_arn == "" ? 1 : 0

  certificate_authority_arn = aws_acmpca_certificate_authority.pcg[0].arn
  certificate               = aws_acmpca_certificate.root[0].certificate
  certificate_chain         = aws_acmpca_certificate.root[0].certificate_chain
}

# Consolidated references — always resolve to either the BYO or the fresh CA.
locals {
  ca_arn      = var.private_ca_arn != "" ? var.private_ca_arn : aws_acmpca_certificate_authority.pcg[0].arn
  ca_cert_pem = var.private_ca_arn != "" ? data.aws_acmpca_certificate_authority.byo[0].certificate : aws_acmpca_certificate.root[0].certificate
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 2 — Server cert issuance (for the gateway ALB hostname)
# ─────────────────────────────────────────────────────────────────────────────

# Generate an RSA private key locally. Written to pcg-cluster's Secret as
# `tls.key` for the ALB Ingress and to apps-cluster's Secret for consumers.
#
# NOTE: this key is stored in plaintext in terraform.tfstate. The tls_private_key
# resource has no `sensitive` attribute that would encrypt at-rest. Anyone with
# read access to state can extract the server private key. Standard mitigations:
# use a remote backend with server-side encryption + strict IAM (e.g. S3 +
# `aes256` / KMS + bucket policy) and treat the state file with the same
# access controls as the private key itself. See the "Secrets in state"
# section in aws/README.md.
resource "tls_private_key" "server" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Build a CSR for the gateway hostname. The Common Name + SANs must match the
# hostname apps will use to connect (which comes from the private zone from 4.1-route53-private-zone).
resource "tls_cert_request" "server" {
  private_key_pem = tls_private_key.server.private_key_pem

  subject {
    common_name  = var.pcg_hostname
    organization = var.ca_organization
  }

  # SANs — this is what modern clients actually validate. CN is legacy but
  # kept in sync for older stacks.
  dns_names = [var.pcg_hostname]
}

# Submit the CSR to the Private CA and get back a signed cert.
# End-entity template (not root/subordinate) — this is a server cert.
resource "aws_acmpca_certificate" "server" {
  certificate_authority_arn   = local.ca_arn
  certificate_signing_request = tls_cert_request.server.cert_request_pem
  signing_algorithm           = "SHA256WITHRSA"
  template_arn                = "arn:aws:acm-pca:::template/EndEntityCertificate/V1"

  validity {
    type  = "DAYS"
    value = var.cert_validity_days
  }

  # Ensure CA is ACTIVE before requesting certs. When we're creating the CA,
  # this depends on the activation resource. When BYO, the caller guarantees
  # the CA is active — no explicit dependency needed.
  depends_on = [aws_acmpca_certificate_authority_certificate.root]
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 2b — Import the server cert into ACM
#
# AWS ALB requires the TLS cert to be in ACM (referenced by ARN via the
# `alb.ingress.kubernetes.io/certificate-arn` annotation). ALB does NOT read
# K8s TLS Secrets — the ALB Ingress spec.tls[].secretName is used only by
# ingress controllers that terminate TLS in-cluster (NGINX, Kong, etc.).
#
# So we import the SAME cert (from ACM-PCA) into ACM. The K8s Secret we
# create in Section 4 stays useful for anything that reads certs from k8s
# Secrets (verification tooling, potential future non-ALB paths), and this
# ACM import is what the ALB itself consumes.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_acm_certificate" "pcg_server_imported" {
  private_key       = tls_private_key.server.private_key_pem
  certificate_body  = aws_acmpca_certificate.server.certificate
  certificate_chain = aws_acmpca_certificate.server.certificate_chain

  # This cert is self-owned (we hold the private key). Import is FREE.
  # ACM cert renewal doesn't apply — we manage lifecycle via Terraform apply.

  tags = {
    Name     = "pcg-server-cert-${var.pcg_hostname}"
    Hostname = var.pcg_hostname
    Source   = "4.2-out-of-cluster-tls"
  }

  lifecycle {
    # If we re-issue the server cert (new apply after cert expiry), ACM
    # requires a new cert before destroying the old (avoids ALB downtime).
    create_before_destroy = true
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 3 — Namespace pre-creation in pcg-cluster
# ─────────────────────────────────────────────────────────────────────────────

# The 5-pcg module also creates this namespace. To avoid
# double-creation errors, that module has a create_pcg_namespace flag that
# defaults to false so THIS module wins. If a caller flips the roles, they
# can pass create_pcg_namespace = false here instead.
resource "kubernetes_namespace_v1" "pcg" {
  provider = kubernetes.pcg
  count    = var.create_pcg_namespace ? 1 : 0

  metadata {
    name = var.pcg_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "pipeline-control-gateway"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 4 — Server cert Secret in pcg-cluster
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_secret_v1" "pcg_tls" {
  provider = kubernetes.pcg

  metadata {
    name      = var.pcg_tls_secret_name
    namespace = var.create_pcg_namespace ? kubernetes_namespace_v1.pcg[0].metadata[0].name : var.pcg_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "pcg-server-tls"
      "app.kubernetes.io/part-of"    = "pipeline-control-gateway"
    }

    annotations = {
      "pcg.newrelic.com/hostname"  = var.pcg_hostname
      "pcg.newrelic.com/ca-source" = var.private_ca_arn != "" ? "byo" : "terraform-created"
    }
  }

  # kubernetes.io/tls is the standard Secret type for ALB Ingress + most
  # controllers. It requires tls.crt and tls.key keys.
  type = "kubernetes.io/tls"

  data = {
    # ALB (and most controllers) accept the leaf cert + chain concatenated.
    # certificate_chain from ACM-PCA is the intermediate/root chain.
    "tls.crt" = "${aws_acmpca_certificate.server.certificate}\n${aws_acmpca_certificate.server.certificate_chain}"
    "tls.key" = tls_private_key.server.private_key_pem
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 5 — CA bundle Secret in apps-cluster
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_secret_v1" "apps_ca_bundle" {
  provider = kubernetes.apps

  metadata {
    name      = var.apps_ca_bundle_secret_name
    namespace = var.apps_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "pcg-ca-trust"
      "app.kubernetes.io/part-of"    = "pipeline-control-gateway"
    }

    annotations = {
      "pcg.newrelic.com/ca-arn"       = local.ca_arn
      "pcg.newrelic.com/pcg-hostname" = var.pcg_hostname
    }
  }

  # Opaque, not kubernetes.io/tls — this Secret holds only the CA cert (no
  # server key), so tls.crt/tls.key semantics don't apply.
  type = "Opaque"

  data = {
    # ca.crt is the conventional key for CA bundle Secrets. pcg-ca.pem matches
    # the conventional path for per-language CA trust config (e.g. Node.js
    # NODE_EXTRA_CA_CERTS=/etc/ssl/certs/pcg-ca.pem).
    "ca.crt"     = local.ca_cert_pem
    "pcg-ca.pem" = local.ca_cert_pem
  }
}

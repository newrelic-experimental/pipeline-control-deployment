# Gateway Deployment Variables (Flux mode)

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# Gateway configuration
# ─────────────────────────────────────────────────────────────────────────────

variable "pcg_values_file" {
  description = "Path to the gateway Helm values file downloaded from the New Relic UI install flow"
  type        = string
}

variable "pcg_wait_duration" {
  description = "Time to wait for Flux to deploy the gateway after Agent Control"
  type        = string
  default     = "180s"
}

# ─────────────────────────────────────────────────────────────────────────────
# Chart version — pin your own for reproducibility.
#
# The default is the version this repo was last validated against, but the
# `agent-control-bootstrap` chart is updated frequently. If a later apply picks
# up a breaking upstream change, override to the exact version you validated.
# Leave as-is for the tested default; override in tfvars for pinning:
#   agent_control_bootstrap_chart_version = "2.3.3"
# ─────────────────────────────────────────────────────────────────────────────

variable "agent_control_bootstrap_chart_version" {
  description = "Chart version for `agent-control-bootstrap` (Flux mode). Defaults to the version validated in this repo. Leave empty (\"\") to always fetch the latest chart at apply time (not recommended for production)."
  type        = string
  default     = "1.8.12"
}

# ─────────────────────────────────────────────────────────────────────────────
# Namespace Configuration
# ─────────────────────────────────────────────────────────────────────────────

variable "create_agent_control_namespace" {
  description = "Create the Agent Control namespace (`newrelic-agent-control`). Default true — this module owns it."
  type        = bool
  default     = true
}

variable "create_pcg_namespace" {
  description = "Create the gateway namespace (`newrelic`). Default false — the `4.3-pcg-certificate` module (Step 4) already creates it. Only set true if you're skipping Step 4 or bringing your own TLS setup that doesn't create the namespace."
  type        = bool
  default     = false
}

variable "agent_control_namespace" {
  description = "Namespace for Agent Control"
  type        = string
  default     = "newrelic-agent-control"
}

variable "pcg_namespace" {
  description = "Namespace for Pipeline Control gateway"
  type        = string
  default     = "newrelic"
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

# ─────────────────────────────────────────────────────────────────────────────
# Out-of-cluster — ALB Ingress + Route53
#
# These variables are all defaulted-off. Intra-cluster users see no behavior change.
# The out-of-cluster pattern sets create_alb_ingress + create_route53_record to true.
# ─────────────────────────────────────────────────────────────────────────────

variable "create_alb_ingress" {
  description = "Out-of-cluster only: create an ALB Ingress that terminates TLS on the ALB and routes to the gateway. Requires ALB Controller pre-installed and pcg-tls-secret in place. Intra-cluster users leave this false."
  type        = bool
  default     = false
}

variable "pcg_hostname" {
  description = "Hostname served by the ALB (must match the server cert CN from 4.2-out-of-cluster-tls and the Route53 record from 4.1-route53-private-zone). Only used when create_alb_ingress = true."
  type        = string
  default     = "pcg.internal.newrelic"
}

variable "tls_secret_name" {
  description = "Name of the K8s Secret in pcg_namespace containing the ALB TLS cert. Created by 4.2-out-of-cluster-tls. Referenced in the Ingress spec.tls[].secretName. NOTE: AWS ALB doesn't actually consume this Secret — it uses acm_certificate_arn below. The Secret reference is kept for informational parity with other ingress controllers (NGINX/Kong)."
  type        = string
  default     = "pcg-tls-secret"
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for TLS termination at the ALB. Set from 4.2-out-of-cluster-tls's `acm_certificate_arn` output. AWS ALB requires the cert to be in ACM (referenced by ARN) — it does NOT read K8s TLS Secrets. Only used when create_alb_ingress = true."
  type        = string
  default     = ""
}

variable "alb_scheme" {
  description = "ALB scheme: 'internal' (private-only, out-of-cluster default) or 'internet-facing' (the public-DNS variant). Only used when create_alb_ingress = true."
  type        = string
  default     = "internal"
}

variable "pcg_service_name" {
  description = "Name of the gateway Service that the ALB Ingress routes to. This Service is created by Flux via the agent-control-bootstrap chart. Convention: 'pipeline-control-gateway'."
  type        = string
  default     = "pipeline-control-gateway"
}

variable "pcg_otlp_http_port" {
  description = "the gateway's OTLP HTTP port. Ingress paths /v1/traces, /v1/metrics, /v1/logs route here."
  type        = number
  default     = 4318
}

variable "pcg_nr_receiver_port" {
  description = "the gateway's NR proprietary receiver port. Ingress paths /metric/v1, /v1/accounts/events, /agent_listener, and the catch-all / route here."
  type        = number
  default     = 80
}

variable "create_route53_record" {
  description = "Out-of-cluster only: create a Route53 A-record aliased to the ALB in the private zone from 4.1-route53-private-zone. Requires create_alb_ingress = true and route53_zone_id set."
  type        = bool
  default     = false
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for the private zone (output of 4.1-route53-private-zone). Required when create_route53_record = true."
  type        = string
  default     = ""
}

variable "alb_wait_duration" {
  description = "Time to wait after Ingress creation for ALB Controller to provision the ALB and populate ingress.status.loadBalancer.ingress[].hostname. Increase if apply times out reading the ALB hostname."
  type        = string
  default     = "120s"
}

# Fluxless gateway Deployment Variables
#
# Interface matches 5-pcg/flux as closely as possible so both modules
# are drop-in replacements. Only difference: fluxless takes TWO values.yaml
# files (one for agent-control, one for the gateway) since it installs two separate
# Helm charts instead of one bootstrap chart.

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# Fluxless-specific: two Helm charts, two values.yaml files
# ─────────────────────────────────────────────────────────────────────────────

variable "agent_control_values_file" {
  description = "Path to the agent-control-deployment Helm values.yaml (downloaded from New Relic install wizard). Corresponds to: helm install newrelic/agent-control-deployment --values <this>."
  type        = string
}

variable "pcg_values_file" {
  description = "Path to the pipeline-control-gateway Helm values.yaml (downloaded from New Relic install wizard). Corresponds to: helm install newrelic/pipeline-control-gateway --values <this>. The values file controls whether the gateway runs as a Deployment or DaemonSet (via `kind` in the values)."
  type        = string
}

variable "agent_control_wait_duration" {
  description = "Time to wait after Agent Control install before installing gateway chart. Agent Control needs to be Ready to accept the gateway's CRD/manifest registrations."
  type        = string
  default     = "60s"
}

variable "pcg_wait_duration" {
  description = "Time to wait after gateway Helm install before subsequent steps (Ingress, etc.) can safely read the gateway's Service."
  type        = string
  default     = "60s"
}

# ─────────────────────────────────────────────────────────────────────────────
# Chart versions — pin your own for reproducibility.
#
# Defaults are the versions this repo was last validated against, but both
# charts are updated frequently. If a later apply picks up a breaking upstream
# change, override to the exact version you validated. Set to "" to always
# fetch the latest chart at apply time (not recommended for production).
# ─────────────────────────────────────────────────────────────────────────────

variable "agent_control_chart_version" {
  description = "Chart version for `agent-control-deployment` (Fluxless mode). Defaults to the version validated in this repo. Set to \"\" to fetch latest."
  type        = string
  default     = "1.7.17"
}

variable "pcg_chart_version" {
  description = "Chart version for `pipeline-control-gateway`. Defaults to the version validated in this repo. Set to \"\" to fetch latest."
  type        = string
  default     = "2.5.0"
}

# ─────────────────────────────────────────────────────────────────────────────
# Namespace Configuration
# ─────────────────────────────────────────────────────────────────────────────
# Fluxless uses a single namespace (newrelic) for both charts. Simpler than
# 5-pcg/flux which splits into newrelic-agent-control + newrelic.

variable "create_pcg_namespace" {
  description = "Create the gateway namespace. Default false — the `4.3-pcg-certificate` (the intra-cluster pattern) or `4.2-out-of-cluster-tls` (the out-of-cluster pattern) module already creates it (that's where the TLS Secret lives). Only set true if you're skipping both."
  type        = bool
  default     = false
}

variable "pcg_namespace" {
  description = "Namespace where both Agent Control and gateway install. Fluxless is namespace-scoped so it all fits in one namespace."
  type        = string
  default     = "newrelic"
}

variable "tags" {
  description = "Additional tags for AWS resources (Route53 record). No effect on K8s resources."
  type        = map(string)
  default     = {}
}

# ─────────────────────────────────────────────────────────────────────────────
# Out-of-cluster — ALB Ingress + Route53
#
# Matches 5-pcg/flux for out-of-cluster ingress + Route53. These variables are
# defaulted-off, so intra-cluster users see no change.
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
  description = "Name of the K8s Secret in pcg_namespace containing the ALB TLS cert. Referenced in the Ingress spec.tls[].secretName. NOTE: AWS ALB doesn't actually consume this Secret — it uses acm_certificate_arn below. The Secret reference is kept for informational parity with other ingress controllers (NGINX/Kong)."
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
  description = "Name of the gateway Service that the ALB Ingress routes to. Created by the pipeline-control-gateway Helm chart. Convention: 'pipeline-control-gateway'."
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
  description = "Time to wait after Ingress creation for ALB Controller to provision the ALB and populate ingress.status.loadBalancer.ingress[].hostname."
  type        = string
  default     = "120s"
}

#!/usr/bin/env bash
#
# Pipeline Control gateway — Guided Teardown (scaffold)
#
# Interactive helper that prints the sequence of `terraform destroy` commands
# needed to tear down your gateway infrastructure. Mirror-image of deploy.sh.
#
# Prints commands only — does NOT run terraform destroy for you. You copy-paste
# the printed commands in order. This mirrors the shape of deploy.sh.
#
# Handles both topologies:
#   - intra-cluster — 1 tfvars file
#   - out-of-cluster (private DNS) — 2 tfvars files + workspaces
#
# What this scaffold does NOT do (yet):
#   - Actually execute terraform destroy (you copy-paste the commands)
#   - Delete your tfvars files (leaves them alone — your call)
#   - Delete your state files (leaves them alone; wipe with rm terraform.tfstate*)
#   - Clean up orphan AWS resources (ENIs, LBs) — detect only, cleanup manual
#
# Usage:
#   ./teardown.sh

set -euo pipefail

# ── styling ──────────────────────────────────────────────────────────────────
# Using printf %b instead of echo -e so this script works when invoked as
# `sh teardown.sh` on macOS (/bin/sh treats echo -e differently).
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { printf "%bℹ%b  %s\n" "$BLUE"   "$NC" "$*"; }
success() { printf "%b✓%b %s\n"  "$GREEN"  "$NC" "$*"; }
warn()    { printf "%b⚠%b %s\n"  "$YELLOW" "$NC" "$*"; }
die()     { printf "%b✗%b %s\n"  "$RED"    "$NC" "$*" >&2; exit 1; }
danger()  { printf "%b⚠  %s%b\n" "$RED"    "$*"  "$NC"; }

# ── locate repo root (script lives at aws/scripts/, so ../..) ────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# ── loud opening banner ──────────────────────────────────────────────────────
echo
danger "================================================================"
danger "  PIPELINE CONTROL GATEWAY GUIDED TEARDOWN"
danger "  This will produce a destroy plan for your gateway infrastructure."
danger "  Destroy is IRREVERSIBLE. Read every command before pasting it."
danger "================================================================"
echo

# ── prompt helpers ───────────────────────────────────────────────────────────
prompt_choice() {
  # prompt_choice "label" "default" "opt1|opt2|opt3"
  local label="$1" default="$2" opts="$3" answer prompt
  while :; do
    prompt=$(printf "%b%s%b [%s]: " "$BLUE" "$label" "$NC" "$default")
    read -r -p "$prompt" answer
    answer="${answer:-$default}"
    if [[ "|$opts|" == *"|$answer|"* ]]; then
      echo "$answer"
      return
    fi
    warn "Invalid choice. Expected one of: $(echo "$opts" | tr '|' ' ')"
  done
}

confirm() {
  local msg="$1" answer prompt
  prompt=$(printf "%b%s%b [y/N]: " "$YELLOW" "$msg" "$NC")
  read -r -p "$prompt" answer
  [[ "$answer" =~ ^[Yy] ]]
}

# ── prompt: which topology ───────────────────────────────────────────────────
echo
info "Which topology did you deploy?"
info "  1 = out-of-cluster (private DNS + Private CA)"
info "      — 8 modules, aws/out-of-cluster-private-dns-{pcg,apps}.tfvars"
info "  2 = intra-cluster — 6 modules, aws/intra-cluster.tfvars"
TOPOLOGY=$(prompt_choice "Topology (1 or 2)" "2" "1|2")
echo

# ── prompt: which reverse proxy (both topologies can use one) ────────────────
PROXY=""
if [[ "$TOPOLOGY" == "2" ]]; then
  info "Which reverse proxy did you apply?"
  info "  n = NGINX  (module: aws/3-ingress/reverse-proxy-within-cluster/nginx)"
  info "  k = Kong   (module: aws/3-ingress/reverse-proxy-within-cluster/kong)"
  PROXY=$(prompt_choice "Reverse proxy" "n" "n|k")
  echo
elif [[ "$TOPOLOGY" == "1" ]]; then
  info "Did you use a layered in-cluster proxy (ALB → NGINX/Kong → gateway)?"
  info "  n = No (direct ALB → gateway)"
  info "  N = NGINX layered"
  info "  K = Kong layered"
  PROXY=$(prompt_choice "Layered proxy" "n" "n|N|K")
  echo
fi

# ── prompt: which gateway install mode ───────────────────────────────────────
info "Which gateway install mode did you apply?"
info "  f = Flux mode    (module: aws/5-pcg/flux)"
info "  x = Fluxless mode (module: aws/5-pcg/fluxless)"
PCG_MODE=$(prompt_choice "Gateway install mode" "f" "f|x")
echo

# ── State-drift heads-up ─────────────────────────────────────────────────────
warn "State-drift heads-up: if any 'terraform apply' was interrupted, Helm releases"
warn "may exist without Terraform state tracking them. 'terraform destroy' will NOT"
warn "remove releases it doesn't know about."
info "After destroy, verify with:  helm list -n newrelic"
info "If any releases remain:"
info "  helm uninstall newrelic-pcg              -n newrelic"
info "  helm uninstall agent-control-deployment  -n newrelic"
info "  helm uninstall agent-control-bootstrap   -n newrelic-agent-control"
echo

# ── Provider-bug heads-up for NGINX/Kong modules ─────────────────────────────
# The providers.tf pin `~> 2.37.1` excludes the buggy 2.37.0. This note stays
# in case someone loosens the pin manually and hits the identity-change crash
# on destroy.
if [[ "$PROXY" != "n" ]]; then
  warn "Kubernetes provider 2.37.0 has a known 'Unexpected Identity Change' bug"
  warn "that can block terraform destroy. The repo pins to ~> 2.37.1 to avoid it."
  warn "If you've loosened the pin and hit:"
  warn "  Error: Unexpected Identity Change ... resource kubernetes_deployment_v1"
  info "Workaround (destroys via kubectl, then wipes terraform state):"
  info '  kubectl delete deployment,service,configmap -n newrelic -l app.kubernetes.io/name=pcg-nginx'
  info '  terraform state rm kubernetes_deployment_v1.nginx \'
  info '                     kubernetes_service_v1.nginx \'
  info '                     kubernetes_config_map_v1.nginx_config'
  info '  rm -rf terraform.tfstate* .terraform .terraform.lock.hcl'
  info "  (Substitute 'pcg-kong' + Kong resource names if using Kong.)"
  echo
fi

# ── out-of-cluster warning: Private CA billing ──────────────────────────────────────────
if [[ "$TOPOLOGY" == "1" ]]; then
  danger "Out-of-cluster note: aws/4-dns-tls/private/4.2-out-of-cluster-tls hosts an AWS Private CA"
  danger "at a flat monthly rate. Destroying that module STOPS billing immediately (the CA"
  danger "record lingers 7 days in DELETED state but billing stops at destroy time)."
  echo
fi

echo
danger "================================================================"
danger "  DESTROY SEQUENCE — copy-paste one command at a time"
danger "  Verify each 'Plan: 0 to add, 0 to change, N to destroy' before typing 'yes'"
danger "  (Each terraform destroy is itself interactive, so nothing is destroyed"
danger "   by pasting a command — you still confirm at every apply.)"
danger "================================================================"
echo

# ─────────────────────────────────────────────────────────────────────────────
# Intra-cluster destroy sequence
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$TOPOLOGY" == "2" ]]; then
  cat <<'EOF'

  # ═══ intra-cluster destroy — reverse of apply order ══════════════════════════════════
  # All commands start from repo root. tfvars: aws/intra-cluster.tfvars.

  # ── Step 6: Reverse proxy (destroy FIRST — reverse of apply order) ──────────
EOF
  if [[ "$PROXY" == "n" ]]; then
    cat <<'EOF'
  (cd aws/3-ingress/reverse-proxy-within-cluster/nginx && terraform destroy -var-file=../../../intra-cluster.tfvars)
EOF
  else
    cat <<'EOF'
  (cd aws/3-ingress/reverse-proxy-within-cluster/kong && terraform destroy -var-file=../../../intra-cluster.tfvars)
EOF
  fi

  cat <<'EOF'

  # ── Step 5: gateway install (removes Helm releases + Deployment/Service) ────
EOF
  if [[ "$PCG_MODE" == "f" ]]; then
    cat <<'EOF'
  (cd aws/5-pcg/flux && terraform destroy -var-file=../../intra-cluster.tfvars -var="pcg_values_file=./pcg-values.yaml")
EOF
  else
    cat <<'EOF'
  (cd aws/5-pcg/fluxless && terraform destroy -var-file=../../intra-cluster.tfvars -var="agent_control_values_file=./agent-control-values.yaml" -var="pcg_values_file=./pcg-values.yaml")
EOF
  fi

  cat <<'EOF'

  # ── Step 4b: gateway certificate + CA bundle Secret ────────────────────────
  (cd aws/4-dns-tls/cert-manager/4.3-pcg-certificate && terraform destroy -var-file=../../../intra-cluster.tfvars)

  # ── Step 4a: internal CA + ClusterIssuer ───────────────────────────────────
  (cd aws/4-dns-tls/cert-manager/4.2-cluster-issuer && terraform destroy -var-file=../../../intra-cluster.tfvars)

  # ── Step 3: cert-manager Helm release + CRDs ───────────────────────────────
  (cd aws/4-dns-tls/cert-manager/4.1-installer && terraform destroy -var-file=../../../intra-cluster.tfvars)

  # ── Step 2: EKS cluster (~10 min; may hang on node group — see notes below) ─
  (cd aws/2-eks && terraform destroy -var-file=../intra-cluster.tfvars)

  # ── Step 1: VPC + NAT gateways + subnets + IGW ─────────────────────────────
  (cd aws/1-vpc && terraform destroy -var-file=../intra-cluster.tfvars)

EOF

# ─────────────────────────────────────────────────────────────────────────────
# Out-of-cluster destroy sequence
# ─────────────────────────────────────────────────────────────────────────────
elif [[ "$TOPOLOGY" == "1" ]]; then
  cat <<'EOF'

  # ═══ out-of-cluster (private DNS) destroy — reverse of apply order ═════════
  # All commands start from repo root.
  # tfvars: aws/out-of-cluster-private-dns-{pcg,apps}.tfvars

EOF

  # Layered proxy destroy — comes before the gateway since ALB references its Service
  if [[ "$PROXY" == "N" ]]; then
    cat <<'EOF'
  # ── Step 6b: Layered NGINX proxy (destroy FIRST — reverse of apply) ────────
  (cd aws/3-ingress/reverse-proxy-within-cluster/nginx && terraform destroy -var-file=../../../out-of-cluster-private-dns-pcg.tfvars -var="nginx_tls_enabled=false")

EOF
  elif [[ "$PROXY" == "K" ]]; then
    cat <<'EOF'
  # ── Step 6b: Layered Kong proxy (destroy FIRST — reverse of apply) ─────────
  (cd aws/3-ingress/reverse-proxy-within-cluster/kong && terraform destroy -var-file=../../../out-of-cluster-private-dns-pcg.tfvars -var="proxy_tls_enabled=false")

EOF
  fi

  cat <<'EOF'
  # ── Step 6a: gateway install (removes ALB Ingress + Route53 A-record) ──────
EOF
  if [[ "$PCG_MODE" == "f" ]]; then
    cat <<'EOF'
  (cd aws/5-pcg/flux && terraform destroy -var-file=../../out-of-cluster-private-dns-pcg.tfvars -var="pcg_values_file=./pcg-values.yaml")
EOF
  else
    cat <<'EOF'
  (cd aws/5-pcg/fluxless && terraform destroy -var-file=../../out-of-cluster-private-dns-pcg.tfvars -var="agent_control_values_file=./agent-control-values.yaml" -var="pcg_values_file=./pcg-values.yaml")
EOF
  fi

  cat <<'EOF'

  # ── Step 5b: Out-of-cluster TLS (⚠️ STOPS THE PRIVATE CA BILLING) ─────────
  (cd aws/4-dns-tls/private/4.2-out-of-cluster-tls && terraform destroy -var-file=../../../out-of-cluster-private-dns-pcg.tfvars)

  # ── Step 5a: Route53 private zone ──────────────────────────────────────────
  (cd aws/4-dns-tls/private/4.1-route53-private-zone && terraform destroy -var-file=../../../out-of-cluster-private-dns-pcg.tfvars)

  # ── Step 4: ALB Controller (Helm release on pcg-cluster) ───────────────────
  (cd aws/3-ingress/alb && terraform destroy -var-file=../../out-of-cluster-private-dns-pcg.tfvars)

  # ── Step 3: EKS — destroy BOTH workspaces (apps-cluster FIRST, pcg-cluster LAST)
  # apps-cluster first because pcg-cluster has the ALB Controller IRSA role
  # everything else depends on.
  cd aws/2-eks
  terraform workspace select apps-cluster
  terraform destroy -var-file=../out-of-cluster-private-dns-apps.tfvars
  terraform workspace select pcg-cluster
  terraform destroy -var-file=../out-of-cluster-private-dns-pcg.tfvars
  terraform workspace select default
  cd -

  # ── Step 1: Shared VPC ─────────────────────────────────────────────────────
  (cd aws/1-vpc && terraform destroy -var-file=../out-of-cluster-private-dns-pcg.tfvars)

EOF
fi

# ── Post-destroy checks ──────────────────────────────────────────────────────
cat <<'EOF'
  # ═══ Post-destroy checks (paste after all destroys complete) ═══════════════

  # 1. Orphan Helm releases (Terraform state can lose these on interrupted applies):
  helm list -n newrelic
  helm list -n newrelic-agent-control 2>/dev/null || true

  # 2. Orphan AWS resources — EKS CNI sometimes leaks ENIs, and failed LB destroys leak LBs:
  VPC_ID=<your-vpc-id>   # or check aws ec2 describe-vpcs
  aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'NetworkInterfaces[?Status==`available`].[NetworkInterfaceId,Description]'
  aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerName,State.Code]'
  aws ec2 describe-addresses --query 'Addresses[?AssociationId==`null`].[AllocationId,PublicIp]'

EOF

info "Done. Paste the commands above one at a time, verifying each plan output."
info "See aws/README.md for the full walkthrough + common failure recovery patterns."

#!/usr/bin/env bash
#
# Pipeline Control gateway — Guided Install (scaffold)
#
# Interactive helper that:
#   1. Prompts for the topology (out-of-cluster OR intra-cluster)
#   2. Optionally walks through a BYO checklist (skip modules you
#      already have infra for — VPC, EKS, cert-manager, ALB Controller, etc.)
#   3. Writes the correct tfvars file(s) at aws/*.tfvars
#   4. Prints the terraform apply commands you need to run
#
# It does NOT run terraform apply for you — module-by-module apply is a manual
# step per aws/README.md. This scaffold saves you the tfvars templating +
# tells you which modules to skip for BYO.
#
# Scripts live at aws/scripts/ but this script auto-cd's to the repo root, so
# invoke it however you like:
#   ./aws/scripts/deploy.sh
#   bash aws/scripts/deploy.sh
#   cd aws/scripts && ./deploy.sh
#
# Requires bash 4+. Uses [[ ]], =~, read -a, arrays, and process substitution
# (<<< heredocs), none of which work under POSIX sh / dash. On macOS `sh` is
# bash-in-POSIX-mode and forgiving enough that most of the script runs, but
# don't rely on it — invoke as `bash aws/scripts/deploy.sh` or `./deploy.sh`.
# printf %b is used instead of echo -e for portability across bash versions.

set -euo pipefail

# ── styling ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { printf "%bℹ%b  %s\n" "$BLUE"   "$NC" "$*"; }
success() { printf "%b✓%b %s\n"  "$GREEN"  "$NC" "$*"; }
warn()    { printf "%b⚠%b %s\n"  "$YELLOW" "$NC" "$*"; }
die()     { printf "%b✗%b %s\n"  "$RED"    "$NC" "$*" >&2; exit 1; }

# ── locate repo root (script lives at aws/scripts/, so ../..) ────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# ── prompt helpers ───────────────────────────────────────────────────────────
prompt() {
  local label="$1" default="$2" var prompt_str
  if [[ -n "$default" ]]; then
    prompt_str=$(printf "%b%s%b [%s]: " "$BLUE" "$label" "$NC" "$default")
    read -r -p "$prompt_str" var
    echo "${var:-$default}"
  else
    prompt_str=$(printf "%b%s%b: " "$BLUE" "$label" "$NC")
    read -r -p "$prompt_str" var
    echo "$var"
  fi
}

confirm() {
  local msg="$1" answer prompt_str
  prompt_str=$(printf "%b%s%b [y/N]: " "$YELLOW" "$msg" "$NC")
  read -r -p "$prompt_str" answer
  [[ "$answer" =~ ^[Yy] ]]
}

prompt_choice() {
  local label="$1" default="$2" opts="$3" answer prompt_str
  while :; do
    prompt_str=$(printf "%b%s%b [%s]: " "$BLUE" "$label" "$NC" "$default")
    read -r -p "$prompt_str" answer
    answer="${answer:-$default}"
    if [[ "|$opts|" == *"|$answer|"* ]]; then
      echo "$answer"
      return
    fi
    warn "Invalid choice. Expected one of: $(echo "$opts" | tr '|' ' ')"
  done
}

# should_write_tfvars — safe overwrite of an existing tfvars file.
# Returns 0 (write) if file missing, or if user approves overwrite (with
# timestamped backup). Returns 1 (skip write, keep existing) otherwise.
# Rationale: users iterate on inputs. Silent overwrite loses hand-edits;
# unconditional skip locks them out. Backup + prompt is the safe middle.
should_write_tfvars() {
  local target="$1" backup
  if [[ ! -f "$target" ]]; then
    return 0
  fi
  warn "$target already exists."
  if confirm "  Overwrite it? (existing will be backed up)"; then
    backup="${target}.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$target" "$backup"
    info "  Backed up existing to $backup"
    echo
    return 0
  else
    info "  Keeping existing $target. Printed apply commands will still use it."
    echo
    return 1
  fi
}

# ── prerequisite check ───────────────────────────────────────────────────────
info "Checking for basic tools..."
for bin in terraform aws kubectl helm jq python3; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    warn "$bin not found on PATH — you'll need it to run the module commands."
  fi
done

# ── banner ───────────────────────────────────────────────────────────────────
echo
info "==================================================================="
info "  PIPELINE CONTROL GATEWAY GUIDED INSTALL"
info "  Writes tfvars + prints the terraform apply sequence."
info "  Does NOT run terraform for you — copy-paste the printed commands."
info "==================================================================="
echo

# ─── Step 0: topology ────────────────────────────────────────────────────────
info "Which topology are you deploying?"
info "  2 = intra-cluster — the workloads sending telemetry share the gateway's cluster."
info "      TLS via in-cluster cert-manager. No public DNS or ALB. Simplest."
info "  1 = out-of-cluster (private DNS + private CA) — senders live outside"
info "      the cluster the gateway runs in. Uses a private ALB and"
info "      an ACM Private CA (flat monthly charge). Internal-only, no public exposure."
TOPOLOGY=$(prompt_choice "Topology" "2" "1|2")
echo

# ─── Step 1: common config ───────────────────────────────────────────────────
AWS_REGION=$(prompt "AWS region" "us-west-1")
echo
info "Optional: does your AWS account require an IAM permissions boundary?"
info "  (Common in restricted enterprise accounts. Leave blank if unsure.)"
PERMISSIONS_BOUNDARY=$(prompt "permissions_boundary ARN (blank = none)" "")
echo

# ─── Step 2: BYO checklist (asked BEFORE topology-specific prompts, so we
# don't ask users to name things they won't create) ──────────────────────────
SKIP_VPC=""
SKIP_EKS=""
SKIP_CERT_MANAGER_INSTALLER=""
SKIP_PCG_CERTIFICATE=""
SKIP_ALB_CONTROLLER=""
SKIP_ROUTE53_PRIVATE_ZONE=""
BYO_PRIVATE_CA_ARN=""

BYO_VPC_ID=""
BYO_SUBNET_IDS=""
BYO_EKS_CLUSTER_NAME=""
BYO_ISSUER_NAME=""
BYO_CA_SECRET_NAME=""
BYO_CA_SECRET_NAMESPACE=""
BYO_TLS_SECRET_NAME=""
BYO_ROUTE53_ZONE_ID=""

info "==================================================================="
info "  BYO (Bring Your Own) infrastructure — asked first so subsequent"
info "  prompts skip questions about infra you're not creating"
info "==================================================================="
info "If you already have any of these — VPC, EKS cluster, cert-manager,"
info "ALB Controller, Route53 zone, Private CA — you can reuse them and"
info "skip those modules. Otherwise the modules will create them for you."
echo

if confirm "Do you want to reuse any existing AWS infrastructure?"; then
  echo
  if confirm "BYO VPC — do you have an existing VPC to reuse?"; then
    SKIP_VPC="y"
    info "  📝 To list your VPCs, run in another terminal:"
    info "       \$ aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,Tags[?Key==\`Name\`].Value|[0],CidrBlock]' --output table"
    BYO_VPC_ID=$(prompt "  Existing VPC ID (vpc-...)" "")
    info "  Your VPC must have private subnets in ≥ 2 AZs, tagged:"
    info "    kubernetes.io/role/internal-elb = 1"
    info "    kubernetes.io/cluster/<your-cluster-name> = shared"
    info "    (out-of-cluster: tag with BOTH cluster names — pcg-cluster and apps-cluster)"
    info "  📝 To list private subnets in your VPC:"
    info "       \$ aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc-id> --query 'Subnets[].[SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch]' --output table"
    # Loop until the user gives a valid comma-separated list of subnet-* IDs.
    # Empty input, trailing/leading commas, and non subnet-* tokens all get
    # rejected here — cheaper than letting terraform plan discover it later.
    while :; do
      BYO_SUBNET_IDS=$(prompt "  Private subnet IDs (comma-separated: subnet-aaa,subnet-bbb,subnet-ccc)" "")
      if [[ -z "$BYO_SUBNET_IDS" ]]; then
        warn "  Empty input. Enter at least one subnet ID."
        continue
      fi
      # bash read -a discards trailing empty fields, so we must catch
      # leading/trailing commas by string match before splitting.
      if [[ "$BYO_SUBNET_IDS" == ,* ]] || [[ "$BYO_SUBNET_IDS" == *, ]]; then
        warn "  Leading or trailing comma. Enter as: subnet-aaa,subnet-bbb (no extra commas)."
        continue
      fi
      # Split on comma, walk each token, reject anything that isn't subnet-*.
      # Also rebuild BYO_SUBNET_IDS from the TRIMMED tokens — otherwise the
      # tfvars writer (splits on comma without trimming) emits leading spaces
      # like ` subnet-abc` into the array literal.
      bad_token=""
      __trimmed_tokens=()
      IFS=',' read -r -a __subnet_tokens <<< "$BYO_SUBNET_IDS"
      for token in "${__subnet_tokens[@]}"; do
        # trim whitespace
        token="${token#"${token%%[![:space:]]*}"}"
        token="${token%"${token##*[![:space:]]}"}"
        if [[ -z "$token" ]] || [[ ! "$token" =~ ^subnet-[0-9a-f]+$ ]]; then
          bad_token="$token"
          break
        fi
        __trimmed_tokens+=("$token")
      done
      if [[ -n "$bad_token" ]] || [[ -z "$token" ]]; then
        warn "  Invalid subnet ID: '${bad_token:-<empty>}'. Each token must look like subnet-xxxxxxx (no spaces around commas)."
        continue
      fi
      # Rebuild from trimmed tokens so downstream awk-split sees clean values.
      BYO_SUBNET_IDS="$(IFS=,; echo "${__trimmed_tokens[*]}")"
      break
    done
    echo
  fi

  if confirm "BYO EKS — do you have an existing EKS cluster to reuse?"; then
    SKIP_EKS="y"
    info "  Requirements: K8s 1.29+, OIDC provider enabled, node group sized for the gateway."
    info "  📝 To list your EKS clusters in the region:"
    info "       \$ aws eks list-clusters --region <your-region>"
    BYO_EKS_CLUSTER_NAME=$(prompt "  Existing EKS cluster name" "")
    echo
  fi

  if [[ "$TOPOLOGY" == "2" ]]; then
    if confirm "BYO cert-manager — do you have cert-manager + a ClusterIssuer already?"; then
      SKIP_CERT_MANAGER_INSTALLER="y"
      info "  📝 To find your ClusterIssuer name:"
      info "       \$ kubectl get clusterissuer"
      BYO_ISSUER_NAME=$(prompt         "  Existing ClusterIssuer name"       "")
      info "  📝 To find the CA Secret name and its namespace:"
      info "       \$ kubectl get secret -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,TYPE:.type | grep -Ei 'ca|tls'"
      BYO_CA_SECRET_NAME=$(prompt      "  CA Secret name (contains ca.crt)"  "")
      BYO_CA_SECRET_NAMESPACE=$(prompt "  Namespace of the CA Secret"        "cert-manager")
      echo
    fi

    if confirm "BYO gateway TLS Secret — do you have a pre-made TLS Secret for the gateway?"; then
      SKIP_PCG_CERTIFICATE="y"
      info "  Your Secret must be type kubernetes.io/tls with keys tls.crt + tls.key."
      info "  SANs must cover the reverse-proxy Service DNS name apps target."
      info "  📝 To list TLS secrets in the newrelic namespace:"
      info "       \$ kubectl get secret -n newrelic --field-selector=type=kubernetes.io/tls"
      BYO_TLS_SECRET_NAME=$(prompt "  Existing TLS secret name in newrelic ns" "pcg-tls-secret")
      echo
    fi

  elif [[ "$TOPOLOGY" == "1" ]]; then
    if confirm "BYO ALB Controller — do you have AWS Load Balancer Controller installed?"; then
      SKIP_ALB_CONTROLLER="y"
      info "  Downstream Ingress just uses ingressClassName: alb. No tfvars needed —"
      info "  as long as your controller registers the 'alb' IngressClass, the Ingress works."
      info "  📝 To confirm the controller is running:"
      info "       \$ kubectl get deploy -n kube-system aws-load-balancer-controller"
      info "       \$ kubectl get ingressclass alb"
      echo
    fi

    if confirm "BYO Route53 private zone — do you have a private zone already?"; then
      SKIP_ROUTE53_PRIVATE_ZONE="y"
      info "  Your zone must be associated with the shared VPC (both clusters live there)."
      info "  📝 To list your Route53 private zones:"
      info "       \$ aws route53 list-hosted-zones --query 'HostedZones[?Config.PrivateZone==\`true\`].[Id,Name]' --output table"
      BYO_ROUTE53_ZONE_ID=$(prompt "  Existing Route53 private zone ID (Z...)" "")
      info "  We'll ask for the gateway hostname (subdomain in your zone) next."
      echo
    fi

    if confirm "BYO Private CA — do you have an ACM Private CA to reuse (avoids the flat monthly CA charge)?"; then
      info "  📝 To list ACTIVE Private CAs in the region:"
      info "       \$ aws acm-pca list-certificate-authorities --region <your-region> --query 'CertificateAuthorities[?Status==\`ACTIVE\`].[Arn,CertificateAuthorityConfiguration.Subject.CommonName,UsageMode]' --output table"
      BYO_PRIVATE_CA_ARN=$(prompt "  Existing ACM Private CA ARN (arn:aws:acm-pca:...)" "")
      info "  4.2-out-of-cluster-tls will still apply (it does cert issuance +"
      info "  distributing trust to the sender cluster), but will skip CA creation."
      echo
    fi
  fi
else
  info "Greenfield: all modules will be applied."
  echo
fi

# ─── Step 3: topology-specific config (conditional on BYO answers) ──────────
CLUSTER_NAME=""
PCG_CLUSTER_NAME=""
APPS_CLUSTER_NAME=""
VPC_NAME=""
ZONE_NAME=""
PCG_HOSTNAME=""
PROXY=""
LAYERED=""

# Small helper: derive parent zone from a hostname (pcg.internal.newrelic → internal.newrelic).
# Precondition: hostname MUST already have been validated as containing a dot.
# The caller is responsible for that check — because this function runs inside
# $(command substitution), an `exit` here would only kill the subshell, not the
# parent script. Validate at the prompt loop instead.
derive_zone() {
  local hostname="$1"
  echo "$hostname" | cut -d. -f2-
}

if [[ "$TOPOLOGY" == "2" ]]; then
  # Intra-cluster: one cluster. If we already captured it during BYO, reuse it.
  if [[ -n "$BYO_EKS_CLUSTER_NAME" ]]; then
    CLUSTER_NAME="$BYO_EKS_CLUSTER_NAME"
  else
    CLUSTER_NAME=$(prompt "EKS cluster name" "pcg-cluster")
  fi
  echo

  info "Reverse proxy inside the cluster (terminates TLS):"
  info "  n = NGINX  (module: aws/3-ingress/reverse-proxy-within-cluster/nginx)"
  info "  k = Kong   (module: aws/3-ingress/reverse-proxy-within-cluster/kong)"
  PROXY=$(prompt_choice "Reverse proxy" "n" "n|k")
  echo

elif [[ "$TOPOLOGY" == "1" ]]; then
  # Out-of-cluster: TWO clusters (gateway + apps). BYO EKS during setup only
  # captured one name — if set, use it for the gateway cluster (it's where the
  # gateway lives, typically the "existing" one), then still ask for the apps
  # cluster. If not BYO, ask for both.
  if [[ -n "$BYO_EKS_CLUSTER_NAME" ]]; then
    info "Using '$BYO_EKS_CLUSTER_NAME' from BYO EKS above as the gateway cluster."
    info "You still need to name your apps cluster (where telemetry senders run):"
    PCG_CLUSTER_NAME="$BYO_EKS_CLUSTER_NAME"
    APPS_CLUSTER_NAME=$(prompt "Apps cluster name" "apps-cluster")
  else
    PCG_CLUSTER_NAME=$(prompt  "Gateway cluster name"  "pcg-cluster")
    APPS_CLUSTER_NAME=$(prompt "Apps cluster name" "apps-cluster")
  fi
  echo

  # VPC name prefix — only relevant if we're CREATING the VPC (not BYO)
  if [[ -z "$SKIP_VPC" ]]; then
    VPC_NAME=$(prompt "Shared VPC name prefix (used for auto-discovery tags)" "pcg-shared")
    echo
  else
    VPC_NAME=""  # not written to tfvars when BYO VPC — vpc_id takes over
  fi

  # Gateway hostname — ALWAYS needed (it's the hostname apps use).
  # Zone name derived from it for the greenfield-zone path; ignored for BYO-zone.
  info "Gateway hostname (the FQDN apps will use to reach the gateway — e.g., pcg.internal.newrelic):"
  if [[ -n "$SKIP_ROUTE53_PRIVATE_ZONE" ]]; then
    info "  BYO zone: this hostname must be a subdomain of your existing zone."
  else
    info "  Greenfield: a private zone is created from the hostname's parent domain."
  fi
  # Loop until we get a hostname with at least one dot. cut -d. -f2- returns
  # the input UNCHANGED when there is no dot, so a bare "pcg" would silently
  # write zone_name = "pcg" and only fail minutes later at terraform plan.
  while :; do
    PCG_HOSTNAME=$(prompt "Gateway hostname" "pcg.internal.newrelic")
    if [[ "$PCG_HOSTNAME" != *.* ]]; then
      warn "  Gateway hostname must be a subdomain (e.g. pcg.internal.newrelic)."
      warn "  Cannot derive a parent zone from a bare hostname \"$PCG_HOSTNAME\" — please re-enter."
      continue
    fi
    break
  done
  if [[ -z "$SKIP_ROUTE53_PRIVATE_ZONE" ]]; then
    ZONE_NAME=$(derive_zone "$PCG_HOSTNAME")
    info "  Zone name derived: $ZONE_NAME"
  fi
  echo

  info "Optional: add an in-cluster NGINX/Kong proxy BETWEEN ALB and the gateway"
  info "  (layered Kong / NGINX patterns)"
  info "  n = No     (direct ALB → gateway, simplest)"
  info "  N = NGINX  layered (ALB → NGINX in cluster → gateway)"
  info "  K = Kong   layered (ALB → Kong  in cluster → gateway)"
  LAYERED=$(prompt_choice "Layered proxy" "n" "n|N|K")
  echo
fi

info "Gateway install mode:"
info "  f = Flux mode    — 1 values.yaml; installs Flux (needs cluster-admin)"
info "  x = Fluxless mode — 2 values.yaml files; namespace-scoped, no Flux"
PCG_MODE=$(prompt_choice "Gateway install mode" "f" "f|x")
echo

# ─── Step 4: write tfvars ────────────────────────────────────────────────────
build_common_tfvars() {
  local cluster_name="$1"
  cat <<EOF
# Auto-generated by aws/scripts/deploy.sh — edit before re-running terraform apply.

# ── Core ─────────────────────────────────────────────────────────────────────
cluster_name         = "$cluster_name"
aws_region           = "$AWS_REGION"
permissions_boundary = "$PERMISSIONS_BOUNDARY"
environment          = "dev"

EOF

  if [[ -n "$SKIP_VPC" ]]; then
    cat <<EOF
# ── BYO VPC (skipping aws/1-vpc) ─────────────────────────────────────────────
vpc_id     = "$BYO_VPC_ID"
subnet_ids = [$(echo "$BYO_SUBNET_IDS" | awk -F, '{for(i=1;i<=NF;i++)printf "\"%s\"%s", $i, (i<NF?", ":"")}')]

EOF
  fi

  if [[ "$TOPOLOGY" == "2" && -n "$SKIP_CERT_MANAGER_INSTALLER" ]]; then
    cat <<EOF
# ── BYO cert-manager (skipping 4-dns-tls/cert-manager/4.1-installer) ─────────
issuer_name         = "$BYO_ISSUER_NAME"
ca_secret_name      = "$BYO_CA_SECRET_NAME"
ca_secret_namespace = "$BYO_CA_SECRET_NAMESPACE"

EOF
  fi

  if [[ "$TOPOLOGY" == "2" && -n "$SKIP_PCG_CERTIFICATE" ]]; then
    cat <<EOF
# ── BYO gateway TLS Secret (skip 4-dns-tls/cert-manager/4.3-pcg-certificate) ─
tls_secret_name = "$BYO_TLS_SECRET_NAME"

EOF
  fi
}

build_out_of_cluster_extras() {
  cat <<EOF
# ── out-of-cluster ────────────────────────────────────────────────────────
pcg_cluster_name     = "$PCG_CLUSTER_NAME"
apps_cluster_name    = "$APPS_CLUSTER_NAME"
shared_cluster_names = ["$PCG_CLUSTER_NAME", "$APPS_CLUSTER_NAME"]
EOF

  # vpc_name only when we're CREATING the VPC (auto-discovery tag prefix).
  # BYO-VPC users skip this — vpc_id is already written above.
  if [[ -z "$SKIP_VPC" ]]; then
    cat <<EOF
vpc_name             = "$VPC_NAME"
EOF
  fi

  cat <<EOF

# ── DNS + TLS ────────────────────────────────────────────────────────────────
pcg_hostname = "$PCG_HOSTNAME"
EOF

  # zone_name only when we're CREATING the zone.
  # BYO-zone users already provided route53_zone_id below.
  if [[ -z "$SKIP_ROUTE53_PRIVATE_ZONE" ]]; then
    cat <<EOF
zone_name    = "$ZONE_NAME"
EOF
  fi

  echo

  if [[ -n "$SKIP_ROUTE53_PRIVATE_ZONE" ]]; then
    cat <<EOF
# ── BYO Route53 private zone (skipping 4-dns-tls/private/4.1-route53-private-zone) ──
route53_zone_id = "$BYO_ROUTE53_ZONE_ID"

EOF
  fi

  if [[ -n "$BYO_PRIVATE_CA_ARN" ]]; then
    cat <<EOF
# ── BYO ACM Private CA (still applies 4.2-out-of-cluster-tls, reuses existing CA) ──
private_ca_arn = "$BYO_PRIVATE_CA_ARN"

EOF
  fi

  if [[ "$LAYERED" == "N" ]]; then
    cat <<EOF
# ── out-of-cluster layered ALB → NGINX → gateway ─────────────────────────────
pcg_service_name     = "pcg-nginx"
pcg_otlp_http_port   = 80
pcg_nr_receiver_port = 80

EOF
  elif [[ "$LAYERED" == "K" ]]; then
    cat <<EOF
# ── out-of-cluster layered ALB → Kong → gateway ──────────────────────────────
# Kong chart 2.38.0 with proxy.tls.enabled=false exposes proxy.http.servicePort=80.
# If a future chart upgrade changes the default (e.g., 8000), update these.
pcg_service_name     = "pcg-kong-kong-proxy"
pcg_otlp_http_port   = 80
pcg_nr_receiver_port = 80

EOF
  fi

  cat <<EOF
# ── ALB Ingress on gateway install (5-pcg/*) ─────────────────────────────────
create_alb_ingress    = true
create_route53_record = true
alb_scheme            = "internal"
tls_secret_name       = "pcg-tls-secret"

EOF

  # route53_zone_id — either from BYO (already emitted above) or a placeholder
  # for greenfield users to fill in AFTER applying 4.1-route53-private-zone.
  if [[ -z "$SKIP_ROUTE53_PRIVATE_ZONE" ]]; then
    cat <<EOF
# ⚠️ REQUIRED — populate AFTER applying aws/4-dns-tls/private/4.1-route53-private-zone
#   cd aws/4-dns-tls/private/4.1-route53-private-zone
#   terraform output -raw zone_id
route53_zone_id = "REPLACE_AFTER_4.1_APPLY"

EOF
  fi

  # acm_certificate_arn — always REPLACE_ placeholder (module always creates
  # the cert; there's no BYO-ACM path today).
  cat <<EOF
# ⚠️ REQUIRED — populate AFTER applying aws/4-dns-tls/private/4.2-out-of-cluster-tls
#   cd aws/4-dns-tls/private/4.2-out-of-cluster-tls
#   terraform output -raw acm_certificate_arn
acm_certificate_arn = "REPLACE_AFTER_4.2_APPLY"

EOF
}

if [[ "$TOPOLOGY" == "2" ]]; then
  TFVARS_PATH="aws/intra-cluster.tfvars"
  if should_write_tfvars "$TFVARS_PATH"; then
    info "Writing $TFVARS_PATH..."
    build_common_tfvars "$CLUSTER_NAME" > "$TFVARS_PATH"
    success "Created $TFVARS_PATH"
  fi

elif [[ "$TOPOLOGY" == "1" ]]; then
  TFVARS_PCG="aws/out-of-cluster-private-dns-pcg.tfvars"
  TFVARS_APPS="aws/out-of-cluster-private-dns-apps.tfvars"

  if should_write_tfvars "$TFVARS_PCG"; then
    info "Writing $TFVARS_PCG..."
    {
      build_common_tfvars "$PCG_CLUSTER_NAME"
      build_out_of_cluster_extras
    } > "$TFVARS_PCG"
    success "Created $TFVARS_PCG"
  fi

  if should_write_tfvars "$TFVARS_APPS"; then
    info "Writing $TFVARS_APPS..."
    {
      build_common_tfvars "$APPS_CLUSTER_NAME"
      cat <<EOF
# ── out-of-cluster (apps-cluster context) ────────────────────────────────
pcg_cluster_name     = "$PCG_CLUSTER_NAME"
apps_cluster_name    = "$APPS_CLUSTER_NAME"
shared_cluster_names = ["$PCG_CLUSTER_NAME", "$APPS_CLUSTER_NAME"]
EOF
      if [[ -z "$SKIP_VPC" ]]; then
        cat <<EOF
vpc_name             = "$VPC_NAME"
EOF
      fi
      echo
    } > "$TFVARS_APPS"
    success "Created $TFVARS_APPS"
  fi
fi

# ─── Step 5: print apply sequence ────────────────────────────────────────────
echo
info "==================================================================="
info "  APPLY SEQUENCE — copy-paste one command at a time from repo root"
info "==================================================================="
info "Verify each 'Plan: N to add, 0 to change, 0 to destroy' before typing 'yes'."
info "Gateway install (Step 5) MUST come before the reverse proxy (Step 6) —"
info "NGINX/Kong resolves the gateway upstream at startup, so the gateway must exist first."
echo

step() {
  local skip_flag="$1" step_num="$2" description="$3" cmd="$4"
  if [[ -n "$skip_flag" ]]; then
    printf "  # Step %s: %s\n" "$step_num" "$description"
    printf "  # SKIPPED (BYO in tfvars).\n\n"
  else
    printf "  # Step %s: %s\n" "$step_num" "$description"
    printf "  %s\n\n" "$cmd"
  fi
}

if [[ "$TOPOLOGY" == "2" ]]; then
  echo "  # ═══ intra-cluster apply — run from repo root ══════════════════════════════════════"
  echo

  step "$SKIP_VPC" "1" "VPC + NAT gateways + subnets" \
    "(cd aws/1-vpc && terraform init && terraform apply -var-file=../intra-cluster.tfvars)"

  step "$SKIP_EKS" "2" "EKS cluster + node group + IAM + OIDC" \
    "(cd aws/2-eks && terraform init && terraform apply -var-file=../intra-cluster.tfvars)"

  step "$SKIP_CERT_MANAGER_INSTALLER" "3" "cert-manager (Helm chart + CRDs)" \
    "(cd aws/4-dns-tls/cert-manager/4.1-installer && terraform init && terraform apply -var-file=../../../intra-cluster.tfvars)"

  step "$SKIP_CERT_MANAGER_INSTALLER" "4a" "Internal CA + ClusterIssuer" \
    "(cd aws/4-dns-tls/cert-manager/4.2-cluster-issuer && terraform init && terraform apply -var-file=../../../intra-cluster.tfvars)"

  step "$SKIP_PCG_CERTIFICATE" "4b" "Gateway TLS cert + CA bundle Secret" \
    "(cd aws/4-dns-tls/cert-manager/4.3-pcg-certificate && terraform init && terraform apply -var-file=../../../intra-cluster.tfvars)"

  echo "  # Step 5: gateway install — MUST run before the reverse proxy below."
  echo "  #   Get values.yaml from New Relic UI → Pipeline Control → Setup wizard first."
  if [[ "$PCG_MODE" == "f" ]]; then
    cat <<'EOF'
  cp /path/to/values-newrelic-gateway.yaml aws/5-pcg/flux/pcg-values.yaml
  (cd aws/5-pcg/flux && terraform init && terraform apply -var-file=../../intra-cluster.tfvars -var="pcg_values_file=./pcg-values.yaml")

EOF
  else
    cat <<'EOF'
  cp /path/to/agent-control-deployment-values.yaml   aws/5-pcg/fluxless/agent-control-values.yaml
  cp /path/to/pipeline-control-gateway-values.yaml   aws/5-pcg/fluxless/pcg-values.yaml
  (cd aws/5-pcg/fluxless && terraform init && terraform apply -var-file=../../intra-cluster.tfvars -var="agent_control_values_file=./agent-control-values.yaml" -var="pcg_values_file=./pcg-values.yaml")

EOF
  fi

  if [[ "$PROXY" == "n" ]]; then
    cat <<'EOF'
  # Step 6: Reverse proxy (NGINX)
  (cd aws/3-ingress/reverse-proxy-within-cluster/nginx && terraform init && terraform apply -var-file=../../../intra-cluster.tfvars)

EOF
  else
    cat <<'EOF'
  # Step 6: Reverse proxy (Kong)
  (cd aws/3-ingress/reverse-proxy-within-cluster/kong && terraform init && terraform apply -var-file=../../../intra-cluster.tfvars)

EOF
  fi

elif [[ "$TOPOLOGY" == "1" ]]; then
  echo "  # ═══ out-of-cluster (private DNS) apply — run from repo root ═══════════════"
  echo "  # Two tfvars files. EKS module runs TWICE via Terraform workspaces (one per cluster)."
  echo

  step "$SKIP_VPC" "1" "Shared VPC + NAT gateways + subnets (once)" \
    "(cd aws/1-vpc && terraform init && terraform apply -var-file=../out-of-cluster-private-dns-pcg.tfvars)"

  if [[ -n "$SKIP_EKS" ]]; then
    printf "  # Step 2: EKS (BOTH clusters)\n  # SKIPPED (BYO in tfvars).\n\n"
  else
    cat <<'EOF'
  # Step 2: EKS (BOTH clusters) — one workspace per cluster
  cd aws/2-eks
  terraform init
  terraform workspace new pcg-cluster  2>/dev/null || terraform workspace select pcg-cluster
  terraform apply -var-file=../out-of-cluster-private-dns-pcg.tfvars
  terraform workspace new apps-cluster 2>/dev/null || terraform workspace select apps-cluster
  terraform apply -var-file=../out-of-cluster-private-dns-apps.tfvars
  terraform workspace select default
  cd -

EOF
  fi

  step "$SKIP_ALB_CONTROLLER" "3" "ALB Controller (installed on pcg-cluster)" \
    "(cd aws/3-ingress/alb && terraform init && terraform apply -var-file=../../out-of-cluster-private-dns-pcg.tfvars)"

  step "$SKIP_ROUTE53_PRIVATE_ZONE" "4a" "Route53 private zone" \
    "(cd aws/4-dns-tls/private/4.1-route53-private-zone && terraform init && terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars)"

  # Greenfield zone: remind user to copy the output back into tfvars before Step 5.
  if [[ -z "$SKIP_ROUTE53_PRIVATE_ZONE" ]]; then
    cat <<'EOF'
  # ⚠️ After Step 4a completes, copy the output zone_id into your tfvars.
  # The sed anchors on the tfvars KEY (`route53_zone_id`) rather than the
  # placeholder — so re-applying 4.1 (which may produce a new zone ID)
  # correctly refreshes the tfvars, even if the placeholder was already
  # substituted on a previous run.
  ZONE_ID=$(cd aws/4-dns-tls/private/4.1-route53-private-zone && terraform output -raw zone_id)
  sed -i.bak "s|^route53_zone_id.*|route53_zone_id = \"$ZONE_ID\"|" aws/out-of-cluster-private-dns-pcg.tfvars

EOF
  fi

  if [[ -n "$BYO_PRIVATE_CA_ARN" ]]; then
    cat <<'EOF'
  # Step 4b: Out-of-cluster TLS (BYO Private CA - no flat monthly CA charge)
  (cd aws/4-dns-tls/private/4.2-out-of-cluster-tls && terraform init && terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars)

EOF
  else
    cat <<'EOF'
  # Step 4b: Out-of-cluster TLS - ⚠️ Creates an AWS Private CA (flat monthly charge)
  (cd aws/4-dns-tls/private/4.2-out-of-cluster-tls && terraform init && terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars)

EOF
  fi

  cat <<'EOF'
  # ⚠️ After Step 4b completes, copy the output acm_certificate_arn into your tfvars.
  # Anchors on the key so a re-apply refreshes the tfvars idempotently.
  ACM_ARN=$(cd aws/4-dns-tls/private/4.2-out-of-cluster-tls && terraform output -raw acm_certificate_arn)
  sed -i.bak "s|^acm_certificate_arn.*|acm_certificate_arn = \"$ACM_ARN\"|" aws/out-of-cluster-private-dns-pcg.tfvars

EOF

  echo "  # Step 5: gateway install — MUST run before any layered proxy below."
  echo "  #   Get values.yaml from New Relic UI → Pipeline Control → Setup wizard first."
  if [[ "$PCG_MODE" == "f" ]]; then
    cat <<'EOF'
  cp /path/to/values-newrelic-gateway.yaml aws/5-pcg/flux/pcg-values.yaml
  (cd aws/5-pcg/flux && terraform init && terraform apply -var-file=../../out-of-cluster-private-dns-pcg.tfvars -var="pcg_values_file=./pcg-values.yaml")

EOF
  else
    cat <<'EOF'
  cp /path/to/agent-control-deployment-values.yaml   aws/5-pcg/fluxless/agent-control-values.yaml
  cp /path/to/pipeline-control-gateway-values.yaml   aws/5-pcg/fluxless/pcg-values.yaml
  (cd aws/5-pcg/fluxless && terraform init && terraform apply -var-file=../../out-of-cluster-private-dns-pcg.tfvars -var="agent_control_values_file=./agent-control-values.yaml" -var="pcg_values_file=./pcg-values.yaml")

EOF
  fi

  if [[ "$LAYERED" == "N" ]]; then
    cat <<'EOF'
  # Step 6: Layered NGINX proxy (ALB → NGINX → gateway)
  #   The ALB Ingress in Step 5 already references pcg-nginx as its backend
  #   (deploy.sh wrote pcg_service_name = "pcg-nginx" to tfvars). ALB Controller
  #   reconciles automatically once the Service appears in ~30-60s — no re-apply
  #   of Step 5 needed. Verify with:  kubectl get endpoints pcg-nginx -n newrelic
  (cd aws/3-ingress/reverse-proxy-within-cluster/nginx && terraform init && terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars -var="nginx_tls_enabled=false")

EOF
  elif [[ "$LAYERED" == "K" ]]; then
    cat <<'EOF'
  # Step 6: Layered Kong proxy (ALB → Kong → gateway)
  #   The ALB Ingress in Step 5 already references pcg-kong-kong-proxy as its
  #   backend (deploy.sh wrote pcg_service_name to tfvars). ALB Controller
  #   reconciles automatically once the Service appears in ~30-60s — no
  #   re-apply of Step 5 needed. Verify with:
  #     kubectl get endpoints pcg-kong-kong-proxy -n newrelic
  (cd aws/3-ingress/reverse-proxy-within-cluster/kong && terraform init && terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars -var="proxy_tls_enabled=false")

EOF
  fi
fi

# ── Post-apply hints ─────────────────────────────────────────────────────────
info "==================================================================="
info "  AFTER APPLY — verify"
info "==================================================================="
if [[ "$TOPOLOGY" == "2" ]]; then
  info "  # Send test OTLP logs through the in-cluster path:"
  info "  export NR_LICENSE_KEY=<your-ingest-license-from-values.yaml>"
  if [[ "$PROXY" == "k" ]]; then
    # Kong picked at prompt — override the script's NGINX default so DNS lookup
    # finds Kong's Service. Without this override curl fails with:
    #   Could not resolve host: pcg-nginx.newrelic.svc.cluster.local
    info "  PCG_HOSTNAME=pcg-kong-kong-proxy.newrelic.svc.cluster.local \\"
    info "    aws/tests/send-inventory-logs-intra-cluster.sh"
  else
    info "  aws/tests/send-inventory-logs-intra-cluster.sh"
  fi
elif [[ "$TOPOLOGY" == "1" ]]; then
  info "  # Send test OTLP logs through the out-of-cluster path:"
  info "  export NR_LICENSE_KEY=<your-ingest-license-from-pcg-values.yaml>"
  info "  export CTX_APPS=arn:aws:eks:${AWS_REGION}:<account-id>:cluster/${APPS_CLUSTER_NAME}"
  info "  aws/tests/send-inventory-logs-out-of-cluster.sh"
fi
echo
info "See aws/README.md for the full walkthrough + troubleshooting."
info "For teardown: aws/scripts/teardown.sh"

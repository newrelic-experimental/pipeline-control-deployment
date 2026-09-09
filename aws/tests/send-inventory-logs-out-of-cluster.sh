#!/usr/bin/env bash
#
# Send 4 OTLP log records through the out-of-cluster gateway deployment.
# Validates the full path:
#   pod in apps-cluster → VPC DNS resolver → Route53 private zone →
#   internal ALB in pcg-cluster → gateway → New Relic
#
# Sibling of send-inventory-logs-intra-cluster.sh but adapted for the
# out-of-cluster / private CA topology.
#
# Differences from the intra-cluster sibling:
#   - Runs the curl pod in APPS-CLUSTER (default namespace), not pcg-cluster.
#   - CA is mounted from a SECRET (pcg-ca-bundle) — 4.2-out-of-cluster-tls writes it as a
#     Secret in apps-cluster, not a ConfigMap.
#   - Endpoint is https://pcg.internal.newrelic/v1/logs (private zone name).
#   - TLS terminates at the AWS ALB (not NGINX). Server cert is issued by the
#     ACM Private CA (4.2-out-of-cluster-tls); apps-cluster trusts it via the CA bundle.
#
# Prereqs (modules 1-vpc through 5-pcg applied):
#   - $CTX_APPS points at apps-cluster kubectl context
#   - Secret `pcg-ca-bundle` exists in apps-cluster's `default` namespace
#   - Route53 record pcg.internal.newrelic → ALB exists in the private zone
#   - The gateway is Running in pcg-cluster and the Ingress has an ADDRESS
#
# Usage:
#   export NR_LICENSE_KEY=<your-ingest-license-from-pcg-values.yaml>
#   export CTX_APPS=arn:aws:eks:<region>:<account-id>:cluster/apps-cluster
#   ./send-inventory-logs-out-of-cluster.sh

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Config — override via env if needed
# ─────────────────────────────────────────────────────────────────────────────
PCG_HOSTNAME="${PCG_HOSTNAME:-pcg.internal.newrelic}"
NAMESPACE="${NAMESPACE:-default}"
CA_SECRET="${CA_SECRET:-pcg-ca-bundle}"
TEST_ID="${TEST_ID:-PCG-OUT-OF-CLUSTER-$(date +%s)}"

# The kubectl context targeting apps-cluster. Falls back to whatever's active.
CTX_APPS="${CTX_APPS:-}"
KCTL=(kubectl)
if [[ -n "$CTX_APPS" ]]; then
  KCTL=(kubectl --context "$CTX_APPS")
fi

if [[ -z "${NR_LICENSE_KEY:-}" ]]; then
  echo "ERROR: NR_LICENSE_KEY env var is not set." >&2
  echo "  export NR_LICENSE_KEY=<your-ingest-license-from-pcg-values.yaml>" >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Sanity checks against the live apps-cluster
# ─────────────────────────────────────────────────────────────────────────────
echo "Checking apps-cluster access..."
"${KCTL[@]}" get ns "$NAMESPACE" >/dev/null

echo "Checking CA bundle Secret exists..."
if ! "${KCTL[@]}" get secret "$CA_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: Secret $CA_SECRET not found in namespace $NAMESPACE." >&2
  echo "  Did the 4.2-out-of-cluster-tls module apply successfully?" >&2
  exit 1
fi

echo ""
echo "=========================================="
echo "TEST: $TEST_ID"
if [[ -n "$CTX_APPS" ]]; then
  echo "Context:  $CTX_APPS (via CTX_APPS override)"
else
  echo "Context:  $(kubectl config current-context)"
fi
echo "Endpoint: https://$PCG_HOSTNAME/v1/logs"
echo "=========================================="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Build all 4 OTLP payloads ahead of time, then send them from ONE pod
# ─────────────────────────────────────────────────────────────────────────────
TS=$(python3 -c "import time; print(int(time.time() * 1000000000))")
TS1=$TS
TS2=$((TS + 100000000))
TS3=$((TS + 200000000))
TS4=$((TS + 300000000))

read -r -d '' PAYLOAD_1 <<EOF || true
{
  "resourceLogs": [{
    "resource": {"attributes": [
      {"key": "host.name", "value": {"stringValue": "inventory-host-01"}},
      {"key": "service.name", "value": {"stringValue": "inventory-service"}}
    ]},
    "scopeLogs": [{
      "scope": {"name": "test-logger", "version": "1.0.0"},
      "logRecords": [{
        "timeUnixNano": "$TS1",
        "observedTimeUnixNano": "$TS1",
        "severityNumber": 9,
        "severityText": "INFO",
        "body": {"stringValue": "NGINX access log - GET /api/inventory/items/1 200 OK"},
        "attributes": [
          {"key": "testID", "value": {"stringValue": "$TEST_ID"}},
          {"key": "team", "value": {"stringValue": "alpha"}},
          {"key": "type", "value": {"stringValue": "beta"}},
          {"key": "logtype", "value": {"stringValue": "nginx"}},
          {"key": "request.path", "value": {"stringValue": "/api/inventory/items/1"}}
        ]
      }]
    }]
  }]
}
EOF

read -r -d '' PAYLOAD_2 <<EOF || true
{
  "resourceLogs": [{
    "resource": {"attributes": [
      {"key": "host.name", "value": {"stringValue": "inventory-host-02"}},
      {"key": "service.name", "value": {"stringValue": "inventory-service"}}
    ]},
    "scopeLogs": [{
      "scope": {"name": "test-logger", "version": "1.0.0"},
      "logRecords": [{
        "timeUnixNano": "$TS2",
        "observedTimeUnixNano": "$TS2",
        "severityNumber": 9,
        "severityText": "INFO",
        "body": {"stringValue": "Inventory app log - Processing item #1"},
        "attributes": [
          {"key": "testID", "value": {"stringValue": "$TEST_ID"}},
          {"key": "team", "value": {"stringValue": "blue"}},
          {"key": "type", "value": {"stringValue": "red"}},
          {"key": "item.id", "value": {"stringValue": "ITEM-001"}}
        ]
      }]
    }]
  }]
}
EOF

read -r -d '' PAYLOAD_3 <<EOF || true
{
  "resourceLogs": [{
    "resource": {"attributes": [
      {"key": "host.name", "value": {"stringValue": "inventory-host-03"}}
    ]},
    "scopeLogs": [{
      "scope": {"name": "test-logger", "version": "1.0.0"},
      "logRecords": [{
        "timeUnixNano": "$TS3",
        "observedTimeUnixNano": "$TS3",
        "severityNumber": 9,
        "severityText": "INFO",
        "body": {"stringValue": "Apache access log - GET /inventory/status 200"},
        "attributes": [
          {"key": "testID", "value": {"stringValue": "$TEST_ID"}},
          {"key": "service.name", "value": {"stringValue": "inventory-service"}},
          {"key": "logtype", "value": {"stringValue": "apache"}},
          {"key": "request.path", "value": {"stringValue": "/inventory/status"}}
        ]
      }]
    }]
  }]
}
EOF

read -r -d '' PAYLOAD_4 <<EOF || true
{
  "resourceLogs": [{
    "resource": {"attributes": [
      {"key": "host.name", "value": {"stringValue": "infra-host-01"}}
    ]},
    "scopeLogs": [{
      "scope": {"name": "test-logger", "version": "1.0.0"},
      "logRecords": [{
        "timeUnixNano": "$TS4",
        "observedTimeUnixNano": "$TS4",
        "severityNumber": 9,
        "severityText": "INFO",
        "body": {"stringValue": "NGINX access log - GET /delivery/status 200"},
        "attributes": [
          {"key": "testID", "value": {"stringValue": "$TEST_ID"}},
          {"key": "service.name", "value": {"stringValue": "infra-instant-delivery-service"}},
          {"key": "logtype", "value": {"stringValue": "nginx"}},
          {"key": "request.path", "value": {"stringValue": "/delivery/status"}}
        ]
      }]
    }]
  }]
}
EOF

# ─────────────────────────────────────────────────────────────────────────────
# Run a single curl pod in APPS-CLUSTER that posts all 4 payloads, mounting:
#  - the CA bundle Secret so TLS verifies the Private-CA-issued server cert
#  - each payload written to /tmp inside the pod on demand
# ─────────────────────────────────────────────────────────────────────────────
echo "Spawning curl pod inside apps-cluster (verifies private DNS + TLS + ALB + the gateway)..."
echo ""

POD_NAME="pcg-log-tester-$(date +%s)"
LICENSE_SECRET="pcg-log-tester-license-$(date +%s)"

# Create the license Secret from the shell env value. Sourcing the key from a
# Secret (rather than passing it as an env value) keeps the key out of
# `kubectl describe` and out of any workload YAML dumps for the pod's lifetime.
"${KCTL[@]}" create secret generic "$LICENSE_SECRET" \
  --namespace "$NAMESPACE" \
  --from-literal=license-key="$NR_LICENSE_KEY" \
  --dry-run=client -o yaml | "${KCTL[@]}" apply -f - >/dev/null

cat <<MANIFEST | "${KCTL[@]}" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NAMESPACE
  labels:
    app: pcg-log-tester
    testID: $TEST_ID
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "300"]
      env:
        - name: LICENSE_KEY
          valueFrom:
            secretKeyRef:
              name: $LICENSE_SECRET
              key: license-key
        - name: TEST_ID
          value: "$TEST_ID"
      volumeMounts:
        - name: ca-bundle
          mountPath: /etc/ssl/certs/pcg-ca.crt
          subPath: ca.crt
          readOnly: true
  volumes:
    - name: ca-bundle
      secret:
        secretName: $CA_SECRET
MANIFEST

# Wait for the pod to be Running
echo -n "Waiting for $POD_NAME to be Running"
for _ in $(seq 1 30); do
  phase=$("${KCTL[@]}" get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "$phase" == "Running" ]]; then
    echo " ✓"
    break
  fi
  echo -n "."
  sleep 1
done

if [[ "$("${KCTL[@]}" get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')" != "Running" ]]; then
  echo "" >&2
  echo "ERROR: Pod $POD_NAME never became Running." >&2
  "${KCTL[@]}" describe pod "$POD_NAME" -n "$NAMESPACE" >&2
  "${KCTL[@]}" delete pod "$POD_NAME" -n "$NAMESPACE" --wait=false >/dev/null
  exit 1
fi

# Always clean up the pod AND the license Secret on exit (success, error, or Ctrl+C).
# Use double quotes on the trap body so ${KCTL[*]} expands NOW, not at trap-fire
# time — inside a single-quoted trap body the array expansion is passed as a
# literal string and the cleanup silently fails.
trap "${KCTL[*]} delete pod $POD_NAME secret $LICENSE_SECRET -n $NAMESPACE --wait=false >/dev/null 2>&1 || true" EXIT

# Helper: run curl inside the pod with a given JSON payload
send_log() {
  local label="$1"
  local payload="$2"
  echo "$label"
  "${KCTL[@]}" exec -n "$NAMESPACE" "$POD_NAME" -- sh -c '
    cat > /tmp/payload.json <<JSON
'"$payload"'
JSON
    curl -sS -w "\nHTTP_CODE:%{http_code}\n" \
      --cacert /etc/ssl/certs/pcg-ca.crt \
      -X POST "https://'"$PCG_HOSTNAME"'/v1/logs" \
      -H "Content-Type: application/json" \
      -H "Api-Key: $LICENSE_KEY" \
      --data-binary @/tmp/payload.json
  '
  echo ""
}

send_log "1. inventory-service + logtype=nginx"   "$PAYLOAD_1"
send_log "2. inventory-service + NO logtype"      "$PAYLOAD_2"
send_log "3. inventory-service + logtype=apache"  "$PAYLOAD_3"
send_log "4. infra-instant-delivery + nginx"      "$PAYLOAD_4"

echo "=========================================="
echo "ALL 4 TEST LOGS SENT!"
echo "=========================================="
echo ""
echo "Test ID: $TEST_ID"
echo ""
echo "NRDB Query:"
echo "  FROM Log SELECT * WHERE testID = '$TEST_ID' SINCE 5 minutes ago"
echo ""
echo "If results appear in New Relic, the full out-of-cluster data path works:"
echo "  apps-cluster pod → VPC DNS → private zone → ALB (TLS via Private CA) → gateway → New Relic"

#!/usr/bin/env bash
#
# Send 4 OTLP log records through the in-cluster gateway (intra-cluster pattern).
# Validates the full path: in-cluster pod → k8s Service DNS → NGINX or Kong
# (TLS terminate) → gateway → New Relic.
#
# Note: no CoreDNS rewrite is used (it was destroy-unsafe). Apps reach
# the reverse proxy via the k8s-native Service DNS name (default: pcg-nginx
# for the NGINX module; switch to pcg-kong-kong-proxy for Kong).
#
# Note: the CA bundle is a Secret (not a ConfigMap). Key: ca.crt.
#
# Prereqs:
#   - You can `kubectl get pods -n newrelic` against the target cluster.
#   - `pcg-ca-bundle` Secret exists in `newrelic` (created by 4.3-pcg-certificate module).
#   - NR_LICENSE_KEY is set in your shell (the same value from your values.yaml).
#
# Usage:
#   # Default: sends via NGINX proxy
#   export NR_LICENSE_KEY=<your-ingest-license-from-values.yaml>
#   ./send-inventory-logs-intra-cluster.sh
#
#   # Or to send via Kong proxy instead:
#   PCG_HOSTNAME=pcg-kong-kong-proxy.newrelic.svc.cluster.local \
#     ./send-inventory-logs-intra-cluster.sh

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Config — override via env if needed
# ─────────────────────────────────────────────────────────────────────────────
# Default hostname points at NGINX's Service. For Kong: pcg-kong-kong-proxy.newrelic.svc.cluster.local
PCG_HOSTNAME="${PCG_HOSTNAME:-pcg-nginx.newrelic.svc.cluster.local}"
NAMESPACE="${NAMESPACE:-newrelic}"
CA_SECRET="${CA_SECRET:-pcg-ca-bundle}"
TEST_ID="${TEST_ID:-PCG-INTRA-CLUSTER-$(date +%s)}"

if [[ -z "${NR_LICENSE_KEY:-}" ]]; then
  echo "ERROR: NR_LICENSE_KEY env var is not set." >&2
  echo "  export NR_LICENSE_KEY=<your-ingest-license-from-values.yaml>" >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Sanity checks against the live cluster
# ─────────────────────────────────────────────────────────────────────────────
echo "Checking cluster access..."
kubectl get ns "$NAMESPACE" >/dev/null

echo "Checking CA bundle Secret exists..."
if ! kubectl get secret "$CA_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: Secret $CA_SECRET not found in namespace $NAMESPACE." >&2
  echo "  Did aws/4-dns-tls/cert-manager/4.3-pcg-certificate apply successfully?" >&2
  exit 1
fi

echo ""
echo "=========================================="
echo "TEST: $TEST_ID"
echo "Cluster:  $(kubectl config current-context)"
echo "Endpoint: https://$PCG_HOSTNAME/v1/logs"
echo "=========================================="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Build all 4 OTLP payloads ahead of time, then send them from ONE pod
# (faster than 4 separate `kubectl run` calls — each takes 5-10s).
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
# Run a single curl pod that posts all 4 payloads, mounting:
#  - the CA bundle so TLS verifies the self-signed cert properly
#  - the payloads via stdin (read into the pod via heredoc + curl --data-binary @-)
# ─────────────────────────────────────────────────────────────────────────────
echo "Spawning curl pod inside cluster (verifies DNS + TLS + NGINX + the gateway)..."
echo ""

# Build a manifest with the CA mounted and the license key from a Secret,
# then exec inside it. Sourcing the key from a Secret (rather than passing it
# as an env value) keeps the key out of `kubectl describe` and out of any
# workload YAML dumps for the pod's lifetime.
POD_NAME="pcg-log-tester-$(date +%s)"
LICENSE_SECRET="pcg-log-tester-license-$(date +%s)"

# Create the license Secret from the shell env value. --dry-run + apply keeps
# the secret out of shell history and off the command line.
kubectl create secret generic "$LICENSE_SECRET" \
  --namespace "$NAMESPACE" \
  --from-literal=license-key="$NR_LICENSE_KEY" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Use a heredoc to define the pod, run it to completion, then clean it up.
cat <<MANIFEST | kubectl apply -f - >/dev/null
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
  phase=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "$phase" == "Running" ]]; then
    echo " ✓"
    break
  fi
  echo -n "."
  sleep 1
done

if [[ "$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')" != "Running" ]]; then
  echo "" >&2
  echo "ERROR: Pod $POD_NAME never became Running." >&2
  kubectl describe pod "$POD_NAME" -n "$NAMESPACE" >&2
  kubectl delete pod "$POD_NAME" -n "$NAMESPACE" --wait=false >/dev/null
  exit 1
fi

# Always clean up the pod AND the license Secret on exit (success, error, or Ctrl+C)
trap 'kubectl delete pod "$POD_NAME" secret "$LICENSE_SECRET" -n "$NAMESPACE" --wait=false >/dev/null 2>&1 || true' EXIT

# Helper: run curl inside the pod with a given JSON payload
send_log() {
  local label="$1"
  local payload="$2"
  echo "$label"
  kubectl exec -n "$NAMESPACE" "$POD_NAME" -- sh -c '
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
echo "If results appear in New Relic, the full intra-cluster pattern data path works:"
echo "  in-cluster pod → k8s Service DNS ($PCG_HOSTNAME) → NGINX/Kong (TLS) → gateway → New Relic"

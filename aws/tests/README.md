# Test telemetry helpers

Two scripts that send real OTLP log records through a deployed gateway and confirm the whole path works, end to end. Use them as the final verification step after `terraform apply`.

Each script spins up a short-lived `curl` pod inside your cluster, mounts the CA bundle so the pod trusts the gateway's certificate, posts four OTLP log records, and reports the HTTP status of each. Four `200`s mean the path is good; the records then show up in New Relic within a minute or two.

| Script | Use with | Where the pod runs | Endpoint it targets |
|---|---|---|---|
| [`send-inventory-logs-intra-cluster.sh`](send-inventory-logs-intra-cluster.sh) | Intra-cluster topology | The cluster running both the gateway and the senders | The in-cluster proxy's Service DNS name |
| [`send-inventory-logs-out-of-cluster.sh`](send-inventory-logs-out-of-cluster.sh) | Out-of-cluster topology | A sending cluster, outside the gateway's own | The private-zone hostname, via the internal ALB |

## Requirements

- `kubectl`, authenticated against the relevant cluster
- `python3` (used to generate nanosecond OTLP timestamps; `date +%s%N` is not portable to macOS)
- The gateway already deployed and running, with its TLS material in place

## Running them

Both scripts take all configuration from the environment.

```bash
# Required for both. Two ways to set it:

# Option 1 — paste it in (substitute your real key; don't include the angle brackets):
export NR_LICENSE_KEY="YOUR_INGEST_LICENSE_KEY"

# Option 2 — extract it from the values.yaml the New Relic install wizard gave you.
# Field is `licenseKey:` in pcg-values.yaml (or agent-control-values.yaml in Fluxless mode).
export NR_LICENSE_KEY=$(awk '/^\s*licenseKey:/ {print $2}' aws/5-pcg/flux/pcg-values.yaml)
echo "Length: ${#NR_LICENSE_KEY} (expect 40)"       # sanity check — real key is 40 chars

# Intra-cluster — NGINX (default)
./send-inventory-logs-intra-cluster.sh

# Intra-cluster — Kong (override the NGINX default)
PCG_HOSTNAME=pcg-kong-kong-proxy.newrelic.svc.cluster.local \
  ./send-inventory-logs-intra-cluster.sh

# Out-of-cluster: also point at the sending cluster
export CTX_APPS=arn:aws:eks:<region>:<account-id>:cluster/apps-cluster
./send-inventory-logs-out-of-cluster.sh
```

The license key is the one in the `values.yaml` you downloaded from the New Relic UI.

### Optional overrides

| Variable | Default (intra-cluster) | Default (out-of-cluster) |
|---|---|---|
| `PCG_HOSTNAME` | `pcg-nginx.newrelic.svc.cluster.local` | `pcg.internal.newrelic` |
| `NAMESPACE` | `newrelic` | `default` |
| `CA_SECRET` | `pcg-ca-bundle` | `pcg-ca-bundle` |
| `TEST_ID` | generated from the current timestamp | generated from the current timestamp |

**If you deployed Kong** rather than NGINX (Step 6 chose `k`), you MUST set `PCG_HOSTNAME=pcg-kong-kong-proxy.newrelic.svc.cluster.local` — otherwise `curl` fails with `Could not resolve host: pcg-nginx.newrelic.svc.cluster.local`, since that Service only exists when the NGINX module is applied.

## Confirming the data arrived

Each run prints its `TEST_ID`. Query for it in New Relic:

```
FROM Log SELECT * WHERE testID = '<the TEST_ID the script printed>' SINCE 5 minutes ago
```

## If it fails

- **`Could not resolve host: pcg-nginx.newrelic.svc.cluster.local`** on the intra-cluster script — you deployed Kong, not NGINX. Re-run with `PCG_HOSTNAME=pcg-kong-kong-proxy.newrelic.svc.cluster.local` prefixed.
- **`Could not resolve host`** on the out-of-cluster script — Route53 records can take a minute to propagate after `terraform apply`. Wait and re-run.
- **TLS verification errors** — the CA bundle Secret is missing or holds the wrong certificate. Check that [`4.2-out-of-cluster-tls`](../4-dns-tls/private/4.2-out-of-cluster-tls/) (out-of-cluster) or [`4.3-pcg-certificate`](../4-dns-tls/cert-manager/4.3-pcg-certificate/) (intra-cluster) applied cleanly.
- **Connection refused or timeout** — the gateway pods or the proxy in front of them are not ready. Check `kubectl get pods -n newrelic`.
- **`403` or `401`** — the license key is wrong, or it's a user API key rather than an ingest license key.

## Realistic app check — `sample-app-*.yaml`

The scripts above prove the network path is open. For a stronger check — a real
instrumented application registering as an APM entity and reporting continuous
Transactions, Spans, and Metrics — deploy the sample Node.js app.

| Manifest | Use with | Where the pod runs | Endpoint it targets |
|---|---|---|---|
| [`sample-app-apm-nodejs-intra-cluster.yaml`](sample-app-apm-nodejs-intra-cluster.yaml) | Intra-cluster topology | Same cluster as the gateway, `newrelic` namespace | In-cluster proxy Service DNS |
| [`sample-app-apm-nodejs-out-of-cluster.yaml`](sample-app-apm-nodejs-out-of-cluster.yaml) | Out-of-cluster topology | Apps-cluster, `default` namespace | Private-zone hostname → internal ALB |

Each manifest deploys a tiny Express app plus a `newrelic` npm-agent that
continuously self-generates traffic. The app mounts `pcg-ca-bundle` so it
trusts the gateway's TLS cert without any Node-side truststore fiddling.

### Intra-cluster

```bash
kubectl -n newrelic create secret generic pcg-connectivity-nodejs-license \
  --from-literal=license-key="$NR_LICENSE_KEY"
kubectl apply -f sample-app-apm-nodejs-intra-cluster.yaml
```

If you deployed Kong instead of NGINX, swap the hostname before applying:

```bash
sed 's/pcg-nginx\./pcg-kong-kong-proxy./' sample-app-apm-nodejs-intra-cluster.yaml | kubectl apply -f -
```

### Out-of-cluster

```bash
export CTX_APPS=arn:aws:eks:<region>:<account-id>:cluster/apps-cluster
kubectl --context $CTX_APPS -n default create secret generic pcg-connectivity-nodejs-license \
  --from-literal=license-key="$NR_LICENSE_KEY"
kubectl --context $CTX_APPS apply -f sample-app-apm-nodejs-out-of-cluster.yaml
```

If your gateway hostname differs from the default:

```bash
sed 's|pcg.internal.newrelic|pcg.internal.example.com|' sample-app-apm-nodejs-out-of-cluster.yaml \
  | kubectl --context $CTX_APPS apply -f -
```

### Confirming the app registered

```bash
# Intra-cluster
kubectl -n newrelic logs -l app.kubernetes.io/name=pcg-connectivity-nodejs-apm

# Out-of-cluster
kubectl --context $CTX_APPS -n default logs \
  -l app.kubernetes.io/name=pcg-connectivity-nodejs-apm-out-of-cluster
```

Wait for `Agent state changed from connecting to connected`, then check
**APM & Services** in New Relic for the entity.

### Cleanup

```bash
# Intra-cluster
kubectl delete -f sample-app-apm-nodejs-intra-cluster.yaml
kubectl -n newrelic delete secret pcg-connectivity-nodejs-license

# Out-of-cluster
kubectl --context $CTX_APPS delete -f sample-app-apm-nodejs-out-of-cluster.yaml
kubectl --context $CTX_APPS -n default delete secret pcg-connectivity-nodejs-license
```

## Which one should I use?

- **Quick sanity check right after `terraform apply`** — `send-inventory-logs-*.sh`.
- **Proof that a real application registers as an entity and reports data** — `sample-app-*.yaml`.

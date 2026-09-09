# reverse-proxy-within-cluster/ — in-cluster reverse proxies

Both modules here run a reverse proxy pod **inside** the same cluster as the gateway. They terminate TLS on port 443 and forward plain HTTP to the gateway's Service ports (4318 OTLP HTTP, 4317 OTLP gRPC, 80 NR proprietary).

Neither provisions an external load balancer — that's `../alb/`, which is for the out-of-cluster pattern only.

## Pick ONE

| | `nginx/` | `kong/` |
|---|---|---|
| Config | Hand-written `nginx.conf` in a ConfigMap | Dynamic — generated from K8s `Ingress` resources |
| Complexity | Low (simple Deployment + Service) | Higher (Kong controller + CRDs + Helm chart) |
| gRPC | Supported | Supported natively |
| Plugins | No (plain NGINX) | Yes (Kong plugins for auth, rate limiting, etc.) |
| Default choice | ✅ Simpler | Use if your org standardizes on Kong |

The two are mutually exclusive — apply one, skip the other. Both route to the gateway the same way (identical paths, identical backend ports).

## How apps reach it

- `nginx/` → apps use `pcg-nginx.newrelic.svc.cluster.local`
- `kong/` → apps use `pcg-kong-kong-proxy.newrelic.svc.cluster.local`

Both hostnames are K8s Service DNS names, resolvable automatically by the cluster's built-in DNS (CoreDNS). No external DNS setup needed.

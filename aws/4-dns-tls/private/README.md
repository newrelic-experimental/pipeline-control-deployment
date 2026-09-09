# private/ — out-of-cluster (private DNS + private CA)

Private DNS + private CA for out-of-cluster gateway deployment. Everything internal — no public DNS, no public trust.

**⚠️ Cost warning:** `4.2-out-of-cluster-tls/` creates an AWS Private CA, which bills a **flat monthly rate whether idle or busy** ([pricing](https://aws.amazon.com/private-ca/pricing/)). Destroy when not actively testing.

## Two submodules — apply in order

### `4.1-route53-private-zone/`
- Creates a Route53 **private** hosted zone (default name `internal.newrelic`)
- Associates the zone with the shared VPC where both clusters live
- Zone is empty at creation — the A-record for `pcg.<zone>` gets added later by `5-pcg/flux/` or `5-pcg/fluxless/`

### `4.2-out-of-cluster-tls/`
- Creates AWS ACM Private CA (or accepts `private_ca_arn` for BYO)
- Issues server cert for the gateway hostname
- Uses two `kubernetes` provider aliases to write **two Secrets**:
  - `pcg-tls-secret` (cert + key) → pcg-cluster's `newrelic` namespace
  - `pcg-ca-bundle` (CA cert only) → apps-cluster's `default` namespace
- Also imports the server cert into ACM (via `aws_acm_certificate`) because AWS ALB requires cert-by-ARN

## Apply order

```bash
cd 4.1-route53-private-zone && terraform init && terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars
cd ../4.2-out-of-cluster-tls && terraform init && terraform apply -var-file=../../../out-of-cluster-private-dns-pcg.tfvars
```

## Verify

The critical test that both halves of the trust story work:

```bash
export CTX_PCG=arn:aws:eks:eu-west-1:<account>:cluster/pcg-cluster
export CTX_APPS=arn:aws:eks:eu-west-1:<account>:cluster/apps-cluster

kubectl --context $CTX_PCG  get secret pcg-tls-secret -n newrelic -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/server.crt
kubectl --context $CTX_APPS get secret pcg-ca-bundle  -n default  -o jsonpath='{.data.ca\.crt}'  | base64 -d > /tmp/ca.crt
openssl verify -CAfile /tmp/ca.crt /tmp/server.crt
# Should print: /tmp/server.crt: OK
```

## Future work

These two submodules will be merged into a single `private/` module (no submodules) after end-to-end validation of the restructured layout. Kept split for now to preserve the tested state. Tracked as a deferred task.

## BYO

- **Existing private zone:** skip `4.1-route53-private-zone/`. Set `route53_zone_id` in [`5-pcg/flux`](../../5-pcg/flux/) or [`5-pcg/fluxless`](../../5-pcg/fluxless/) tfvars.
- **Existing Private CA:** apply `4.2-out-of-cluster-tls/` with `private_ca_arn = "arn:..."` — module skips CA creation, reuses yours.

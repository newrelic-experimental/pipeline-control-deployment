# TLS Options

How to choose between the TLS paths this repo supports. Start with the decision tree; the options below it are reference detail.

## Decision tree

The deciding question is **where the workloads sending telemetry run**, relative to the gateway's cluster. Owning a public domain only matters once those senders can't reach the gateway over private networking.

```
Does EVERYTHING sending telemetry run in the same cluster as the gateway?
│
├─ Yes ──► Use cert-manager with a self-signed in-cluster CA.
│          Free, no public exposure, no DNS to manage.
│          Option 1 · aws/4-dns-tls/cert-manager/{4.1-installer,4.3-pcg-certificate}
│
└─ No ───► Can every sender reach the gateway over private networking?
           (same VPC, a peered VPC with DNS resolution, or on-prem
            over Direct Connect / VPN)
           │
           ├─ Yes ──► Use an ACM Private CA + a Route53 private zone.
           │          Still no public exposure. Note the Private CA's
           │          flat monthly charge.
           │          Option 2 · aws/4-dns-tls/private/{4.1-route53-private-zone,4.2-out-of-cluster-tls}
           │
           └─ No ───► Senders are on the public internet (another cloud,
                      a SaaS backend, an unpeered network).
                      Not supported by this reference architecture —
                      bring your own PKI. See Option 3 below.
```

Bringing your own certificate or issuer (**Option 3**) overrides either of the two.

> **Why cert-manager isn't an option once senders leave the cluster:** its CA is distributed as a Kubernetes Secret, and that distribution is in-cluster only. A sender in a different cluster, on EC2, or on-prem has no way to obtain the CA, so it cannot verify the gateway's certificate.

## Option 1 — cert-manager + self-signed internal CA (intra-cluster default)

**Modules:** [`aws/4-dns-tls/cert-manager/4.1-installer`](../aws/4-dns-tls/cert-manager/4.1-installer/) + [`aws/4-dns-tls/cert-manager/4.3-pcg-certificate`](../aws/4-dns-tls/cert-manager/4.3-pcg-certificate/)

**How it works:**
- cert-manager runs in the cluster, generates a self-signed root CA (`internal-ca-issuer` ClusterIssuer)
- Issues a TLS cert for the gateway's Kubernetes Service DNS names, SANs cover `pcg-nginx.newrelic.svc.cluster.local` etc.
- Auto-renews 30 days before expiry
- CA cert distributed as a Secret (`pcg-ca-bundle`) that apps in the same cluster mount

**Pros:**
- Free (no AWS charges beyond EKS itself)
- Zero external dependencies — works air-gapped
- Auto-renewal built in
- No public exposure

**Cons:**
- Only works for workloads in the **same cluster** as the gateway — the CA is distributed as a Kubernetes Secret, so nothing outside the cluster can obtain it
- Not trusted by anything outside your cluster
- Apps must mount the CA bundle and be told to trust it, which is per-language configuration (see the pattern guides for the mount; the per-language variable names are not collected in this repo yet)

**Use when:** everything sending telemetry runs in the same cluster as the gateway. This is the default path in the reference architecture.

## Option 2 — ACM Private CA + Route53 private zone (out-of-cluster)

**Modules:** [`aws/4-dns-tls/private/4.1-route53-private-zone`](../aws/4-dns-tls/private/4.1-route53-private-zone/) + [`aws/4-dns-tls/private/4.2-out-of-cluster-tls`](../aws/4-dns-tls/private/4.2-out-of-cluster-tls/)

**How it works:**
- AWS ACM Private CA issues a server cert for `pcg.internal.newrelic` (or whatever hostname you choose)
- Cert imported into ACM (for ALB) AND written as a K8s Secret (`pcg-tls-secret` in pcg-cluster) — ALB needs cert-by-ARN, K8s Secret is for reference
- Route53 **private** hosted zone, associated with the VPC the gateway runs in — resolvable only from networks attached to that zone
- CA root cert distributed to the sending cluster as a K8s Secret (`pcg-ca-bundle`), which pods mount to trust the gateway's cert
- Senders that aren't Kubernetes pods (EC2, ECS, on-prem) need the same CA root delivered by whatever mechanism suits them — the module writes it into a second EKS cluster, but the trust requirement is the same either way

**Pros:**
- No public DNS or public exposure
- Cert trusted by senders outside the gateway's cluster
- Real AWS-issued CA — professional PKI story

**Cons:**
- **AWS Private CA bills a flat monthly rate** whether idle or busy, plus a per-certificate issuance fee ([pricing](https://aws.amazon.com/private-ca/pricing/))
- More moving parts than cert-manager (CA activation dance, out-of-cluster Secret distribution)
- Requires private network reachability between senders and the gateway — the same VPC, a peered VPC with DNS resolution enabled, or on-prem over Direct Connect / VPN

**Use when:** senders live outside the gateway's cluster but can still reach it privately, and you want no public exposure. Validated end to end in both Flux and Fluxless modes.

**Cost-saving BYO:** If your org already runs an ACM Private CA, set `private_ca_arn = "..."` on the [`4.2-out-of-cluster-tls`](../aws/4-dns-tls/private/4.2-out-of-cluster-tls/) module and you pay only the per-certificate issuance fee.

## Option 3 — BYO cert / BYO Issuer

Either of the TLS paths above can be replaced with your own PKI. This is also the answer if you need a publicly-trusted certificate (public ACM + public Route53) — that path is not supported natively; bring your own.

See each module's BYO section for the exact tfvars:

- **cert-manager BYO:** [`aws/4-dns-tls/cert-manager/4.1-installer/README.md`](../aws/4-dns-tls/cert-manager/4.1-installer/README.md) — point [`4.3-pcg-certificate`](../aws/4-dns-tls/cert-manager/4.3-pcg-certificate/) at your existing `ClusterIssuer`
- **Private CA BYO:** [`aws/4-dns-tls/private/4.2-out-of-cluster-tls/README.md`](../aws/4-dns-tls/private/4.2-out-of-cluster-tls/README.md) — set `private_ca_arn` to your existing ACM Private CA
- **Full BYO (bring pre-made Secrets):** create the required K8s Secrets manually and skip the whole `4-dns-tls/` tree; point downstream `3-ingress/*` and `5-pcg/*` at your Secret names via tfvars

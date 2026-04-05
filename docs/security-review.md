# Security Review

## Threat Model

The order book service accepts untrusted HTTP from external clients, matches orders in memory, and persists events to Redis. It runs on Kubernetes behind Istio.

![Threat model: client through trust boundary to Istio, orderbook pod, Redis, with observability](images/threat-model.svg)

**Trust boundaries:**
1. Istio gateway → orderbook pod (external traffic enters the mesh)
2. orderbook pod → Redis (application talks to its data store)

**Assets worth protecting:**
- Open orders (bids/asks) — manipulation affects market pricing
- Trade history — regulatory audit trail
- Order book snapshots — reveals market depth to competitors
- Redis credentials — grants access to journal and cache
- Container images — tampered image = full compromise

**Who might attack this:**
- External attacker — manipulate orders, exfiltrate book data, deny service
- Compromised CI runner — supply chain attack, deploy malicious image
- Insider — modify orders, exfiltrate data, misconfigure infra
- Adjacent pod — lateral movement to orderbook or Redis

### STRIDE

- **Spoofing:** No identity on API requests. NetworkPolicy restricts to Istio gateway but there's no authentication (Risk 1).
- **Tampering:** Malicious image pushed to registry. CI has Cosign/SBOM/Trivy but signing isn't enforced (Risk 4).
- **Repudiation:** Redis journal is mutable. Anyone with Redis access can edit entries after trades.
- **Info Disclosure:** Full order book readable via unauthenticated GET. Rate limiting helps but no auth.
- **DoS:** Flood orders to exhaust memory. Per-pod rate limit bypassed with N replicas (Risk 5).
- **Elevation:** Container escape to host. Strong posture — nonroot, ro-fs, drop ALL caps, seccomp.

---

## Five Risks

### 1. No Authentication (Critical)

Every endpoint is open. Anyone with network access can place orders, cancel orders, read the full book. In a real exchange this enables spoofing/layering — place fake orders to move the visible book, cancel before execution, no identity recorded.

The NetworkPolicy helps (only Istio gateway traffic reaches the pod), and UUIDs for order IDs aren't guessable, but these are speed bumps, not access control.

The fix is Istio-native: `RequestAuthentication` + `AuthorizationPolicy` at the gateway. No application code changes needed.

### 2. In-Memory State, No WAL (High)

All order state lives in memory. Pod dies, orders are gone. The Redis journal exists but writes are synchronous with no acknowledgment guarantees — if Redis is down the write silently fails and the order still succeeds in memory. Recovery is disabled in multi-replica mode to avoid duplicate orders.

An attacker who can trigger OOMKill effectively wipes the order book. More realistically, a node failure during trading hours loses all open orders.

Production fix: Redis Streams with acknowledgment before responding to the client. For multi-replica, leader election via Kubernetes lease with followers replaying the stream.

### 3. Secrets Management (High)

Two problems. `docker-compose.yml` has `REDIS_PASSWORD=compose-local-dev-only` in plaintext — it's labeled as dev-only but it's in version control. Kubernetes secrets are created manually with no rotation or audit trail.

The Kubernetes side is the more serious concern. Anyone with `kubectl get secret` in the trading namespace can decode the Redis password. External Secrets Operator pulling from AWS Secrets Manager would fix both the lifecycle and the access control problem.

### 4. Unsigned Container Images (Medium)

The CI pipeline has Cosign signing and SBOM generation built in, but signing is optional (the `cosign-key` input isn't configured) and there's no admission controller rejecting unsigned images. The capability exists but isn't enforced — which in practice means it doesn't exist.

The deploy pipeline pins by digest (not tag), which prevents tag mutation attacks, and Trivy catches known CVEs. But there's no cryptographic proof that the running image is what CI built.

Lowest-effort fix of all five risks: configure the Cosign key pair in GitHub Secrets and deploy Sigstore policy-controller.

### 5. Per-Pod Rate Limiter (Medium)

The rate limiter uses an in-memory map keyed on `RemoteAddr`. Two problems: with 3 replicas, an attacker gets 3x the intended rate. And behind Istio, `RemoteAddr` is the sidecar IP, not the client — so either all traffic shares one bucket or the limit doesn't apply at all depending on the network path.

The per-pod limiter still has value as defense in depth, but the primary rate limit should be at the Istio gateway using EnvoyFilter + a Redis-backed rate limit service.

---

## What's Already Solid

- **Distroless image.** No shell, no package manager. Nothing to work with if you get code execution.
- **Read-only filesystem + drop ALL capabilities + seccomp RuntimeDefault.** The full hardening stack.
- **NetworkPolicy deny-all with explicit allowlist.** Istio on 8080, Prometheus on 9090, Redis on 6379, DNS on 53.
- **Graceful degradation.** Redis goes down, the service keeps matching orders.
- **Input validation.** Rejects negative prices, zero quantities, invalid sides before they reach the engine.
- **CI security gates.** tfsec + checkov on Terraform, gosec + govulncheck + Trivy on application, SBOM + SLSA provenance on images, AWS OIDC for credentials.

## Compliance Gaps

- **Audit trail:** Redis journal captures events but isn't tamper-proof. Production needs append-only log with separate permissions.
- **Data retention:** Journal capped at 10k entries. Financial regs typically require 5-7 years.
- **Encryption in transit:** Istio mTLS + ElastiCache encryption covers production, but local dev runs without TLS.
- **Vulnerability management:** Static scanning covered (Trivy, gosec, govulncheck, tfsec, checkov). No runtime scanning (Falco).

## What I'd Harden First

In order of effort-to-impact:

1. **Enforce image signing** (Risk 4). Configure Cosign key, deploy admission controller. Closes the supply chain gap without touching application code.
2. **Add API authentication** (Risk 1). Istio `RequestAuthentication` + `AuthorizationPolicy`. No app changes.
3. **Automate secrets** (Risk 3). External Secrets Operator from AWS Secrets Manager.
4. **Distributed rate limiting** (Risk 5). Istio EnvoyFilter + Redis rate limit service.
5. **WAL** (Risk 2). Redis Streams with ack before response. Largest change.
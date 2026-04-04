# Security Self-Review

A critical review of this submission's security posture: threat model, five most significant risks, compliance considerations, and a prioritized hardening roadmap.

---

## Threat Model

### System Context

The order book service accepts untrusted HTTP requests from external clients, matches buy and sell orders in memory, and persists events to Redis. It runs as a containerized workload on Kubernetes behind an Istio service mesh.

![Threat model: client through trust boundary to Istio, orderbook pod, Redis, with observability and CI runner](images/threat-model.svg)

**Trust boundaries:**
1. Istio gateway → orderbook pod (external traffic enters the mesh)
2. orderbook pod → Redis (application talks to its data store)
3. CI runner → EKS cluster (deployment pipeline pushes changes)

### Assets

| Asset | Sensitivity | Location |
|-------|------------|----------|
| Open orders (bids/asks) | High — manipulation affects market pricing | In-memory (`engine.books`) |
| Trade history | High — regulatory audit trail | In-memory + Redis journal |
| Order book snapshots | Medium — reveals market depth to competitors | Redis cache (100ms TTL) |
| Redis credentials | High — grants access to journal and cache | K8s Secret / docker-compose env |
| Container images | High — tampered image = full compromise | GHCR registry |
| EKS kubeconfig | Critical — cluster admin access | CI pipeline (OIDC, ephemeral) |

### Threat Actors

| Actor | Capability | Goal |
|-------|-----------|------|
| External attacker | Network access to the API endpoint | Manipulate orders, exfiltrate book data, deny service |
| Compromised CI runner | Push images, access deploy secrets | Supply chain attack — deploy malicious image |
| Insider (malicious or careless) | kubectl access, Git push | Modify orders, exfiltrate data, misconfigure infra |
| Adjacent pod (compromised neighbor) | Same-cluster network access | Lateral movement to orderbook or Redis |

### STRIDE Analysis

| Threat | Vector | Current Mitigation | Gap |
|--------|--------|-------------------|-----|
| **Spoofing** | Unauthenticated API — anyone can impersonate any trader | NetworkPolicy limits ingress to Istio gateway only | No identity verification (Risk 1) |
| **Tampering** | Push malicious container image to registry | CI builds with Cosign signing support, SBOM generation | Signing not enforced, no admission controller (Risk 4) |
| **Repudiation** | Modify or delete Redis journal entries after trades | Journal uses `LPUSH` + `LTRIM` (append pattern) | Journal is mutable by anyone with Redis access — not tamper-proof |
| **Information Disclosure** | Read full order book depth via `GET /orderbook/{pair}` | Rate limiting (1000 RPS per IP) | No authentication — any client can read market depth |
| **Denial of Service** | Flood orders to exhaust memory or CPU | Per-IP rate limit, HPA auto-scaling, PDB | Rate limit is per-pod, bypassed by N replicas (Risk 5) |
| **Elevation of Privilege** | Container escape → host access | Nonroot, read-only FS, drop ALL caps, seccomp RuntimeDefault | Strong posture — next step: AppArmor + PodSecurity admission |

---

## Five Most Significant Risks

### Risk 1: No Authentication or Authorization (Critical)

All API endpoints are unauthenticated. Any client with network access can place orders, cancel orders, and read the full order book.

**Attack scenario:** An attacker places thousands of fake orders at extreme prices to manipulate the visible book (spoofing/layering), then cancels them before execution. No identity is recorded, so attribution is impossible.

**Existing mitigations:**
- NetworkPolicy restricts API ingress to Istio gateway — no direct pod access from other namespaces.
- Per-IP rate limiting (1000 RPS) in middleware limits automated abuse volume.
- UUIDs for order IDs are not guessable, limiting cross-user cancellation.

**Hardening:**
1. Add Istio `RequestAuthentication` with JWT validation at the gateway.
2. Add `AuthorizationPolicy` restricting `DELETE /orders/{id}` to the token subject.
3. For a real exchange: integrate with an identity provider (Keycloak/Auth0) issuing short-lived tokens with trading permissions.

### Risk 2: In-Memory State with No Write-Ahead Log (High)

The matching engine holds all order state in memory. If the pod is killed (OOMKill, node failure, deploy), all open orders are lost.

Redis persistence exists but is best-effort: journal writes are fire-and-forget, and recovery is disabled in multi-replica mode to avoid duplicate orders.

**Attack scenario:** An attacker triggers OOMKill (e.g., placing orders with extremely long pair names if validation is insufficient) to erase the order book. More commonly, this is an availability risk rather than a security one.

**Hardening:**
1. Implement a WAL using Redis Streams — write event to stream and await acknowledgment before responding to client.
2. For multi-replica: leader election via Kubernetes lease, followers replay stream for hot standby.

### Risk 3: Secrets Management (High)

- `docker-compose.yml` contains `REDIS_PASSWORD=compose-local-dev-only` in plaintext, committed to version control.
- Kubernetes uses `secretKeyRef` (optional: true) but secrets are created manually — no rotation, no audit trail.
- CI uses `GITHUB_TOKEN` (scoped, fine) but the deploy role ARN is a long-lived secret reference.

**Attack scenario:** Repository compromise exposes the docker-compose Redis password. In K8s, anyone with `kubectl get secret` in the trading namespace can decode the Redis password.

**Hardening:**
1. Integrate External Secrets Operator to pull from AWS Secrets Manager.
2. Use OIDC for all CI/CD cloud access (already done for AWS).
3. Move docker-compose password to `.env` file (gitignored).

### Risk 4: Container Image Supply Chain Not Enforced (Medium)

CI supports Cosign signing and SBOM generation, but signing is optional (not configured in the workflow invocation) and no admission controller rejects unsigned images.

**Attack scenario:** Compromise the container registry or CI pipeline. Push a malicious image with a legitimate-looking tag. Pods pulling on restart get the malicious version.

**Existing mitigations:**
- Build outputs an immutable digest (`sha256:...`) — the deploy pipeline pins this, not a tag.
- Trivy scans for known CVEs before push.
- Distroless base image with no shell limits post-compromise capability.

**Hardening:**
1. Configure Cosign key pair in GitHub Secrets, enable signing in build action.
2. Deploy Sigstore policy-controller or Kyverno to reject unsigned images in the `trading` namespace.
3. Pin all base images by digest in the Dockerfile.

### Risk 5: Per-Pod Rate Limiter Not Distributed (Medium)

The rate limiter uses an in-memory map per pod. With 3 replicas, an attacker gets 3x the intended rate. Additionally, `RemoteAddr` in Kubernetes resolves to the Istio sidecar IP, not the client — so all traffic may share one bucket or bypass limiting entirely.

**Hardening:**
1. Set `X-Forwarded-For` in Istio and use it as the rate limit key.
2. Implement rate limiting at the Istio gateway level (EnvoyFilter + external rate limit service backed by Redis).
3. Keep per-pod limiter as defense in depth at a higher threshold.

---

## What Is Already Done Well

A security review that only lists problems gives a distorted picture. These are genuine strengths:

**Runtime hardening:**
1. **Distroless image** — no shell, no package manager. An attacker achieving code execution has no tools to escalate.
2. **Read-only root filesystem** — prevents writing scripts, modifying binaries, or persisting backdoors.
3. **Drop ALL capabilities** — no `ptrace`, `chown`, `net_raw`, or any other capability.
4. **Seccomp RuntimeDefault** — restricts syscalls to a safe baseline.

**Network isolation:**
5. **NetworkPolicy deny-all + allowlist** — only Istio on 8080, Prometheus on 9090, Redis on 6379, DNS on 53. Blocks lateral movement.
6. **Separate metrics port** — Prometheus scraping is isolated from user traffic via distinct NetworkPolicy rules.

**Application resilience:**
7. **Graceful degradation** — Redis unavailability does not cascade to service unavailability. Orders are still matched.
8. **Input validation** — handler rejects negative prices, zero quantities, invalid sides before they reach the engine.

**CI/CD security (shift-left):**
9. **Infrastructure security scanning** — tfsec and checkov run against Terraform HCL before plan/apply. Catches open security groups, public buckets, disabled encryption during code review, not after the infrastructure is live.
10. **Application SAST** — gosec scans Go source for security issues (SQL injection patterns, hardcoded credentials, weak crypto). govulncheck checks dependencies against the Go vulnerability database.
11. **Container scanning** — Trivy scans the built image for known CVEs before it is pushed to the registry.
12. **OIDC credentials** — CI/CD uses AWS OIDC federation. No long-lived access keys stored in GitHub Secrets.
13. **SBOM generation** — every image build produces an SPDX Software Bill of Materials attached as a registry attestation. This provides a full inventory of packages and dependencies for post-build vulnerability scanning and audit compliance.
14. **SLSA provenance** — build provenance attestation records source repo, commit SHA, and builder identity. Establishes a verifiable chain from source to deployed artifact.

---

## Compliance and Audit Considerations

| Concern | Current State | Gap |
|---------|--------------|-----|
| **Audit trail** | Redis journal captures order place/cancel events | Not tamper-proof — anyone with Redis access can modify entries. Use append-only log (Kafka) with separate read/write permissions. |
| **Data retention** | Journal capped at 10,000 entries, no expiration policy | Financial regulations typically require 5-7 years of trade records. |
| **Encryption in transit** | Istio mTLS (when configured), ElastiCache transit encryption | Local dev (docker-compose, KinD) runs without TLS. Acceptable for dev but should be documented for auditors. |
| **Encryption at rest** | EKS secrets via KMS, ElastiCache at-rest encryption | In-memory order book is never encrypted. Standard for in-memory systems but may need documentation. |
| **Access control** | NetworkPolicy + ServiceAccount without token automount | No RBAC on API endpoints. No multi-tenancy isolation. |
| **Vulnerability management** | Trivy (container CVEs), gosec (SAST), govulncheck (Go deps), tfsec (Terraform), checkov (CIS benchmarks) | No runtime scanning (e.g., Falco for container behavior anomalies). |

---

## 30-Day Hardening Roadmap

| Week | Action | Effort | Closes |
|------|--------|--------|--------|
| 1 | Enable Cosign signing in CI + deploy admission controller | 1-2 days | Risk 4 |
| 1 | Move docker-compose secrets to `.env`, add to `.gitignore` | 1 hour | Risk 3 |
| 2 | Add Istio `RequestAuthentication` + `AuthorizationPolicy` | 2-3 days | Risk 1 |
| 2 | Deploy External Secrets Operator, migrate Redis password | 1-2 days | Risk 3 |
| 3 | Implement distributed rate limiting at Istio gateway | 2-3 days | Risk 5 |
| 3 | Fix rate limiter to use `X-Forwarded-For` | 2 hours | Risk 5 |
| 4 | Implement WAL for order persistence | 3-5 days | Risk 2 |
| 4 | Deploy Falco for runtime anomaly detection | 1-2 days | Compliance |

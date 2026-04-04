# Security Self-Review

A critical review of this submission's security posture, identifying the most significant risks, realistic attack scenarios, and a prioritized hardening roadmap.

## Five Most Significant Risks

### Risk 1: No Authentication or Authorization on API Endpoints

**Severity: Critical**

All API endpoints (`POST /api/v1/orders`, `DELETE /api/v1/orders/{id}`, `GET /api/v1/orderbook/{pair}`, `GET /api/v1/trades/{pair}`) are unauthenticated. Any client that can reach the service can place orders, cancel orders, and read the full order book.

**What an attacker could exploit:**
- Place thousands of fake orders to manipulate the visible order book (spoofing/layering).
- Cancel other users' orders if they can guess or enumerate order IDs (UUIDs are not guessable, but the API returns order IDs in responses).
- Read the full order book depth to front-run legitimate orders.
- Flood the service with orders to exhaust the in-memory book and rate limiter budget.

**Mitigating factors already in place:**
- NetworkPolicy restricts API access to traffic arriving through the Istio gateway. Direct pod-to-pod access from other namespaces is blocked.
- Per-IP rate limiting (1000 RPS default) in middleware limits the blast radius of automated abuse.
- Istio can be configured with `RequestAuthentication` and `AuthorizationPolicy` without modifying application code.

**What I would harden first:**
1. Add Istio `RequestAuthentication` with JWT validation at the gateway. The application itself does not need to parse tokens; Istio's sidecar handles this before the request reaches the pod.
2. Add `AuthorizationPolicy` to restrict `DELETE /api/v1/orders/{id}` to the token's subject, preventing cross-user cancellation.
3. For a real exchange, integrate with an identity provider (Keycloak, Auth0) that issues short-lived tokens with claims for trading permissions.

### Risk 2: In-Memory Order Book with No Write-Ahead Log

**Severity: High**

The matching engine stores all order state in memory (`engine.go`, `books map[string]*book`). If the pod is killed (OOMKill, node failure, deploy rollback), all open orders and the current book state are lost.

The Redis persistence layer (`persistence/redis.go`) writes a journal and order snapshots, but:
- `ORDERBOOK_REDIS_RECOVER` is set to `false` in the production ConfigMap (correctly, because with 3 replicas, recovery would create duplicate orders across pods).
- The journal write is fire-and-forget: if Redis is unavailable, the order is still processed but not persisted. There is no guarantee that the journal is complete.
- There is no write-ahead log (WAL) pattern where persistence is confirmed before the client receives a response.

**What an attacker could exploit:**
- This is less of an attack vector and more of a reliability gap. However, an attacker who can cause pod restarts (e.g., by triggering OOMKill through large orders) would erase the order book.

**What I would harden first:**
1. Implement a WAL using Redis Streams (or Kafka in a larger system). Write the order event to the stream and receive acknowledgment before processing the match and responding to the client.
2. For multi-replica deployments, designate a leader (via Kubernetes lease or etcd election) that processes matches, with followers replaying the stream for hot standby.

### Risk 3: Secrets Management

**Severity: High**

Several secrets are handled in ways that would not pass a security audit:

1. **docker-compose.yml** contains `REDIS_PASSWORD=compose-local-dev-only` in plaintext. While this is clearly labeled as development-only, the file is committed to version control. An auditor would flag this regardless of intent.

2. **Kubernetes deployment** references `redis-credentials` Secret via `secretKeyRef` (optional: true), but there is no automated mechanism to create or rotate this secret. In practice, it is created manually (`kubectl create secret`), which means:
   - No audit trail of who created or last modified the secret.
   - No automatic rotation.
   - The secret value is stored in etcd (encrypted at rest if KMS is configured, but accessible to anyone with RBAC read access to secrets in the `trading` namespace).

3. **CI pipeline** uses `GITHUB_TOKEN` for container registry authentication. This is a scoped token (fine), but the commented-out deploy job references `ACR_PASSWORD` as a GitHub secret, which is a long-lived credential rather than OIDC federation.

**What an attacker could exploit:**
- If the Git repository is compromised, the docker-compose Redis password is exposed. In a real exchange, this could grant access to the cache and persistence journal.
- If a developer has `kubectl get secret` permissions in the trading namespace, they can decode the Redis password.
- If the CI runner is compromised and long-lived cloud credentials are in GitHub Secrets, the attacker gets infrastructure access.

**What I would harden first:**
1. Integrate External Secrets Operator to pull secrets from AWS Secrets Manager. Kubernetes Secrets become a projection of the source of truth, not the source itself.
2. Use OIDC federation for CI/CD cloud access (GitHub Actions OIDC provider -> AWS IAM role). No long-lived credentials stored in GitHub.
3. Move the docker-compose password to a `.env` file excluded from version control (`.gitignore` already exists; add `.env` if not present).

### Risk 4: Container Image Supply Chain Not Enforced

**Severity: Medium**

The CI pipeline supports Cosign image signing and SBOM generation (`.github/workflows/actions/build/action.yml`), but:
- The `cosign-key` input is optional and not configured in the workflow invocation.
- There is no admission controller in the Kubernetes cluster to reject unsigned images.
- The `imagePullPolicy: IfNotPresent` in the deployment means a cached image could be served even if the registry image is later replaced.

**What an attacker could exploit:**
- Supply chain attack: compromise the container registry (or CI pipeline) and push a malicious image with a legitimate-looking tag.
- Tag mutation: push a new image to the `:latest` tag. Pods that restart will pull the new (malicious) image if the cache is invalidated.

**Mitigating factors:**
- The build action generates an image digest (`sha256:...`) which is immutable. The deploy job (commented out) references this digest, not a tag.
- The Dockerfile uses a specific base image (`gcr.io/distroless/static-debian12:nonroot`), not `:latest`.
- Trivy container scanning in CI catches known CVEs before the image is pushed.

**What I would harden first:**
1. Configure Cosign key pair in GitHub Secrets and enable signing in the build workflow.
2. Deploy Sigstore policy-controller or Kyverno to reject any image in the `trading` namespace that lacks a valid Cosign signature.
3. Pin the deployment to image digests rather than tags (the CI already outputs the digest; wire it through to the Kustomize overlay).

### Risk 5: Per-Pod Rate Limiter Is Not Distributed

**Severity: Medium**

The rate limiter in `middleware.go` uses an in-memory `map[string]*rate.Limiter` per pod. With 3 replicas, an attacker sending requests to all pods gets 3x the intended rate limit (3000 RPS instead of 1000 RPS). The Istio load balancer distributes requests across pods, so an attacker does not need to target specific pods.

Additionally:
- The rate limiter keys on `r.RemoteAddr`, which in a Kubernetes environment is the Istio sidecar's IP (127.0.0.6 or the pod's IP), not the client's real IP. This means all traffic through Istio may share a single rate limit bucket, or conversely, the rate limit may not apply at all if `RemoteAddr` is the local sidecar.
- The cleanup goroutine (lines 112-123) runs indefinitely with no shutdown mechanism, though this is a minor leak since it is bounded to one goroutine per pod.

**What an attacker could exploit:**
- DDoS the service at 3x the intended rate, exhausting CPU and memory. The HPA would scale up, but each new pod adds another rate limiter, creating a feedback loop where scaling makes the effective rate limit *higher*.
- If `RemoteAddr` resolves to the sidecar IP, a single malicious client could lock out all legitimate traffic (all traffic shares one bucket) or bypass rate limiting entirely (the sidecar IP gets its own high-burst bucket).

**What I would harden first:**
1. Configure Istio to set the `X-Forwarded-For` header and use it as the rate limit key instead of `RemoteAddr`.
2. Implement rate limiting at the Istio gateway level using EnvoyFilter + an external rate limit service (backed by Redis). This provides a single, consistent rate limit across all replicas.
3. Keep the per-pod rate limiter as defense in depth, but set it to a higher threshold (e.g., 5000 RPS) that acts as a circuit breaker rather than the primary rate limit.

## Compliance and Audit Considerations

In a real exchange environment, the following would require attention:

| Concern | Current State | Gap |
|---------|--------------|-----|
| **Audit trail** | Redis journal captures order events | Journal is not tamper-proof; anyone with Redis access can modify entries. Production: use append-only log (Kafka) with separate read/write permissions. |
| **Data retention** | Journal capped at 10,000 entries, no expiration on order keys | No defined retention policy. Financial regulations typically require 5-7 years of trade records. |
| **Encryption in transit** | Istio mTLS (when configured), Redis transit encryption enabled in production | Local development (docker-compose, KinD) runs without TLS. Acceptable for dev, but the gap should be documented. |
| **Encryption at rest** | EKS secrets encrypted via KMS, ElastiCache at-rest encryption | In-memory order book data is never encrypted. This is standard for in-memory systems, but may need documentation for auditors. |
| **Access control** | NetworkPolicy + ServiceAccount without token automount | No RBAC for API endpoints (Risk 1). No multi-tenancy isolation. |
| **Vulnerability management** | Trivy, gosec, govulncheck in CI | No runtime vulnerability scanning (e.g., Falco for container behavior anomalies). |

## Threat Model Summary (STRIDE)

| Threat | Applicability | Mitigation |
|--------|--------------|------------|
| **Spoofing** | No identity verification on API | Risk 1: Add JWT/mTLS authentication |
| **Tampering** | Unsigned container images | Risk 4: Enforce Cosign signatures |
| **Repudiation** | Redis journal exists but is mutable | Append-only audit log with separate permissions |
| **Information Disclosure** | Metrics endpoint unauthenticated | NetworkPolicy restricts access to monitoring namespace only. Acceptable risk for internal metrics. |
| **Denial of Service** | Per-pod rate limit, HPA, PDB | Risk 5: Distributed rate limiting. Also: input validation prevents unbounded payloads (price/quantity must be positive). |
| **Elevation of Privilege** | Container runs nonroot, read-only FS, all capabilities dropped, seccomp RuntimeDefault | Strong posture. Next step: enable AppArmor profile and use PodSecurity admission (restricted). |

## What Is Already Done Well

This section exists because a security review that only lists problems gives a distorted picture. The following are genuine security strengths of this implementation:

1. **Distroless base image** with no shell and no package manager. An attacker who achieves code execution inside the container has no tools to escalate with.
2. **Read-only root filesystem** prevents an attacker from writing scripts, modifying binaries, or persisting a backdoor.
3. **Capabilities drop ALL** with no re-addition. The container cannot use `ptrace`, `chown`, `net_raw`, or any other capability.
4. **NetworkPolicy deny-all default** with explicit allowlist. An attacker who compromises the pod cannot reach arbitrary services in the cluster.
5. **Separate metrics port** (9090) from application port (8080) with distinct NetworkPolicy rules. Prometheus scraping is isolated from user traffic.
6. **Graceful degradation** when Redis is unavailable. The service continues to accept and match orders, just without persistence. This prevents a Redis outage from cascading to a full service outage.
7. **Input validation** at the handler level rejects negative prices, zero quantities, and invalid sides before they reach the matching engine.

## 30-Day Hardening Roadmap

| Priority | Action | Effort | Impact |
|----------|--------|--------|--------|
| Week 1 | Enable Cosign signing in CI + deploy policy-controller | 1-2 days | Closes supply chain gap (Risk 4) |
| Week 1 | Move docker-compose secrets to `.env`, add to `.gitignore` | 1 hour | Removes plaintext secret from VCS (Risk 3) |
| Week 2 | Add Istio `RequestAuthentication` + `AuthorizationPolicy` | 2-3 days | Closes authentication gap (Risk 1) |
| Week 2 | Deploy External Secrets Operator, migrate Redis password | 1-2 days | Automates secret lifecycle (Risk 3) |
| Week 3 | Implement distributed rate limiting at Istio gateway | 2-3 days | Fixes per-pod bypass (Risk 5) |
| Week 3 | Fix rate limiter to use `X-Forwarded-For` | 2 hours | Correct client identification (Risk 5) |
| Week 4 | Implement WAL for order persistence | 3-5 days | Closes durability gap (Risk 2) |
| Week 4 | Deploy Falco for runtime anomaly detection | 1-2 days | Adds runtime security layer |

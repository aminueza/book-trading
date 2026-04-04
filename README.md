# Order Book Trading Service

A low-latency limit order book with price-time priority matching, built in Go. Designed for operational maturity: containerized on distroless, orchestrated on Kubernetes with zero-downtime deploys, provisioned via Terraform, observed through Prometheus/Grafana/OpenTelemetry, and deployed through a CI/CD pipeline with automated health verification and rollback.

---

## Assumptions

- **In-memory matching engine** — no write-ahead log. Production would add a WAL backed by Redis Streams or Kafka before acknowledging the client. This tradeoff is documented in [Security Review, Risk 2](docs/security-review.md).
- **Single-region scope** — Kubernetes and Terraform target one AWS region (us-east-1). Multi-region is discussed in [Hybrid Migration](docs/hybrid-migration.md).
- **Redis as cache + journal, not primary store** — Redis provides snapshot caching (100ms TTL) and a best-effort event journal. The in-memory engine is the source of truth.
- **No authentication on API** — endpoints are open. Production would use Istio `RequestAuthentication` + `AuthorizationPolicy` with JWT. Documented as [Security Review, Risk 1](docs/security-review.md).
- **KinD for local, EKS for production** — the local environment runs a single-node KinD cluster. Production targets EKS with multi-AZ node groups.

## Architecture

![Architecture: Istio Gateway to 3 orderbook pods to Redis, with Prometheus, Tempo, and Grafana observability](docs/images/architecture-diagram.svg)

### Components

| Component | File | Purpose |
|-----------|------|---------|
| Matching engine | `application/internal/orderbook/engine.go` | Price-time priority matching with partial fills, thread-safe per pair |
| HTTP handlers | `application/internal/handler/handler.go` | REST API: place order, cancel, book snapshot, recent trades |
| Middleware | `application/internal/middleware/middleware.go` | RequestID, structured logging, Prometheus metrics, rate limiting, panic recovery |
| Health checks | `application/internal/health/` | `/healthz` (liveness), `/readyz` (readiness with Redis check) |
| Persistence | `application/internal/persistence/redis.go` | Event journal + order snapshots for crash recovery |
| Tracing | `application/internal/telemetry/tracing.go` | OpenTelemetry with configurable OTLP exporter |

## Build and Run

**Prerequisites:** Docker, kind, kubectl, helm, opentofu/terraform. Run `make deps-info` for install links or `make install-deps` on macOS.

### KinD Cluster (Kubernetes)

```bash
make up        # Build image + provision KinD + Istio + Redis + monitoring + deploy
make validate  # Correctness tests + load test against NodePort
make down      # Tear down
```

- API: http://127.0.0.1:8001
- Grafana: http://127.0.0.1:3000 (admin/admin)
- Istio ingress: `make pf` then http://localhost:8080

### Docker Compose

```bash
docker compose up --build   # orderbook + Redis + Prometheus + Grafana + Tempo + OTEL
```

- API: http://localhost:8080
- Grafana: http://localhost:3000

## Deploy (Production)

Two independent pipelines: `ci-infrastructure.yml` (Terraform) and `ci-application.yml` (build + deploy). Infrastructure changes deploy first; application changes deploy second. Both require manual approval via GitHub Environments.

The application deploy pins the image by digest, applies via kustomize, waits for a zero-downtime rollout, then verifies health (`/readyz`, `/healthz`) and runs a smoke test (place + cancel a real order). If any check fails, the previous revision is automatically restored via `kubectl rollout undo`.

See **[CI/CD and Production Safety](docs/cicd.md)** for the full pipeline architecture, security gates, deployment safety model, rollback procedures, branching strategy, and secrets flow.

## Validate

```bash
make test           # Unit tests with race detector + coverage
make validate       # E2E: health, ordering, matching, cancellation, input validation, load test
make validate-istio # Same, via Istio ingress (requires make pf)
make loadtest       # 1000 concurrent POSTs via hey
```

## Key Design Decisions

### Container

| Decision | Why |
|----------|-----|
| Distroless base (`gcr.io/distroless/static-debian12:nonroot`) | No shell, no package manager — minimal CVE surface. Tradeoff: no exec debugging (use ephemeral containers). |
| Static binary (`CGO_ENABLED=0`, `-trimpath`, `-ldflags="-s -w"`) | No libc dependency, runs on any Linux, required for distroless. |
| Read-only filesystem + drop ALL capabilities | Prevents runtime tampering. Even with container escape, no tools to escalate. |

### Kubernetes

| Decision | Why |
|----------|-----|
| CPU request = limit (Guaranteed QoS) | Avoids CFS throttling in latency-sensitive workloads. Priority during node pressure. |
| `maxSurge=1, maxUnavailable=0` | Zero-downtime. Slower rollout but no dropped requests. |
| Topology spread + pod anti-affinity (preferred) | Zone and node failure resilience. "Preferred" so scheduling works in degraded clusters. |
| NetworkPolicy deny-all + explicit allowlist | Zero-trust: only Istio on 8080, Prometheus on 9090, Redis on 6379, DNS on 53. |
| HPA scale-down stabilization 300s | Prevents flapping on bursty trading traffic. Scale-up is fast (30s). |

### Infrastructure as Code

| Decision | Why |
|----------|-----|
| Module composition (vpc/eks/redis/monitoring) | Independent review, selective apply during incidents, clear ownership for multi-team. |
| S3 + DynamoDB backend with encryption | Prevents concurrent applies. Versioned for state rollback. |
| `prevent_destroy` on VPC/subnets | Blocks accidental deletion of irreplaceable infrastructure. |
| Separate system/trading node groups | Isolates cluster components (CoreDNS) from trading workload pressure. |
| Static security scanning (tfsec + checkov) | Catches misconfigurations before `terraform apply` — shift-left for infrastructure. |

### What I Would Improve for Real Production

1. **Write-ahead log** — persist order events to a durable log before acknowledging the client.
2. **Distributed rate limiting** — Istio EnvoyFilter or Redis-backed, replacing per-pod in-memory limiter.
3. **Binary protocol** — gRPC or FIX instead of JSON/HTTP for lower serialization overhead.
4. **Skiplist/red-black tree** — replace sorted slices for O(log n) insertion instead of O(n log n).
5. **Canary deploys** — Istio VirtualService traffic splitting for progressive rollout.
6. **External Secrets Operator** — sync from AWS Secrets Manager instead of manual `kubectl create secret`.

## Project Structure

```
.
+-- application/
|   +-- cmd/orderbook/main.go             # Entrypoint, config, graceful shutdown
|   +-- internal/
|   |   +-- handler/                      # HTTP handlers
|   |   +-- orderbook/                    # Matching engine + tests + benchmarks
|   |   +-- persistence/                  # Redis journal + recovery
|   |   +-- health/                       # Liveness + readiness probes
|   |   +-- middleware/                   # RequestID, logging, metrics, rate limit, recovery
|   |   +-- telemetry/                    # OpenTelemetry tracing
|   +-- tests/                            # Integration tests (miniredis)
+-- infrastructure/
|   +-- deploy/kubernetes/
|   |   +-- base/                         # Deployment, Service, HPA, PDB, NetworkPolicy, Istio
|   |   +-- overlays/{local,production}/  # Environment-specific patches
|   |   +-- monitoring/local/             # Prometheus, Grafana, Redis exporter, dashboards
|   +-- terraform/
|   |   +-- environments/{local,production}/ # KinD (local), VPC+EKS+ElastiCache (prod)
|   |   +-- modules/{vpc,eks,redis,monitoring}/
|   +-- scripts/validate.sh              # E2E correctness + load validation
+-- .github/workflows/
|   +-- ci-application.yml               # Lint, test, security, build, rollout
|   +-- ci-infrastructure.yml            # Security scan, plan, apply
|   +-- actions/
|       +-- lint/                        # Go linting + SAST
|       +-- build/                       # Docker build + sign + SBOM
|       +-- security/                    # Container vulnerability scan
|       +-- infra-security/              # tfsec + checkov + conftest
|       +-- deploy/                      # Terraform plan/apply (AWS OIDC)
|       +-- rollout/                     # K8s safe deploy + health checks + rollback
+-- docs/
|   +-- cicd.md                          # CI/CD pipeline, deploy safety, rollback, secrets flow
|   +-- observability.md                 # SLOs, alerting, incident walkthrough
|   +-- hybrid-migration.md             # On-prem to cloud migration
|   +-- security-review.md              # Threat model, 5 risks, hardening roadmap
+-- Dockerfile                           # Multi-stage distroless build
+-- docker-compose.yml                   # Full local stack
+-- Makefile                             # One-command workflows
```

## Documentation

| Document | Section | What It Covers |
|----------|---------|---------------|
| [CI/CD and Production Safety](docs/cicd.md) | 4 | Pipeline architecture, security gates, deploy safety, rollback, branching model, secrets flow |
| [Observability](docs/observability.md) | 5 | SLO definitions, four golden signals, alerting philosophy, incident debugging walkthrough |
| [Hybrid Migration](docs/hybrid-migration.md) | 6 | Phased on-prem to cloud migration with shadow traffic and canary cutover |
| [Security Review](docs/security-review.md) | 7 | Threat model (STRIDE + actors + assets), five risks, compliance gaps, 30-day hardening roadmap |

# Order Book Trading Service

A production-grade limit order book service built in Go, designed for low-latency order matching with full observability, Kubernetes orchestration, and infrastructure-as-code provisioning.

## Assumptions

- **In-memory matching engine**: Order book state lives in memory for microsecond-level matching. A production system would add a write-ahead log (WAL) for durability; this is explicitly scoped out (see [Security Review](docs/security-review.md), Risk 2).
- **Single-region scope**: The Kubernetes and Terraform configurations target a single AWS region (us-east-1). Multi-region failover is discussed in the [Hybrid Migration](docs/hybrid-migration.md) design note.
- **Redis as cache + journal, not primary store**: Redis provides snapshot caching (100ms TTL) and a best-effort event journal for audit and recovery. It is not the source of truth for order state.
- **KinD for local development**: The local environment runs on a single-node KinD cluster. Production targets EKS with multi-AZ node groups.
- **Istio service mesh**: Traffic routing, mTLS (in production), and canary capabilities are provided by Istio. The local environment installs Istio for routing fidelity.
- **No authentication on API**: Endpoints are unauthenticated in this implementation. In production, Istio `RequestAuthentication` + `AuthorizationPolicy` would enforce JWT/mTLS. This is documented as Risk 1 in the security review.

## Architecture

```
                         +------------------+
                         |   Istio Gateway  |
                         +--------+---------+
                                  |
                    +-------------+-------------+
                    |             |             |
              +-----v----+ +-----v----+ +-----v----+
              | orderbook | | orderbook | | orderbook |
              |  pod (1)  | |  pod (2)  | |  pod (3)  |
              +-----+----+ +-----+----+ +-----+----+
                    |             |             |
                    +-------------+-------------+
                                  |
                          +-------v-------+
                          |    Redis      |
                          | (cache/journal)|
                          +---------------+

  Observability sidecar:
    Prometheus  <-- scrapes :9090/metrics (http_requests_total, http_request_duration_seconds, http_requests_in_flight)
    Tempo       <-- receives traces via OTEL Collector (order placement spans, Redis calls)
    Grafana     <-- dashboards for request rate, latency percentiles, error rate
```

**Key components:**

| Component | Purpose | File |
|-----------|---------|------|
| Matching engine | Price-time priority order matching with partial fills | `application/internal/orderbook/engine.go` |
| HTTP handlers | REST API for order placement, cancellation, book snapshots, trades | `application/internal/handler/handler.go` |
| Middleware stack | RequestID, structured logging, Prometheus metrics, rate limiting, panic recovery | `application/internal/middleware/middleware.go` |
| Health checks | Liveness (`/healthz`) and readiness (`/readyz` with Redis check) | `application/internal/health/` |
| Redis persistence | Event journal + order snapshots for recovery | `application/internal/persistence/redis.go` |
| Tracing | OpenTelemetry integration with configurable OTLP exporter | `application/internal/telemetry/tracing.go` |

## How to Build

**Prerequisites:** Docker, kind, kubectl, helm, opentofu (or terraform). Run `make deps-info` for install instructions, or `make install-deps` on macOS with Homebrew.

```bash
# Build the container image
make build
# Or directly:
docker build -t orderbook-service:latest .
```

The Dockerfile uses a multi-stage build: Go 1.24 builder with static compilation (`CGO_ENABLED=0`, `-trimpath`, `-ldflags="-s -w"`) into a `distroless/static-debian12:nonroot` runtime image. The final image has no shell, no package manager, and runs as UID 65534.

## How to Run

### Option 1: KinD Cluster (Kubernetes)

```bash
make up
```

This single command:
1. Builds the Docker image
2. Provisions a KinD cluster via Terraform
3. Installs Istio and Redis (Helm)
4. Deploys the orderbook service (3 replicas) via Kustomize
5. Deploys monitoring stack (Prometheus, Grafana, Redis exporter)

**Endpoints after `make up`:**
- API (NodePort): http://127.0.0.1:8001
- Grafana: http://127.0.0.1:3000 (admin/admin)
- Optional Istio ingress: `make pf` then http://localhost:8080

Tear down: `make down`

### Option 2: Docker Compose

```bash
docker compose up --build
```

Starts: orderbook + Redis + Prometheus + Grafana + Tempo + OTEL Collector.

**Endpoints:**
- API: http://localhost:8080
- Grafana: http://localhost:3000 (admin/admin)
- Prometheus: http://localhost:9091
- Metrics (direct): http://localhost:9090/metrics

## How to Deploy (Production)

The production Terraform configuration in `infrastructure/terraform/environments/production/` provisions:

- **VPC**: 10.0.0.0/16 with 3 AZs, private subnets for EKS, public subnets for NLB, NAT gateway per AZ
- **EKS**: Private API endpoint, KMS-encrypted secrets, separate system and trading node groups (c6i.xlarge compute-optimized), IRSA enabled
- **ElastiCache Redis**: r6g.large with automatic failover, encryption in transit + at rest, 7-day snapshot retention
- **Monitoring**: CloudWatch log groups (90-day retention), SNS for PagerDuty/Slack alerts

CI pipeline (`.github/workflows/ci-application.yml`):
1. **Lint**: gofmt, go vet, golangci-lint, gosec (SAST), govulncheck
2. **Test**: `go test -race ./...`
3. **Security scan**: Trivy container vulnerability scanning
4. **Build**: Docker BuildKit with layer caching, Cosign image signing, SBOM generation
5. **Deploy**: Terraform apply with image digest pinning (requires manual approval gate)

## How to Validate

```bash
# Run correctness + load tests against KinD NodePort
make validate

# Or against Istio ingress (requires make pf in another terminal)
make validate-istio

# Unit tests with race detector and coverage
make test

# Load test (requires hey: go install github.com/rakyll/hey@latest)
make loadtest
```

The validation script (`infrastructure/scripts/validate.sh`) tests:
- Health check endpoints (liveness + readiness)
- Order placement and response structure
- Order matching (buy meets sell)
- Price-time priority verification
- Order cancellation
- Input validation (missing fields, invalid values)
- Request ID propagation
- Prometheus metrics endpoint
- Concurrent load (configurable, default 8000 requests)
- Latency percentile calculations (p50/p95/p99/max)

## Key Design Decisions and Tradeoffs

### Container and Runtime

| Decision | Rationale |
|----------|-----------|
| Distroless base image | No shell, no package manager = minimal CVE surface. Tradeoff: no exec-into-pod debugging (use ephemeral containers). |
| Static Go binary (CGO_ENABLED=0) | Eliminates libc dependency; binary runs on any Linux. Required for distroless. |
| Nonroot user (UID 65534) | Defense in depth. Even if a container escape occurs, the process has no privileges. |
| Read-only filesystem | Prevents runtime file tampering. Application writes only to stdout/stderr. |

### Kubernetes and Availability

| Decision | Rationale |
|----------|-----------|
| CPU request = limit (Guaranteed QoS) | Avoids CFS throttling in latency-sensitive workloads. Pods get dedicated CPU and are last to be evicted under node pressure. |
| maxSurge=1, maxUnavailable=0 | Zero-downtime deploys. Slower rollout but no requests hit terminating pods. Critical for a trading service. |
| Topology spread + pod anti-affinity (preferred) | Spreads across zones and nodes for failure resilience. "Preferred" instead of "required" so scheduling works in a degraded cluster. |
| PDB minAvailable=2 | Tolerates 1 voluntary disruption (node drain, cluster upgrade) without losing quorum. |
| NetworkPolicy deny-all with explicit allowlist | Zero-trust: only Istio ingress on 8080, only Prometheus on 9090, only Redis on 6379, only DNS on 53. Blocks lateral movement. |
| HPA scale-down stabilization 300s | Prevents flapping on bursty trading traffic. Scale-up is faster (30s) to handle spikes. |

### Infrastructure as Code

| Decision | Rationale |
|----------|-----------|
| Module composition (vpc/eks/redis/monitoring) | Independent review, selective apply during incidents, clear ownership boundaries for multi-team. |
| S3 + DynamoDB backend | Prevents concurrent applies. State encrypted at rest, versioned for rollback. |
| Separate state per environment | Staging `terraform apply` cannot corrupt production state. |
| `prevent_destroy` on VPC/subnets | Blocks accidental deletion of irreplaceable infrastructure. A `terraform destroy` on VPC requires explicit lifecycle removal. |
| Separate system/trading node groups | Isolates cluster system components (CoreDNS, kube-proxy) from trading workload pressure. Taints on system nodes prevent scheduling app pods there. |

### What I Would Improve for Real Production Traffic

1. **Write-ahead log**: Persist every order event to a durable log (Kafka or Redis Streams) before acknowledging the client. Enables crash recovery and audit replay.
2. **Distributed rate limiting**: Current per-pod rate limiter is bypassed by N replicas. Use Istio EnvoyFilter or Redis-backed rate limiter.
3. **Binary protocol**: Replace JSON/HTTP with gRPC or FIX for lower serialization overhead and stricter contracts.
4. **Order book data structure**: Replace sorted slices with a skiplist or red-black tree for O(log n) insertion instead of O(n log n) re-sort.
5. **Canary deployments**: Implement Istio traffic splitting (VirtualService weight) for progressive rollout instead of rolling update.
6. **External Secrets Operator**: Replace manually-created Kubernetes Secrets with automatic sync from AWS Secrets Manager.

## Project Structure

```
.
+-- application/
|   +-- cmd/orderbook/main.go          # Entrypoint: config, servers, graceful shutdown
|   +-- internal/
|   |   +-- handler/                    # HTTP handlers (PlaceOrder, CancelOrder, GetOrderBook, GetRecentTrades)
|   |   +-- orderbook/                  # Matching engine (price-time priority, thread-safe)
|   |   +-- persistence/                # Redis store (event journal, order snapshots, recovery)
|   |   +-- health/                     # Liveness and readiness probes
|   |   +-- middleware/                 # RequestID, logging, metrics, rate limiting, recovery
|   |   +-- telemetry/                  # OpenTelemetry tracing initialization
|   +-- tests/                          # Integration tests (testapp helper with miniredis)
+-- infrastructure/
|   +-- deploy/kubernetes/
|   |   +-- base/                       # Production manifests (Deployment, Service, HPA, PDB, NetworkPolicy, Istio, ServiceMonitor)
|   |   +-- overlays/local/             # KinD overrides (1 replica, NodePort, local Redis)
|   |   +-- overlays/production/        # Production kustomization
|   |   +-- monitoring/local/           # Prometheus, Grafana, Redis exporter for KinD
|   +-- terraform/
|   |   +-- environments/local/         # KinD cluster + Istio + Redis + bootstrap
|   |   +-- environments/production/    # VPC + EKS + ElastiCache + monitoring modules
|   |   +-- modules/                    # vpc, eks, redis, monitoring
|   +-- docker/                         # Prometheus, Grafana, Tempo, OTEL Collector configs
|   +-- scripts/validate.sh             # Correctness + load validation script
+-- docs/
|   +-- observability.md                # SLOs, metrics, alerting, incident walkthrough
|   +-- hybrid-migration.md             # On-prem to cloud migration design note
|   +-- security-review.md              # Threat model, 5 risks, hardening priorities
+-- .github/workflows/                  # CI pipeline (lint, test, security, build)
+-- Dockerfile                          # Multi-stage distroless build
+-- docker-compose.yml                  # Full local stack
+-- Makefile                            # One-command workflows
```

## Documentation

| Document | Assessment Section | Description |
|----------|-------------------|-------------|
| [Observability and Reliability](docs/observability.md) | Section 5 | SLO definitions, metrics philosophy, alerting strategy, incident debugging walkthrough |
| [Hybrid Migration](docs/hybrid-migration.md) | Section 6 | Phased on-prem to cloud migration design note |
| [Security Self-Review](docs/security-review.md) | Section 7 | Five critical risks, threat model, hardening roadmap |

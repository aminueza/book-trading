# Hybrid Migration: On-Prem to Cloud

A phased approach to migrating the order book service from an on-premises data center to AWS while maintaining availability throughout.

---

## Constraints

| Constraint | Implication |
|-----------|-------------|
| Zero downtime | No maintenance window during trading hours. Every phase must be reversible. |
| Latency budget | App → Redis round trip must stay under 2ms. Cross-datacenter calls violate this. |
| Data consistency | Only one environment actively matches orders at a time. Dual-active = split-brain with duplicate fills. |
| Rollback at every stage | The previous environment stays running until the next phase is proven. |

---

## Phases

### Phase 0: Assessment (Week 1-2)

Establish what "normal" looks like before moving anything.

**Actions:**
- Instrument the on-prem service with the same Prometheus metrics and structured logging used in this repository. The application code is environment-agnostic.
- Measure baseline: p50/p95/p99 latency, throughput (orders/sec), error rate, Redis round-trip. These become acceptance criteria for every subsequent phase.
- Map dependencies: DNS, NTP, certificate authorities, monitoring endpoints. Each needs a cloud equivalent.
- Choose network path: site-to-site VPN (~5-20ms added) or Direct Connect (~1-2ms, weeks to provision).

**Exit criteria:** Baselines documented, network path provisioned.

### Phase 1: Cloud Foundation (Week 3-6)

Deploy infrastructure without routing any production traffic.

**Actions:**
- Apply `infrastructure/terraform/environments/production/main.tf` — provisions VPC, EKS, ElastiCache, monitoring.
- Deploy orderbook to EKS via production Kustomize overlay. Verify health checks pass.
- Deploy monitoring stack (Prometheus, Grafana, Tempo) in AWS. Both environments now have independent monitoring.
- Set up CI/CD to deploy to EKS (the pipeline already produces signed images).

**Exit criteria:** Cloud environment operational, health checks passing, monitoring live, no production traffic.

### Phase 2: Shadow Traffic (Week 7-8)

Validate against real traffic patterns without user impact.

**Actions:**
- Configure Istio traffic mirroring (`VirtualService.mirror`) to copy requests to AWS. Responses are discarded — users only see on-prem responses.
- Compare environments: latency percentiles, error rates, response correctness (logged, not returned).
- Fix cloud-specific issues: DNS resolution differences, clock skew (order timestamps use `time.Now().UTC()`), Redis pool tuning for higher-latency network.

**What to watch for:**
- Cloud latency significantly higher → investigate: AWS VPC routing, instance type (c6i.xlarge vs bare metal), ElastiCache network overhead.
- Mirrored requests cause errors → fix before proceeding. Common: missing env vars, DNS behavior differences.

**Exit criteria:** Cloud handles mirrored traffic at on-prem parity for latency and correctness.

### Phase 3: Canary Cutover (Week 9-10)

Gradually shift real production traffic.

**Actions:**
- Set DNS TTL to 60 seconds (temporary, enables fast rollback).
- Weighted DNS routing (Route 53) or Istio traffic splitting: 5% → 10% → 25% → 50% → 100%.
- At each stage: hold 24-48 hours, verify SLO compliance, error budget not accelerating, p99 within target.

**Critical rule:** The matching engine runs in only one environment at a time. The traffic split controls which environment processes orders, not both simultaneously.

- At 5% cloud: a small user cohort tests cloud reliability. The two environments have independent order books, so cross-matching does not occur. Acceptable because we are testing infrastructure, not liquidity.
- At 50%+: liquidity split becomes a problem. Commit to 100% (if green) or fall back to 0%. Do not hold at 50%.

**Rollback:** Set cloud traffic weight to 0%. DNS propagates within 60 seconds. On-prem continues serving.

**Exit criteria:** 100% traffic on cloud for 48 hours with SLO compliance.

### Phase 4: Decommission (Week 11-12)

- Keep on-prem in standby for 2 weeks after full cutover.
- Decommission on-prem instances. Keep VPN for 30 days as safety net.
- Raise DNS TTL back to production values (300s+).
- Update runbooks and incident response to reference cloud infrastructure.

---

## Key Risks

### Latency-Sensitive Systems

| Path | On-prem | Cloud target | If exceeded |
|------|---------|-------------|-------------|
| App → Redis | < 0.5ms (co-located) | < 2ms (same-AZ ElastiCache) | Place pods + ElastiCache in same AZ; read replicas for reads |
| Client → App | Varies | Should improve (AWS edge) | NLB or CloudFront for client traffic |
| Pod → Pod | < 0.2ms (same rack) | < 1ms (same AZ, Istio mTLS) | Disable mTLS for intra-namespace if unacceptable (tradeoff: less security) |

### Data Consistency

The order book is in-memory. There is no shared state between on-prem and cloud. Consistency is maintained by the constraint that only one environment matches at a time.

If active-active were required (geographic proximity for users in different regions), the architecture would need a consensus protocol (Raft) or CRDTs — a fundamentally different design, out of scope for this migration.

### Avoiding Two Control Planes

The risk with hybrid infrastructure is two loosely coordinated systems for deployment, monitoring, and access control.

| Concern | Mitigation |
|---------|-----------|
| Divergent deployment tooling | Single Terraform repo (`infrastructure/terraform/`). Both environments defined with shared modules. Same PR review process. |
| Separate CI/CD pipelines | Same GitHub Actions workflow. Deploy target controlled by branch/input, not separate pipelines. |
| Split monitoring | Both push to one Prometheus/Grafana stack (or Thanos for multi-cluster). Alerts defined once. On-call sees one pane. |
| Config drift in Kubernetes | Flux or ArgoCD reconciles Git state with both clusters. Drift detected automatically. |
| Separate secret stores | Both pull from AWS Secrets Manager (cloud) or Vault (hybrid). |

If any of these becomes impractical (e.g., on-prem cannot reach Secrets Manager), that signals to accelerate the migration rather than build parallel infrastructure.

---

## Timeline

| Week | Phase | Risk | Rollback |
|------|-------|------|----------|
| 1-2 | Assessment | None | N/A |
| 3-6 | Foundation | Low (no traffic) | Destroy cloud infra |
| 7-8 | Shadow traffic | Low (mirrored) | Disable mirror |
| 9-10 | Canary cutover | Medium (split traffic) | < 60s via DNS weight |
| 11-12 | Decommission | Low (cloud proven) | Restart on-prem standby |

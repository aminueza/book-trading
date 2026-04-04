# Hybrid Migration: On-Prem to Cloud

This document describes a phased approach to migrating the order book service from an on-premises data center to AWS, while maintaining availability throughout the transition.

## Starting Point and Constraints

The current on-prem deployment runs the order book service on bare-metal or VM infrastructure with a co-located Redis instance. The service is latency-sensitive: the matching engine operates in single-digit milliseconds, and introducing network hops between the application and its dependencies directly impacts p99 latency.

Key constraints:
- **Zero downtime**: The migration cannot involve a maintenance window long enough to impact trading hours.
- **Latency budget**: The application-to-Redis round trip must stay under 2ms. Cross-region or cross-data-center calls would violate this.
- **Data consistency**: Only one instance of the order book can actively match orders at a time. Running matching engines in both environments simultaneously would create split-brain conditions with duplicate fills.
- **Rollback at every stage**: Each phase must be reversible without data loss or extended downtime.

## Phase 0: Assessment and Baseline (Week 1-2)

Before moving anything, establish what "normal" looks like.

**Actions:**
- Instrument the on-prem service with the same Prometheus metrics and structured logging used in this repository (the application code is environment-agnostic; only the deployment configuration changes).
- Measure baseline latency (p50, p95, p99), throughput (orders/second), error rate, and Redis round-trip time. These become the acceptance criteria for every subsequent phase.
- Map all dependencies: DNS resolution paths, NTP sources, certificate authorities, monitoring endpoints. Each one needs a cloud equivalent or a cross-environment bridge.
- Identify the network path between the data center and AWS. Options: site-to-site VPN (encrypted over public internet, ~5-20ms added latency) or AWS Direct Connect (dedicated fiber, ~1-2ms added latency, weeks to provision).

**Exit criteria:** Baseline metrics documented, network path selected and provisioned.

## Phase 1: Cloud Foundation (Week 3-6)

Deploy the cloud infrastructure without routing any production traffic to it.

**Actions:**
- Apply the production Terraform configuration (`infrastructure/terraform/environments/production/main.tf`). This provisions the VPC, EKS cluster, ElastiCache Redis, and monitoring stack.
- Deploy the order book service to EKS using the production Kustomize overlay. Verify it starts, passes health checks, and can connect to ElastiCache Redis.
- Deploy the monitoring stack (Prometheus, Grafana, Tempo) in AWS. Configure it to scrape the cloud deployment. At this point, both environments have independent monitoring.
- Set up CI/CD to deploy to EKS (the build pipeline already produces signed container images; only the deploy target changes).
- If using Direct Connect, validate the cross-environment network path: measure round-trip latency between on-prem and AWS VPC. If this exceeds 10ms, some integration patterns (e.g., cross-environment Redis replication) become impractical.

**Exit criteria:** Cloud environment operational, health checks passing, monitoring live, no production traffic.

## Phase 2: Shadow Traffic (Week 7-8)

Validate the cloud deployment against real production traffic patterns without impacting users.

**Actions:**
- Configure Istio traffic mirroring on the on-prem deployment. The VirtualService `mirror` directive sends a copy of every request to the AWS endpoint. Mirrored responses are discarded; users only see on-prem responses.
- Compare metrics between environments: latency percentiles, error rates, response body correctness (logged, not returned to users). The cloud deployment should be within 10% of the on-prem baseline for p99 latency.
- Identify and fix cloud-specific issues: DNS resolution differences, clock skew (the order book uses `time.Now().UTC()` for trade timestamps; NTP drift between environments would cause ordering inconsistencies), Redis connection pool tuning for higher-latency network.

**What to watch for:**
- If cloud latency is significantly higher than on-prem, investigate: is it network (AWS VPC routing, security group evaluation), is it instance type (CPU model differences between c6i.xlarge and on-prem bare metal), or is it Redis (ElastiCache network overhead vs co-located Redis)?
- If mirrored requests cause errors in the cloud deployment, fix them before proceeding. Common issues: missing environment variables, different DNS resolution behavior, TLS certificate differences.

**Exit criteria:** Cloud environment handles mirrored traffic at on-prem parity for latency and correctness. No errors specific to the cloud environment.

## Phase 3: Canary Cutover (Week 9-10)

Gradually shift real production traffic from on-prem to cloud.

**Actions:**
- Set DNS TTL to 60 seconds on the service's external endpoint (this is temporary; low TTL enables fast rollback).
- Use weighted DNS routing (Route 53 weighted records) or Istio traffic splitting to send traffic in stages: 5% -> 10% -> 25% -> 50% -> 100%.
- At each stage, hold for 24-48 hours and verify: SLO budget consumption rate is not accelerating, p99 latency is within target, error rate is flat.

**Critical rule:** During the canary period, the order book matching engine runs in only one environment at a time. The traffic split controls which environment processes orders, not both simultaneously. This avoids split-brain matching.

How this works in practice:
- At 5% cloud traffic: 5% of users hit the cloud order book, 95% hit on-prem. The two environments have independent order books, so cross-environment matching does not occur. This is acceptable during the canary because the 5% cohort is testing cloud reliability, not order book liquidity.
- At 50%+: The liquidity split becomes a problem. At this point, either commit to 100% cloud (if all indicators are green) or fall back to 0%. Do not stay at 50% for extended periods.

**Rollback procedure:** At any stage, set the cloud traffic weight to 0%. DNS propagation completes within 60 seconds (the low TTL set earlier). On-prem continues serving all traffic. No data migration is needed because the on-prem order book never stopped running.

**Exit criteria:** 100% traffic on cloud for 48 hours with SLO compliance.

## Phase 4: Decommission On-Prem (Week 11-12)

- Keep on-prem running in standby for 2 weeks after full cutover (safety net).
- Remove on-prem service deployment. Keep the network connection (VPN/Direct Connect) for 30 days.
- Raise DNS TTL back to production values (300s+).
- Update runbooks, incident response procedures, and escalation paths to reference cloud infrastructure.
- Decommission on-prem infrastructure after the retention period.

## Risks and Mitigations

### Latency-Sensitive Systems

The matching engine tolerates up to ~50ms p99 end-to-end (SLO target). The critical sub-component is the Redis round trip for cache invalidation and journal writes.

| Path | On-prem baseline | Cloud target | Mitigation if exceeded |
|------|-----------------|--------------|----------------------|
| App -> Redis | < 0.5ms (co-located) | < 2ms (same-AZ ElastiCache) | Place pods and ElastiCache in the same AZ; use cluster mode with read replicas for reads |
| Client -> App | Depends on client location | Should improve (AWS edge) | Use CloudFront or NLB for client-facing traffic |
| App -> App (cross-pod) | < 0.2ms (same rack) | < 1ms (same AZ, Istio mTLS) | Disable mTLS for intra-namespace traffic if latency is unacceptable (tradeoff: less security) |

### Data Consistency Across Environments

The order book is an in-memory data structure. There is no shared state between on-prem and cloud deployments. Consistency is maintained by the constraint that only one environment actively matches orders at a time.

If active-active matching were required (e.g., for geographic proximity to users in different regions), this design would need a consensus protocol (Raft) or a conflict-free replicated data type (CRDT) for the order book. This is a fundamentally different architecture and is out of scope for this migration.

The Redis journal is environment-local. On-prem Redis and cloud ElastiCache do not replicate to each other. If recovery is needed after cutover, it uses the cloud ElastiCache journal exclusively.

### Avoiding Two Control Planes

The risk with hybrid infrastructure is ending up with two loosely coordinated sets of deployment tooling, monitoring, and access controls. This creates operational overhead, inconsistent configurations, and incident response confusion.

**Mitigation:**

1. **Single Terraform repository** (this repository). Both environments are defined in the same `infrastructure/terraform/` directory with shared modules. Changes to infrastructure go through the same PR review process regardless of target environment.

2. **Single CI/CD pipeline**. The same GitHub Actions workflow builds the image, runs security scans, and deploys. The deploy target is controlled by the branch or workflow input, not by separate pipelines.

3. **Unified monitoring**. Both environments push metrics to the same Prometheus/Grafana stack (or use Thanos/Cortex for multi-cluster federation). Alerts are defined once and apply to both. An on-call engineer sees a single pane of glass, not two separate dashboards.

4. **GitOps for Kubernetes**. Use Flux or ArgoCD to reconcile the desired state (in Git) with both clusters. Configuration drift between environments is detected automatically, not discovered during an incident.

5. **Centralized secrets management**. Both environments pull secrets from AWS Secrets Manager (cloud) or HashiCorp Vault (hybrid). No environment-specific secret stores.

If any of these become impractical (e.g., the on-prem environment cannot reach AWS Secrets Manager due to network policy), that is a signal to accelerate the migration timeline rather than build a parallel system.

## Timeline Summary

| Week | Phase | Risk Level | Rollback Time |
|------|-------|-----------|---------------|
| 1-2 | Assessment | None | N/A |
| 3-6 | Foundation | Low (no production traffic) | Destroy cloud infra |
| 7-8 | Shadow traffic | Low (mirrored, not real) | Disable mirror |
| 9-10 | Canary cutover | Medium (split traffic) | < 60s (DNS weight to 0%) |
| 11-12 | Decommission | Low (cloud proven) | Restart on-prem (standby) |

The total elapsed time is ~12 weeks. The actual engineering effort is concentrated in weeks 3-8 (infrastructure setup and shadow validation). The canary and decommission phases are primarily observation and validation with minimal engineering work.

# Hybrid Migration: On-Prem to Cloud

This describes how I'd move the order book service from on-prem to AWS without taking it down.

---

## Why This Is Hard

The matching engine needs sub-2ms round trips to Redis. That rules out running the app in one datacenter and Redis in another. And you can't run two matching engines simultaneously — orders would get filled twice, which in a trading context is catastrophic, not just a bug.

So the migration has to be sequential: build cloud, validate cloud, move traffic, tear down on-prem. No shortcuts.

## The Approach

**Start with baselines.** Before moving anything, instrument the on-prem deployment with the same Prometheus metrics already in this repo. Measure p99 latency, throughput, error rate, Redis round-trip. These numbers are the acceptance criteria for every phase — if cloud can't match them within 10%, we don't proceed. Also map every dependency: DNS, NTP, CAs, monitoring endpoints. Missing one of these has stalled migrations I've seen before.

Pick a network path early. Direct Connect takes weeks to provision but adds only 1-2ms. VPN is faster to set up but adds 5-20ms, which may be fine for the validation phase but not for production traffic.

**Build the cloud side, send it nothing.** Apply the production Terraform — VPC, EKS, ElastiCache, monitoring. Deploy the orderbook to EKS, verify health checks pass, verify it can reach ElastiCache. Deploy Prometheus and Grafana so both environments have independent monitoring. If anything goes wrong here, delete it and start over. This is the cheapest phase to fail.

**Shadow traffic.** Configure Istio traffic mirroring on the on-prem side. Every request gets copied to AWS, but the cloud responses are discarded — users only see on-prem. Compare latency, error rates, and response correctness between environments. This catches the things you don't expect: DNS resolves differently in the VPC, NTP drift means timestamps don't match, the Redis pool needs different tuning because ElastiCache has higher network latency than a co-located instance.

**Cutover.** Set DNS TTL to 60 seconds. Use Route 53 weighted records: 5% to cloud, hold a day or two, then 10%, 25%, 100%. At each step, check SLO compliance. The important thing: at low percentages, the two environments have independent order books. A buy order on cloud won't match against a sell on on-prem. That's acceptable at 5% because we're testing infrastructure, not liquidity. But at 50% the fragmentation becomes a real problem — so once past 25%, either commit to 100% or roll back to 0%. Don't sit at 50%.

Rollback at any point: set cloud weight to 0%, DNS propagates in 60 seconds, on-prem never stopped running.

**Decommission.** Keep on-prem in standby for two weeks. Then shut it down, keep the VPN for 30 days, update runbooks.

## Latency

| Path | On-prem | Cloud target | If exceeded |
|------|---------|-------------|-------------|
| App → Redis | < 0.5ms (co-located) | < 2ms (same-AZ ElastiCache) | Pin pods and ElastiCache to the same AZ |
| Client → App | Varies | Should improve (AWS edge) | NLB for client traffic |
| Pod → Pod | < 0.2ms (same rack) | < 1ms (same AZ, Istio mTLS) | Disable mTLS intra-namespace if unacceptable |

## Data Consistency

There's no shared state between environments. The order book is in-memory, Redis journals are environment-local. Consistency comes from the rule that only one environment matches at a time — not from replication.

If active-active were ever required (users in different continents needing local matching), the architecture would need Raft or CRDTs. That's a different system entirely.

## The Control Plane Problem

The real risk with hybrid isn't the migration itself — it's ending up with two of everything. Two deploy pipelines, two monitoring stacks, two secret stores, and an on-call engineer checking two dashboards at 3am. Every time I've seen this happen, the "temporary" second system becomes permanent because nobody has time to consolidate.

The fix is to refuse to build parallel systems from the start:

- **One Terraform repo.** Both environments defined in `infrastructure/terraform/` with shared modules. Same PR process.
- **One CI/CD pipeline.** Same GitHub Actions workflow, target environment is a parameter.
- **One monitoring stack.** Both environments push to the same Prometheus (or Thanos for federation). Alerts defined once.
- **One secret store.** AWS Secrets Manager or Vault. Not one per environment.
- **One GitOps controller.** Flux or ArgoCD reconciling both clusters from the same repo.

If any of these becomes impractical — say, the on-prem firewall blocks Secrets Manager — that's a signal to accelerate the migration, not to build a parallel secret store.

## Timeline

Roughly 10-12 weeks. Engineering effort concentrates in weeks 3-8 (infra setup and shadow validation). Cutover and decommission are mostly observation. The biggest schedule risk is Direct Connect provisioning — start it in week 1.

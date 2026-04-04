# Observability and Reliability

How the order book service is monitored, what constitutes healthy operation, and how to debug production incidents.

---

## Service Level Objectives

### SLO 1: Availability — 99.9% over 30 days

**SLI:** Proportion of non-5xx responses on `/api/v1/*` endpoints.

```promql
1 - (
  sum(rate(http_requests_total{path=~"/api/v1/.*", status=~"5.."}[30d]))
  /
  sum(rate(http_requests_total{path=~"/api/v1/.*"}[30d]))
)
```

**Why this SLI:** A 5xx on order placement means a trade was lost. Users experience this directly. Infrastructure metrics like node CPU or pod restart count do not capture whether users can actually trade.

**Budget:** ~43 minutes of downtime per month.

### SLO 2: Latency — p99 < 50ms for order placement

**SLI:** p99 latency of `POST /api/v1/orders`.

```promql
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{method="POST", path="/api/v1/orders"}[5m])) by (le)
)
```

**Why 50ms:** Matching is in-memory (microseconds). The 50ms budget covers network hops, JSON serialization, Redis cache invalidation, and middleware. Exceeding this means something in the request path is degraded.

### Error Budget Policy

| Budget consumed | Action |
|----------------|--------|
| < 25% | Normal operations. Deploy at will. |
| 25-50% | Increased monitoring. Review recent deploys. |
| 50-80% | Freeze non-critical deployments. Investigate top error contributors. |
| > 80% | Page on-call. Halt all changes. Focus on restoring budget. |

---

## Metrics

Three application metrics, defined in `application/internal/middleware/middleware.go`:

| Metric | Type | Labels | Maps to |
|--------|------|--------|---------|
| `http_requests_total` | Counter | method, path, status | Traffic + Errors |
| `http_request_duration_seconds` | Histogram | method, path | Latency |
| `http_requests_in_flight` | Gauge | — | Saturation |

**Histogram buckets:** `1ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s` — dense in the 1-50ms range where meaningful latency shifts occur in a trading system.

**Go runtime metrics** (free via `promhttp.Handler()`): `go_goroutines`, `go_gc_duration_seconds`, `go_memstats_alloc_bytes`. Visible on the Grafana "Go Runtime" row.

---

## Log Structure

Every request produces a structured JSON log line via zerolog:

```json
{
  "level": "info",
  "request_id": "a1b2c3d4-...",
  "method": "POST",
  "path": "/api/v1/orders",
  "status": 201,
  "duration": "2.134ms",
  "remote_addr": "10.244.0.1:54321",
  "time": "2025-01-15T14:30:00.123456789Z",
  "message": "request completed"
}
```

The `request_id` creates three-way correlation: client sees it in `X-Request-ID` header, logs contain it, traces are tagged with it.

| Level | When | Example |
|-------|------|---------|
| Info | Every request, startup/shutdown | `"application server starting"` |
| Warn | Degraded but not failing | `"redis unavailable; operating in degraded mode"` |
| Error | Request-affecting failures | `"app server shutdown error"` |
| Debug | Cache ops, persistence detail (enable via `LOG_LEVEL=debug`) | `"cache set failed"` |

---

## Alerting

Alerts answer one question: **is the user experience degraded?**

### Pages (P1 → PagerDuty)

| Alert | Condition | Why it pages |
|-------|-----------|-------------|
| Fast burn | Error budget consumed at 14.4x sustainable rate over 1h | 30-day budget exhausted in ~2 days if unchecked |
| Unavailability | Zero successful responses on `/api/v1/*` for 2 min | Complete outage |
| Latency extreme | p99 > 500ms for 5 min | 10x SLO target — something is fundamentally broken |

### Tickets (P2 → Slack + Jira)

| Alert | Condition | Why it tickets |
|-------|-----------|---------------|
| Slow burn | Budget consumed at 1x rate over 3d | Gradual degradation invisible in short windows |
| HPA at max | 10 pods, still >90% utilization | Traffic pattern changed or efficiency problem |
| Multi-pod readiness failure | >2 pods fail readiness simultaneously | Systemic issue, not a transient restart |

### Does NOT alert

- **Individual pod restart** — Kubernetes handles this. Alert only if >3/hour across the deployment.
- **CPU above 70%** — the HPA acts on this. An alert would be noise.
- **Single 5xx** — transient. The SLO burn rate captures sustained problems.
- **Node-level metrics** — infrastructure team's concern. Application SLO captures user impact regardless of cause.

---

## Incident Walkthrough

**Scenario:** p99 latency on `POST /orders` rises from 8ms to 120ms. CPU and memory appear normal. Some users report intermittent failures.

### Minute 0-2: Confirm and scope

1. **Grafana → `http_request_duration_seconds`** — which endpoints? If only `/orders` but not `/orderbook/{pair}`, the problem is the write path (matching + Redis), not reads.
2. **Correlate with deploy events** — did latency start when a new revision rolled out?
3. **Check error rate** — are the failures 5xx or client-side timeouts? If users see timeouts but the service returns 200, the latency is network/proxy, not application.

### Minute 2-5: Narrow the hypothesis

4. **`http_requests_in_flight`** — is concurrency spiking? If 10x normal, check for traffic surge or rate limiter misconfiguration. If normal, each individual request is slow.
5. **Redis latency** — order placement does cache invalidation (`DEL`) and journal writes (`LPUSH`). Check `redis_commands_duration_seconds_total` from the exporter. Check `redis_connected_clients` against pool size (50).
6. **CFS throttling** — CPU may look "normal" at 250m but if hitting the 500m limit in bursts, check `container_cpu_cfs_throttled_periods_total`.

### Minute 5-10: Trace a slow request

7. **Tempo → filter by `duration > 100ms`** — the trace shows spans for handler, engine.PlaceOrder, engine.match, store.RecordPlace, cache.Del. Which span is slow?
8. **If `store.RecordPlace` = 80ms** → Redis is the bottleneck. Check `maxmemory` hit causing eviction churn.
9. **If `engine.match` = 80ms** → book is too deep, `sort.Slice` is O(n log n). Check book depth via `/orderbook/BTC-USD?depth=100`.
10. **If latency is high only on one pair** → per-book mutex contention. All orders for that pair serialize through one lock.

### Resolution matrix

| Finding | Root cause | Fix |
|---------|-----------|-----|
| Redis `SET` latency spiked | `maxmemory` hit, eviction churn | Increase `maxmemory` or reduce journal size |
| Connection pool exhausted | Traffic > PoolSize (50) | Increase PoolSize and MinIdleConns |
| CFS throttling | CPU burst above limit | Set request=limit for Guaranteed QoS (already done in base) |
| `engine.match` slow | Large book, O(n log n) sort | Migrate to skiplist data structure |
| Single-pair lock contention | Hot pair serializes through one mutex | Shard book or lock-free matching |
| GC pauses | Memory pressure from large trade history | Check `go_gc_duration_seconds`, tune GOGC |

### After resolution

1. Verify p99 returns below 50ms SLO target.
2. Calculate error budget consumed during incident. If >10%, write incident review.
3. Add missing monitoring for the specific failure mode (e.g., alert on `redis_connected_clients > pool_size * 0.8`).

---

## Multi-Region Considerations

- **SLI measurement point:** Move from in-cluster Prometheus to global edge (Route 53 health checks). SLO should reflect user experience from their region.
- **Replication lag SLI:** Target < 100ms between regions if using active-passive order book replication.
- **Regional error budgets:** Each region gets its own. A single-region outage consumes that region's budget, not the global aggregate.
- **Alert routing:** Regional on-call team, with escalation to global SRE if multiple regions degrade simultaneously.

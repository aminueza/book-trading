# Observability and Reliability

This document defines how the order book service is monitored, what constitutes healthy operation, and how to debug production incidents.

## Service Level Objectives (SLOs)

### SLO 1: Availability

- **SLI**: Proportion of non-5xx responses on `/api/v1/*` endpoints, measured at the Istio gateway.
- **Target**: 99.9% over a 30-day rolling window.
- **Budget**: ~43 minutes of downtime per month.
- **Why this reflects user impact**: A 5xx on order placement means a trade was lost. Users experience this directly as failed transactions. Infrastructure metrics like node CPU or pod restart count do not capture whether users can actually trade.

Prometheus query:
```promql
1 - (
  sum(rate(http_requests_total{path=~"/api/v1/.*", status=~"5.."}[30d]))
  /
  sum(rate(http_requests_total{path=~"/api/v1/.*"}[30d]))
)
```

### SLO 2: Latency

- **SLI**: p99 latency of `POST /api/v1/orders` (order placement), measured from the application's Prometheus histogram.
- **Target**: p99 < 50ms.
- **Why 50ms**: Order matching is in-memory and should complete in microseconds. The 50ms budget accounts for network hops (Istio sidecar, pod networking), JSON serialization, Redis cache invalidation, and middleware overhead. If p99 exceeds this, something in the request path is degraded.

Prometheus query:
```promql
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{method="POST", path="/api/v1/orders"}[5m])) by (le)
)
```

### Error Budget Policy

| Budget consumed | Action |
|----------------|--------|
| < 25% | Normal operations. Deploy at will. |
| 25-50% | Increased monitoring. Review recent deploys for correlation. |
| 50-80% | Freeze non-critical deployments. Investigate top error contributors. |
| > 80% | Page on-call. Halt all changes. Focus entirely on restoring budget. |

The error budget resets on a 30-day rolling basis. Budget consumption rate (burn rate) is more actionable than absolute budget remaining, because it indicates whether the situation is getting worse.

## Metrics That Matter

The application emits three Prometheus metrics (defined in `application/internal/middleware/middleware.go`):

| Metric | Type | Labels | Purpose |
|--------|------|--------|---------|
| `http_requests_total` | Counter | method, path, status | Traffic volume and error breakdown |
| `http_request_duration_seconds` | Histogram | method, path | Latency distribution (buckets: 1ms to 1s) |
| `http_requests_in_flight` | Gauge | (none) | Concurrency / saturation indicator |

These map to three of the four golden signals (traffic, latency, saturation). Errors are derived from `http_requests_total` by filtering on `status=~"5.."`.

### Histogram Bucket Design

The histogram buckets are: `0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0` seconds.

This is intentionally dense in the 1-50ms range because that is where meaningful latency shifts occur in a trading system. A jump from 5ms to 25ms p99 is operationally significant; the buckets are fine-grained enough to detect this. The 0.25-1.0s buckets exist to capture outliers without requiring a separate metric.

### What Is NOT Instrumented (and Why)

- **Business metrics** (order count, trade volume, book depth): These belong in the trading domain's own dashboards, not in the generic HTTP middleware. They would be added as custom Prometheus metrics in `handler.go` or `engine.go` in a production system.
- **Go runtime metrics**: The `promhttp.Handler()` on port 9090 already exposes `go_goroutines`, `go_memstats_*`, and `process_*` metrics via the default Prometheus client library. No custom instrumentation needed.

## Log Structure

All application logs use structured JSON via zerolog. Every log line includes:

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

The `request_id` field correlates logs to traces (the same ID is set as a span attribute in OpenTelemetry) and is returned to the client via the `X-Request-ID` response header. This creates a three-way correlation: client sees the ID, logs contain it, traces are tagged with it.

### Log Levels

| Level | Use | Example |
|-------|-----|---------|
| Info | Every completed request, startup events, shutdown sequence | `"application server starting"` |
| Warn | Degraded operation that does not fail the request | `"redis unavailable at startup; operating in degraded mode"` |
| Error | Request-affecting failures, shutdown errors | `"app server shutdown error"` |
| Debug | Cache operations, persistence details (enabled via `LOG_LEVEL=debug`) | `"cache set failed"` |

Debug logging is disabled by default and enabled per-environment via the `LOG_LEVEL` environment variable. This avoids log volume explosion in production while preserving the ability to enable verbose logging during incidents without a redeploy (just change the ConfigMap and restart).

## Alerting Philosophy

Alerts should answer one question: **Is the user experience degraded?**

### What Pages Someone (P1 - PagerDuty)

- **SLO fast burn**: Error budget is being consumed at 14.4x the sustainable rate over a 1-hour window. This means the 30-day budget will be exhausted in ~2 days if nothing changes. Example: sudden spike in 5xx errors after a deploy.
- **Complete unavailability**: Zero successful responses on `/api/v1/*` for 2 minutes. All pods are down or unreachable.
- **Latency extreme**: p99 > 500ms for 5 minutes (10x the SLO target). Something is fundamentally broken, not just degraded.

### What Creates a Ticket (P2 - Slack + Jira)

- **SLO slow burn**: Error budget consumed at 1x the sustainable rate over a 3-day window. The service is slowly degrading. This catches problems that are invisible in short windows: a memory leak, a gradually growing queue, a slow increase in Redis latency.
- **Readiness probe failures**: More than 2 pods fail readiness simultaneously. Individual pod restarts are normal and handled by Kubernetes.
- **HPA at max replicas**: The autoscaler has scaled to its maximum (10 pods) and is still at >90% target utilization. Either the traffic pattern has changed or there is a resource efficiency problem.

### What Does NOT Alert

- **Individual pod restart**: Kubernetes handles this. A single OOMKill is not an incident. Only alert if the restart rate exceeds 3 per hour across the deployment (suggests a systemic issue).
- **CPU usage above 70%**: This is what the HPA acts on. The HPA is the response; an alert would just be noise.
- **Single 5xx error**: Transient errors happen (network blips, client disconnects). The SLO burn rate captures sustained problems without alerting on individual events.
- **Node-level metrics**: Node CPU, memory, and disk are the infrastructure team's concern. The application SLO captures the user impact regardless of underlying cause.

### Alert Routing

```
P1 (fast burn, unavailability)  -->  PagerDuty  -->  On-call SRE
P2 (slow burn, HPA saturation)  -->  Slack #trading-alerts  -->  Jira ticket (auto-created)
Info (deploy events, scale events)  -->  Slack #trading-deploys  -->  No action required
```

## Incident Walkthrough: Latency Spike with Normal CPU/Memory

**Scenario**: p99 latency on `POST /api/v1/orders` increases from 8ms to 120ms. CPU and memory utilization appear normal across all pods. Some users report intermittent failures.

### Minute 0-2: Confirm and Scope

1. **Open Grafana, check `http_request_duration_seconds` histogram**.
   - Which endpoints are affected? If only `/api/v1/orders` but not `/api/v1/orderbook/{pair}`, the problem is in the write path (matching + Redis persistence), not the read path.
   - When did the increase start? Correlate with deploy events (`kube_deployment_status_observed_generation` or Grafana annotations).

2. **Check error rate**. Are the intermittent failures 5xx or timeouts?
   - `rate(http_requests_total{status=~"5.."}[1m])` -- if this is elevated, there is a hard failure, not just slowness.
   - If users see timeouts but the service returns 200s, the latency is at the network/proxy layer, not the application.

### Minute 2-5: Narrow the Hypothesis

3. **Check `http_requests_in_flight`**. Is concurrency spiking?
   - If in-flight is 10x normal, there may be a upstream traffic surge or the rate limiter is misconfigured. Check `rate(http_requests_total[1m])` to see if request volume changed.
   - If in-flight is normal but latency is high, each individual request is slow.

4. **Check Redis latency**. The order placement path does cache invalidation (`DEL orderbook:{pair}`) and persistence journal writes (`LPUSH persist:journal`).
   - If Redis is slow, every order placement pays the penalty.
   - Check `redis_commands_duration_seconds_total` from the redis-exporter. Look for spikes in `SET`, `DEL`, or `LPUSH` command latencies.
   - Check `redis_connected_clients` -- if the connection pool is exhausted (>50 clients, matching the PoolSize config), requests will queue waiting for a connection.

5. **Check pod-level resource pressure** beyond simple CPU/memory.
   - `kubectl top pods -n trading` -- CPU may show "normal" at 250m but if the pod limit is 500m and there are scheduling bursts, CFS throttling could add latency. Check `container_cpu_cfs_throttled_periods_total` in kubelet metrics.
   - Check `go_goroutines` -- a goroutine leak manifests as high concurrency with normal CPU until GC pressure causes stop-the-world pauses.

### Minute 5-10: Trace a Slow Request

6. **Pick a slow trace in Tempo**. Filter by `service.name=orderbook-service` and `duration > 100ms`.
   - The trace shows spans for: HTTP handler, engine.PlaceOrder, engine.match, store.RecordPlace, cache.Del.
   - If `store.RecordPlace` shows 80ms, the bottleneck is Redis write.
   - If `engine.match` shows 80ms, the order book is too deep and sort.Slice is expensive (O(n log n) per insertion). Check the book depth: `curl /api/v1/orderbook/BTC-USD?depth=100` and count total open orders.

7. **Check for lock contention**. The matching engine uses a per-book mutex. If there is a traffic surge on a single pair (e.g., BTC-USD), all orders for that pair serialize through one lock.
   - This would manifest as: latency high on BTC-USD, normal on other pairs.
   - Verify: compare `http_request_duration_seconds` filtered by pair (requires adding pair as a label or checking trace attributes).

### Minute 10-15: Root Cause Scenarios

| Finding | Root Cause | Fix |
|---------|-----------|-----|
| Redis `SET` latency spiked | Redis `maxmemory` hit, causing eviction churn during writes | Increase `maxmemory` or reduce journal length (`journalMaxLen`) |
| Redis connection pool exhausted | Traffic surge exceeded PoolSize (50) | Increase PoolSize and MinIdleConns in main.go config |
| CFS throttling on pods | CPU burst above limit causing kernel-level throttling | Raise CPU limit or set request=limit to get Guaranteed QoS (already done in base deployment) |
| `engine.match` slow | Large book with thousands of open orders, sort.Slice is O(n log n) | Optimize to skiplist/tree data structure (documented improvement) |
| Single-pair lock contention | All traffic on one pair serializes through one mutex | Shard the book or implement lock-free matching |
| Network: Istio sidecar latency | Envoy proxy added latency (mutual TLS handshake, filter chain) | Check Istio proxy access logs, verify mTLS certificate rotation is not churning |
| GC pauses | Memory pressure from large in-memory book + trade history | Check `go_gc_duration_seconds`, tune GOGC, reduce trade history size |

### Resolution and Follow-Up

After identifying and fixing the root cause:

1. **Verify**: p99 latency returns below 50ms SLO target.
2. **Error budget**: Calculate how much budget was consumed during the incident. If >10%, write a brief incident review.
3. **Prevent recurrence**: Add missing monitoring (e.g., if Redis connection pool exhaustion was the cause, add an alert on `redis_connected_clients > pool_size * 0.8`).
4. **Update runbook**: Document the debugging path that worked for this specific failure mode.

## What Would Change in a Multi-Region Deployment

- **SLO measurement point**: Move SLI measurement from in-cluster Prometheus to a global edge metric (e.g., Cloudflare Workers or Route 53 health checks). The SLO should reflect user experience from their region, not from within the cluster.
- **Cross-region latency SLI**: Add an SLI for replication lag between regions (if using active-passive replication of the order book state). Target: replication lag < 100ms.
- **Regional error budgets**: Each region gets its own error budget. A single-region outage consumes that region's budget, not the global budget. This prevents a failing region from masking healthy regions in aggregate metrics.
- **Alert routing**: Route alerts to the regional on-call team, with escalation to global SRE if multiple regions are affected simultaneously.

# Observability and Reliability

How the order book service is monitored and how to debug it when things go wrong.

---

## SLOs

Two SLOs, both chosen because they reflect what users actually experience:

**Availability: 99.9% over 30 days.** Measured as non-5xx responses on `/api/v1/*` at the Istio gateway. A 5xx on order placement means a trade was lost — that's the user impact we're tracking, not node CPU or pod restart count.

```promql
1 - (
  sum(rate(http_requests_total{path=~"/api/v1/.*", status=~"5.."}[30d]))
  /
  sum(rate(http_requests_total{path=~"/api/v1/.*"}[30d]))
)
```

Budget: ~43 minutes/month. At 50% consumed, freeze non-critical deploys. At 80%, page on-call and halt all changes.

**Order placement latency: p99 < 50ms.** Matching is in-memory and takes microseconds. The 50ms budget covers the full request path: Istio sidecar, JSON parsing, matching, Redis cache invalidation, response serialization. If p99 exceeds this, something is degraded.

```promql
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{method="POST", path="/api/v1/orders"}[5m])) by (le)
)
```

## Metrics

Three application metrics from `application/internal/middleware/middleware.go`:

| Metric | Type | Labels |
|--------|------|--------|
| `http_requests_total` | Counter | method, path, status |
| `http_request_duration_seconds` | Histogram | method, path |
| `http_requests_in_flight` | Gauge | — |

These cover three of the four golden signals (traffic, latency, saturation). Errors are derived from `http_requests_total` by filtering on `status=~"5.."`.

The histogram buckets are intentionally dense in the 1-50ms range (`0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0`) because that's where meaningful shifts happen in a trading system. A jump from 5ms to 25ms p99 matters; the coarse 0.25-1.0s buckets are just there to catch outliers.

Go runtime metrics (`go_goroutines`, `go_gc_duration_seconds`, `go_memstats_alloc_bytes`) are exposed for free via `promhttp.Handler()` and shown in the Grafana "Go Runtime" row.

## Logs

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

The `request_id` ties everything together: the client sees it in `X-Request-ID`, logs contain it, traces are tagged with it. Three-way correlation without any extra effort during an incident.

Debug logging is off by default (`LOG_LEVEL=info`). Change the ConfigMap and restart to enable it — no redeploy needed.

## Alerting

The goal is to alert on user impact, not infrastructure noise.

**Pages (PagerDuty):** SLO fast burn (14.4x rate over 1h — budget exhausted in ~2 days if unchecked), complete unavailability (zero successful responses for 2 min), or extreme latency (p99 > 500ms for 5 min).

**Tickets (Slack + Jira):** SLO slow burn (1x rate over 3d — gradual degradation), HPA at max replicas and still saturated, or multiple pods failing readiness simultaneously.

**Does not alert:** Individual pod restarts (Kubernetes handles it), CPU above 70% (that's what the HPA is for), single 5xx errors (transient), node-level metrics (infrastructure team's concern — the application SLO captures user impact regardless of cause).

The alerting rules are implemented as a `PrometheusRule` CRD in `infrastructure/deploy/kubernetes/base/prometheusrule.yaml`.

## Incident Walkthrough

**Scenario from the assessment:** latency increases, CPU and memory look normal, some users report intermittent failures.

Here's how I'd work through it.

**First thing:** open Grafana, look at `http_request_duration_seconds`. Which endpoints are slow? If it's only `POST /orders` but `GET /orderbook/{pair}` is fine, the problem is in the write path — matching or Redis persistence. If everything is slow, it's lower in the stack (network, sidecar, node). When did the spike start? Overlay deploy events on the graph. If it correlates with a rollout, that's the first hypothesis.

**Check concurrency.** Is `http_requests_in_flight` spiking? If it's 10x normal with normal request rate, something is holding connections open. If in-flight is normal but latency is high, each individual request is slow.

**Check Redis.** Order placement does a cache `DEL` and a journal `LPUSH`. If Redis is slow, every write pays. Look at `redis_commands_duration_seconds_total` from the exporter. Also check `redis_connected_clients` against the pool size (50) — if they're converging, requests are queueing for connections.

**Check for CFS throttling.** CPU can look "normal" at 250m but if the pod hits the 500m limit in bursts, the kernel throttles it. This shows up as latency spikes that don't correlate with average CPU. Check `container_cpu_cfs_throttled_periods_total` — if it's climbing, that's the cause. (Our base deployment sets request=limit specifically to avoid this, but it's worth verifying in case an overlay changed it.)

**Trace a slow request.** Filter Tempo by `duration > 100ms`. The trace breaks down into spans: handler, `engine.PlaceOrder`, `engine.match`, `store.RecordPlace`, `cache.Del`. Whichever span is fat is where the problem is.

If `store.RecordPlace` is 80ms — Redis is the bottleneck, probably `maxmemory` hit causing eviction churn during writes. If `engine.match` is 80ms — the book is too deep and `sort.Slice` (O(n log n)) is expensive. Check book depth. If latency is high on one pair but not others — per-book mutex contention, all orders for that pair serialize through one lock.

**After fixing it:** verify p99 drops below 50ms. Calculate error budget consumed. If it was more than 10%, write a brief incident review. Add monitoring for whatever was missing — if Redis pool exhaustion was the cause, add an alert on `redis_connected_clients > pool_size * 0.8`.

## Multi-Region

If this went multi-region: move SLI measurement to the edge (Route 53 health checks, not in-cluster Prometheus). Add a replication lag SLI between regions. Give each region its own error budget — a single-region outage shouldn't mask healthy regions in the aggregate.

# Observability

How monitoring works and how to debug things when they break.

## SLOs

Two SLOs based on what users actually feel:

**Availability: 99.9% over 30 days.** Non-5xx on `/api/v1/*` measured at Istio 
gateway. That's about 43 minutes of budget per month. At 50% burned we freeze 
deploys, at 80% we page.

**Order placement latency: p99 under 100ms.** Measured locally at 169ms p99 
under load (10 concurrency, KinD) — we're already over. The bottleneck is 
synchronous Redis writes in the request path. Realistic target after moving 
journal writes async is p99 < 50ms, but until that's done, 100ms is the honest 
number.

## What we actually measure

Three metrics from the middleware, that's it:

- `http_requests_total` (counter) — method, path, status
- `http_request_duration_seconds` (histogram) — method, path
- `http_requests_in_flight` (gauge)

Histogram buckets are dense in 1-50ms (0.001, 0.005, 0.01, 0.025, 0.05) 
because for an order book, going from 5ms to 25ms matters. Standard Prometheus 
defaults would miss that shift entirely.

**Known gap:** There are no Redis client metrics. We can't see Redis RTT, 
connection pool usage, or command latency from the app. The redis-exporter 
gives server-side stats but not per-call latency from the application's 
perspective. This is the first thing to add.

**Known gap:** OpenTelemetry is wired up but only gives one span per HTTP 
request (auto-instrumented via otelmux). There are no custom spans on the 
matching engine, Redis calls, or cache operations. During an incident you 
get request-level duration but can't break it down further without adding 
instrumentation.

Go runtime metrics (goroutines, GC, memory) come free from promhttp.

## Logs

Structured JSON via zerolog on every request — level, request_id, method, 
path, status, duration, remote_addr. The request_id shows up in the 
X-Request-ID header so you can grep logs by the same ID the client sees.

Debug logging is off by default. Flip LOG_LEVEL in the ConfigMap and 
restart.

## Alerting

Pages (PagerDuty): SLO fast burn (14.4x error rate over 1h), total 
unavailability (2 min), extreme latency (p99 > 500ms for 5 min).

Tickets (Slack): slow burn (1x over 3d), HPA maxed out, multiple pods 
failing readiness.

Doesn't alert: individual restarts, CPU over 70%, single 5xx, node metrics. 
Kubernetes and HPA handle those. If they cause user impact, the SLO alert 
fires anyway.

## Debugging a latency spike

If latency goes up but CPU/memory look normal and users see intermittent 
failures:

Start with `http_request_duration_seconds` in Grafana. Which endpoints? 
If only POST /orders is slow, it's the write path. If everything is slow, 
it's lower — network or sidecar. Check if it lines up with a deploy.

Check `http_requests_in_flight`. If it's spiking with normal request rate, 
something is holding connections. If it's normal, individual requests are 
just slow.

Check Redis via the exporter dashboard. We don't have app-side Redis 
metrics yet (see gap above), so we're limited to server-side stats — 
connected clients, memory usage, slowlog. If connected clients are near 
the pool size (50), requests are queuing.

Check CFS throttling: `container_cpu_cfs_throttled_periods_total`. CPU 
can look fine at 250m average but if it bursts past the 500m limit, the 
kernel throttles and you get latency spikes. We set request=limit to 
avoid this but worth verifying nothing changed.

Without custom trace spans we can't break down where inside a request the 
time goes. That's a gap for now, correlate log duration with Redis 
exporter timing to narrow it down.


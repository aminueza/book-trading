#!/usr/bin/env bash
# validate.sh — Correctness checks + optional load generation for metrics/traces/dashboards.
#
# Usage:
#   ./scripts/validate.sh [base_url] [--no-load] [--load-only]
#
# Default base_url: http://localhost:8080
#
# Environment (load phase):
#   VALIDATE_LOAD_REQUESTS   Total HTTP requests to fire (default: 8000)
#   VALIDATE_LOAD_PARALLEL   Max concurrent in-flight requests (default: 40)
#   VALIDATE_LATENCY_SAMPLES Serial samples for latency report (default: 200)
#   METRICS_URL              Prometheus scrape URL (default: derived from host + :9090/metrics)
#
# Correctness uses isolated pair names (default VAL-<pid>-MATCH / VAL-<pid>-CANCEL) so a
# persistent Redis volume does not leave extra BTC-USD liquidity from earlier runs.
# Override with VALIDATE_PAIR_MATCH and VALIDATE_PAIR_CANCEL if needed.
#
# After load, open Grafana (Docker Compose folder) and Prometheus; Explore → Tempo for traces.
# Prometheus histograms need a short window of traffic — use a 5–15m time range in Grafana.

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
DO_CORRECTNESS=true
DO_LOAD=true

for arg in "$@"; do
  case "$arg" in
    --no-load) DO_LOAD=false ;;
    --load-only) DO_CORRECTNESS=false ;;
    http://*|https://*) BASE_URL="$arg" ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

# Subshells (metrics URL, xargs workers) need BASE_URL in the environment.
export BASE_URL

# Fresh symbol names per process — avoids flaky "remaining ask" when Redis still holds BTC-USD state.
PAIR_MATCH="${VALIDATE_PAIR_MATCH:-VAL-$$-MATCH}"
PAIR_CANCEL="${VALIDATE_PAIR_CANCEL:-VAL-$$-CANCEL}"

PASS=0
FAIL=0

# Avoid `((PASS++))` under `set -e` (exit status 1 when expression is 0).
check() {
  local name="$1"
  local expected="$2"
  local actual="$3"

  if [ "$actual" = "$expected" ]; then
    echo "  ✓ ${name}"
    PASS=$((PASS + 1))
  else
    echo "  ✗ ${name} (expected: ${expected}, got: ${actual})"
    FAIL=$((FAIL + 1))
  fi
}

derive_metrics_url() {
  if [ -n "${METRICS_URL:-}" ]; then
    echo "$METRICS_URL"
    return 0
  fi
  local out
  if command -v python3 >/dev/null 2>&1; then
    out="$(BU="$BASE_URL" python3 -c 'import os, urllib.parse as u; p=u.urlparse(os.environ["BU"]); h=p.hostname or "localhost"; print(f"{p.scheme}://{h}:9090/metrics")' 2>/dev/null)" || true
    if [ -n "$out" ]; then
      echo "$out"
      return 0
    fi
  fi
  echo "http://127.0.0.1:9090/metrics"
}

METRICS_URL="$(derive_metrics_url)"

# --- Single request for load generator (index drives path mix) ---
fire_request() {
  local i="$1"
  local mod=$((i % 6))
  case "$mod" in
    0)
      curl -sS -o /dev/null --connect-timeout 2 --max-time 10 \
        "${BASE_URL}/api/v1/orderbook/BTC-USD" || true
      ;;
    1)
      curl -sS -o /dev/null --connect-timeout 2 --max-time 10 \
        "${BASE_URL}/api/v1/trades/BTC-USD" || true
      ;;
    2)
      curl -sS -o /dev/null --connect-timeout 2 --max-time 10 \
        "${BASE_URL}/api/v1/orderbook/ETH-USD" || true
      ;;
    3)
      curl -sS -o /dev/null --connect-timeout 2 --max-time 10 \
        "${BASE_URL}/healthz" || true
      ;;
    4)
      curl -sS -o /dev/null --connect-timeout 2 --max-time 10 \
        "${BASE_URL}/readyz" || true
      ;;
    5)
      # Light write load — unique-ish price keeps matching engine busy; may 4xx if duplicate id — ignore
      local p=$((3000 + (i % 200)))
      curl -sS -o /dev/null --connect-timeout 2 --max-time 10 \
        -X POST "${BASE_URL}/api/v1/orders" \
        -H "Content-Type: application/json" \
        -d "{\"pair\":\"ETH-USD\",\"side\":\"buy\",\"price\":${p}.0,\"quantity\":0.01}" || true
      ;;
  esac
}

run_load_phase() {
  local total="${VALIDATE_LOAD_REQUESTS:-8000}"
  local parallel="${VALIDATE_LOAD_PARALLEL:-40}"
  local samples="${VALIDATE_LATENCY_SAMPLES:-200}"

  echo ""
  echo "=== Load generation (Prometheus + Tempo) ==="
  echo "  Target: ${BASE_URL}"
  echo "  Requests: ${total}  parallel: ${parallel}"
  echo "  (If you see many 429s, lower VALIDATE_LOAD_PARALLEL — app rate-limits per IP.)"
  echo ""

  local start
  start=$(date +%s)

  # macOS ships a POSIX xargs; -P is supported on BSD/GNU xargs used on Mac/Linux CI
  seq 1 "$total" | xargs -P "$parallel" -n 1 bash -c 'fire_request "$1"' _ || true

  local elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 1 ] && elapsed=1
  echo "  Wall time: ${elapsed}s (~$(( total / elapsed )) req/s average)"
  echo ""

  echo "[Latency sample — serial GET ${BASE_URL}/healthz]"
  local tmp
  tmp=$(mktemp)
  local i
  for i in $(seq 1 "$samples"); do
    curl -sS -o /dev/null -w "%{time_total}\n" --connect-timeout 2 --max-time 10 \
      "${BASE_URL}/healthz" 2>/dev/null || echo "9.999"
  done >"$tmp"

  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import sys
xs = sorted(float(x) for x in open('$tmp') if x.strip())
if not xs:
    print('  (no samples)')
    sys.exit(0)
def pct(p):
    i = min(len(xs)-1, max(0, int(p * len(xs)) - 1))
    return xs[i]
print(f'  samples={len(xs)}  min={xs[0]*1000:.2f}ms  p50={pct(0.50)*1000:.2f}ms  p95={pct(0.95)*1000:.2f}ms  p99={pct(0.99)*1000:.2f}ms  max={xs[-1]*1000:.2f}ms')
"
  else
    sort -n "$tmp" | awk '
      NR==1 {min=$1}
      {a[NR]=$1; n=NR}
      END {
        if(n<1) exit
        print "  samples=" n " min=" min*1000 "ms max=" a[n]*1000 "ms (install python3 for p50/p95)"
      }'
  fi
  rm -f "$tmp"
  echo ""
  echo "  Tip: In Grafana set time range to **Last 15 minutes**, refresh dashboard."
  echo "  Traces: Explore → Tempo → query service name **orderbook-service**."
}

export -f fire_request

# ---------------------------------------------------------------------------
# Correctness
# ---------------------------------------------------------------------------
if [ "$DO_CORRECTNESS" = true ]; then
  echo "=== Validating order book service at ${BASE_URL} ==="
  echo ""

  echo "[Health Checks]"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/healthz")
  check "Liveness probe" "200" "$HTTP_CODE"

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/readyz")
  check "Readiness probe" "200" "$HTTP_CODE"

  echo ""
  echo "[Order Placement] (pair ${PAIR_MATCH})"
  SELL_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d "{\"pair\":\"${PAIR_MATCH}\",\"side\":\"sell\",\"price\":50000.00,\"quantity\":1.5}")
  SELL_SUCCESS=$(echo "$SELL_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['success'])" 2>/dev/null || echo "false")
  check "Place sell order" "True" "$SELL_SUCCESS"

  BUY_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d "{\"pair\":\"${PAIR_MATCH}\",\"side\":\"buy\",\"price\":50000.00,\"quantity\":0.5}")
  BUY_SUCCESS=$(echo "$BUY_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['success'])" 2>/dev/null || echo "false")
  check "Place matching buy order" "True" "$BUY_SUCCESS"

  TRADE_COUNT=$(echo "$BUY_RESPONSE" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['data']['trades']))" 2>/dev/null || echo "0")
  check "Trade generated" "1" "$TRADE_COUNT"

  echo ""
  echo "[Order Book]"
  BOOK_RESPONSE=$(curl -s "${BASE_URL}/api/v1/orderbook/${PAIR_MATCH}")
  BOOK_SUCCESS=$(echo "$BOOK_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['success'])" 2>/dev/null || echo "false")
  check "Get order book" "True" "$BOOK_SUCCESS"

  # JSON may emit quantity as 1 (int) or 1.0 (float); normalize for string check.
  ASK_QTY=$(echo "$BOOK_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; q=float(d['asks'][0]['quantity']) if d.get('asks') else 0.0; print(q)" 2>/dev/null || echo "0")
  check "Remaining ask quantity" "1.0" "$ASK_QTY"

  echo ""
  echo "[Recent Trades]"
  TRADES_RESPONSE=$(curl -s "${BASE_URL}/api/v1/trades/${PAIR_MATCH}")
  TRADES_SUCCESS=$(echo "$TRADES_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['success'])" 2>/dev/null || echo "false")
  check "Get recent trades" "True" "$TRADES_SUCCESS"

  echo ""
  echo "[Order Cancellation]"
  NEW_ORDER=$(curl -s -X POST "${BASE_URL}/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d "{\"pair\":\"${PAIR_CANCEL}\",\"side\":\"buy\",\"price\":3000.00,\"quantity\":2.0}")
  ORDER_ID=$(echo "$NEW_ORDER" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['order']['id'])" 2>/dev/null || echo "")

  if [ -n "$ORDER_ID" ]; then
    CANCEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "${BASE_URL}/api/v1/orders/${ORDER_ID}?pair=${PAIR_CANCEL}")
    check "Cancel order" "200" "$CANCEL_CODE"
  else
    echo "  ✗ Cancel order (could not create order to cancel)"
    FAIL=$((FAIL + 1))
  fi

  echo ""
  echo "[Input Validation]"
  BAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d '{"pair":"","side":"buy","price":-1,"quantity":0}')
  check "Reject invalid input" "400" "$BAD_CODE"

  echo ""
  echo "[Request Tracing]"
  REQ_ID=$(curl -s -D - -o /dev/null "${BASE_URL}/healthz" | grep -i "x-request-id" | tr -d '\r' | awk '{print $2}')
  if [ -n "$REQ_ID" ]; then
    check "Request ID header present" "true" "true"
  else
    check "Request ID header present" "true" "false"
  fi

  echo ""
  echo "[Metrics]"
  METRICS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$METRICS_URL" 2>/dev/null || echo "000")
  if [ "$METRICS_CODE" = "200" ]; then
    check "Prometheus metrics reachable" "200" "$METRICS_CODE"
  else
    echo "  - Metrics not at ${METRICS_URL} (set METRICS_URL if needed)"
  fi

  echo ""
  echo "=== Correctness: ${PASS} passed, ${FAIL} failed ==="

  if [ "$FAIL" -gt 0 ]; then
    exit 1
  fi
fi

if [ "$DO_LOAD" = true ]; then
  run_load_phase
fi

if [ "$DO_CORRECTNESS" = false ] && [ "$DO_LOAD" = true ]; then
  exit 0
fi

exit 0

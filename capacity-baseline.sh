#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# capacity-baseline.sh — finds the request rate at which the SLO breaks
#
# Gradually increases load until either:
#   - p95 latency exceeds 500ms (latency SLO breach)
#   - Error rate exceeds 10% (availability SLO breach)
#   - Or max RPS reached
#
# Results are saved to docs/capacity-baseline-results.md
# Run from the root of your cloud-sre-lab project
# ─────────────────────────────────────────────────────────────────────────────

BASE_URL="http://localhost:8888"
RESULTS_FILE="docs/capacity-baseline-results.md"
PROMETHEUS_URL="http://localhost:9090"

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $1"; }

# ── Query Prometheus ──────────────────────────────────────────────────────────
query_prometheus() {
  local query=$1
  curl -s "${PROMETHEUS_URL}/api/v1/query" \
    --data-urlencode "query=${query}" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if results:
    print(results[0]['value'][1])
else:
    print('0')
" 2>/dev/null || echo "0"
}

# ── Send burst of requests ────────────────────────────────────────────────────
send_burst() {
  local rps=$1
  local duration=10  # seconds per test level
  local total=$((rps * duration))
  local delay
  delay=$(echo "scale=4; 1/$rps" | bc)

  for ((i=1; i<=total; i++)); do
    curl -s -o /dev/null "${BASE_URL}/" &
    sleep "$delay" 2>/dev/null || true
  done
  wait
}

# ── Main test loop ────────────────────────────────────────────────────────────
echo "════════════════════════════════════════"
echo "  Capacity Baseline Test"
echo "  Cloud Lab API — SLO Breaking Point"
echo "════════════════════════════════════════"
echo ""
warn "This test will gradually increase load."
warn "Watch Grafana at http://localhost:3000"
warn "Press Ctrl+C to stop at any time"
echo ""

# Initialise results file
mkdir -p docs
cat > "$RESULTS_FILE" << 'HEADER'
# Capacity Baseline Results

## Test configuration
- SLO: 99% availability, p95 latency < 500ms
- Method: Ramping load test — 10 RPS increments
- Duration per level: 10 seconds of sustained load

## Results

| RPS | p95 Latency | Error Rate | Status |
|-----|-------------|------------|--------|
HEADER

# Test levels — 10, 20, 30... up to 100 RPS
BREAKING_POINT=""
PREVIOUS_RPS=0

for RPS in 10 20 30 40 50 60 70 80 90 100; do
  log "Testing at ${RPS} requests/second..."

  # Send load
  send_burst $RPS

  # Wait for Prometheus to scrape the results
  sleep 15

  # Query metrics
  P95=$(query_prometheus "slo:latency_p95_5m")
  ERROR_RATE=$(query_prometheus "slo:error_rate_5m")

  # Convert to readable format
  P95_MS=$(echo "$P95 * 1000" | bc 2>/dev/null | cut -d. -f1)
  ERROR_PCT=$(echo "$ERROR_RATE * 100" | bc 2>/dev/null | cut -d. -f1)

  log "  p95 latency: ${P95_MS}ms | error rate: ${ERROR_PCT}%"

  # Determine status
  STATUS="✅ OK"
  BREACH=false

  if (( $(echo "$P95 > 0.5" | bc -l 2>/dev/null || echo 0) )); then
    STATUS="⚠️  LATENCY SLO BREACH"
    BREACH=true
  fi

  if (( $(echo "$ERROR_RATE > 0.10" | bc -l 2>/dev/null || echo 0) )); then
    STATUS="❌ ERROR RATE SLO BREACH"
    BREACH=true
  fi

  # Append to results
  echo "| ${RPS} | ${P95_MS}ms | ${ERROR_PCT}% | ${STATUS} |" >> "$RESULTS_FILE"

  if $BREACH && [[ -z "$BREAKING_POINT" ]]; then
    BREAKING_POINT=$RPS
    warn "SLO breach detected at ${RPS} RPS!"
    warn "Safe operating capacity: ${PREVIOUS_RPS} RPS"
    break
  fi

  PREVIOUS_RPS=$RPS
  log "  Status: ${STATUS} — continuing..."
  echo ""
done

# ── Write summary ─────────────────────────────────────────────────────────────
cat >> "$RESULTS_FILE" << SUMMARY

## Summary

| Metric | Value |
|--------|-------|
| Safe operating capacity | ${PREVIOUS_RPS} RPS |
| SLO breaking point | ${BREAKING_POINT:-">100"} RPS |
| Test date | $(date '+%Y-%m-%d') |
| Replicas during test | $(kubectl get deployment cloud-lab -n app -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "unknown") |

## Recommendations

- HPA should scale up before reaching ${BREAKING_POINT:-100} RPS
- Alert on sustained load above $((PREVIOUS_RPS * 80 / 100)) RPS (80% of safe capacity)
- Consider increasing replicas or resource limits if capacity is insufficient

## What this means for SLO management

At ${PREVIOUS_RPS} RPS the service operates within SLO targets.
Beyond ${BREAKING_POINT:-100} RPS the service breaches either the latency or
availability SLO. The HPA is configured to scale up at 60% CPU utilisation
which should provide headroom before the breaking point is reached.
SUMMARY

echo ""
echo "════════════════════════════════════════"
echo "  Capacity Baseline Complete"
echo "════════════════════════════════════════"
echo ""
ok "Safe operating capacity: ${PREVIOUS_RPS} RPS"
ok "Breaking point: ${BREAKING_POINT:-">100"} RPS"
echo ""
ok "Results saved to: $RESULTS_FILE"
echo ""
echo "  Add to git:"
echo "  git add docs/capacity-baseline-results.md"
echo "  git commit -m 'docs: add capacity baseline results'"
echo "════════════════════════════════════════"

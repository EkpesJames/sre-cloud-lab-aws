#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# fix-observability.sh
# Updates Prometheus scrape config to handle all three services separately
# Verifies Grafana, Alertmanager, and Jaeger are picking up all services
# ─────────────────────────────────────────────────────────────────────────────

set -e

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $1"; }

echo "════════════════════════════════════════"
echo "  Fixing Observability Stack"
echo "  Connecting all three services"
echo "════════════════════════════════════════"
echo ""

# ── Step 1: Update Prometheus scrape config via Helm ─────────────────────────
log "Upgrading kube-prometheus-stack with per-service scrape jobs..."
helm upgrade kube-prometheus \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values k8s/monitoring/kube-prometheus-stack-values.yaml \
  --timeout 5m
ok "Prometheus scrape config updated"

# ── Step 2: Apply updated PrometheusRule ─────────────────────────────────────
log "Applying per-service PrometheusRule..."
kubectl apply -f k8s/monitoring/prometheus-rules-distributed.yaml
ok "PrometheusRule applied"

# ── Step 3: Update Grafana dashboard ConfigMap ────────────────────────────────
log "Updating Grafana dashboard ConfigMap..."
kubectl create configmap grafana-dashboards \
  --namespace=monitoring \
  --from-file=sre-overview.json=grafana/dashboards/sre-overview.json \
  --dry-run=client -o yaml | kubectl apply -f -
ok "Grafana dashboard ConfigMap updated"

# ── Step 4: Restart Prometheus to pick up new config ─────────────────────────
log "Restarting Prometheus..."
kubectl rollout restart statefulset \
  prometheus-kube-prometheus-kube-prome-prometheus \
  -n monitoring
kubectl rollout status statefulset \
  prometheus-kube-prometheus-kube-prome-prometheus \
  -n monitoring --timeout=120s
ok "Prometheus restarted"

# ── Step 5: Wait for scrape targets to appear ────────────────────────────────
log "Waiting 30s for scrape targets to register..."
sleep 30

# ── Step 6: Verify all three services are being scraped ──────────────────────
echo ""
log "Checking Prometheus targets..."

check_target() {
  local job=$1
  local result
  result=$(curl -s "http://localhost:9090/api/v1/targets" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
targets = data.get('data', {}).get('activeTargets', [])
matches = [t for t in targets if t.get('labels', {}).get('job') == '$job']
healthy = [t for t in matches if t.get('health') == 'up']
print(f'{len(healthy)}/{len(matches)} UP')
" 2>/dev/null || echo "error")
  echo "  $job: $result"
}

check_target "api-gateway"
check_target "booking-service"
check_target "payment-service"

# ── Step 7: Generate traffic and verify metrics ───────────────────────────────
echo ""
log "Sending test traffic to populate metrics..."
for i in {1..10}; do
  curl -s -X POST http://localhost:8888/book \
    -H "Content-Type: application/json" \
    -d '{"event_type":"concert","seats":1}' > /dev/null
  sleep 0.5
done
ok "Test traffic sent"

log "Waiting 15s for Prometheus to scrape..."
sleep 15

# ── Step 8: Verify recording rules are computing ─────────────────────────────
echo ""
log "Checking recording rules..."

check_rule() {
  local rule=$1
  local result
  result=$(curl -s "http://localhost:9090/api/v1/query?query=${rule}" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if results:
    val = results[0]['value'][1]
    print(f'OK ({val})')
else:
    print('No data yet')
" 2>/dev/null || echo "error")
  echo "  $rule: $result"
}

check_rule "slo:api_gateway:success_rate_5m"
check_rule "slo:booking_service:success_rate_5m"
check_rule "slo:payment_service:success_rate_5m"

# ── Step 9: Verify Jaeger is receiving traces ─────────────────────────────────
echo ""
log "Checking Jaeger services..."
curl -s "http://localhost:16686/api/services" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
services = data.get('data', [])
print('  Jaeger services: ' + ', '.join(services))
" 2>/dev/null || warn "Jaeger not reachable"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Observability Fix Complete"
echo "════════════════════════════════════════"
echo ""
echo "  Verify in browser:"
echo ""
echo "  Prometheus targets:"
echo "  http://localhost:9090/targets"
echo "  → Should show 3 separate jobs:"
echo "    api-gateway (2 pods)"
echo "    booking-service (2 pods)"
echo "    payment-service (2 pods)"
echo ""
echo "  Prometheus queries:"
echo "  slo:api_gateway:success_rate_5m"
echo "  slo:booking_service:success_rate_5m"
echo "  slo:payment_service:success_rate_5m"
echo ""
echo "  Jaeger:"
echo "  http://localhost:16686"
echo "  → Should show services:"
echo "    api-gateway"
echo "    booking-service"
echo "    payment-service"
echo ""
echo "  Grafana:"
echo "  http://localhost:3000"
echo "  → Dashboards → Cloud Lab → SRE Overview"
echo "════════════════════════════════════════"

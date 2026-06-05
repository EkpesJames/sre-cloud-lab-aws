#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# week3-deploy.sh — adds tracing, circuit breaker, graceful shutdown
# Run from the root of your cloud-sre-lab project
# ─────────────────────────────────────────────────────────────────────────────

set -e

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $1"; }

echo "════════════════════════════════════════"
echo "  Week 3 — Tracing + Resilience"
echo "════════════════════════════════════════"
echo ""

# ── Step 1: Deploy Jaeger ─────────────────────────────────────────────────────
log "Deploying Jaeger..."
kubectl apply -f k8s/monitoring/jaeger.yaml
ok "Jaeger deployed"

# ── Step 2: Wait for Jaeger to be ready ──────────────────────────────────────
log "Waiting for Jaeger to be ready..."
kubectl wait --for=condition=ready pod \
  -l app=jaeger \
  -n monitoring \
  --timeout=60s
ok "Jaeger ready"

# ── Step 3: Update ConfigMap with Jaeger endpoint ────────────────────────────
log "Updating ConfigMap..."
kubectl apply -f k8s/app/configmap.yaml
ok "ConfigMap updated"

# ── Step 4: Rebuild app image with new dependencies ──────────────────────────
log "Rebuilding app image with OpenTelemetry + Tenacity..."
docker build -t cloud-lab:local -f docker/Dockerfile .
ok "Image built"

# ── Step 5: Import into k3s ───────────────────────────────────────────────────
log "Importing image into k3s..."
docker save cloud-lab:local | sudo k3s ctr images import -
ok "Image imported"

# ── Step 6: Rolling restart to pick up new image and config ──────────────────
log "Rolling restart of app deployment..."
kubectl rollout restart deployment/cloud-lab -n app
kubectl rollout status deployment/cloud-lab -n app --timeout=120s
ok "Rolling restart complete"

# ── Step 7: Verify ───────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Verification"
echo "════════════════════════════════════════"
kubectl get pods -n app
echo ""
kubectl get pods -n monitoring -l app=jaeger
echo ""

# Quick health checks
sleep 5
LIVE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8888/health/live)
CIRCUIT=$(curl -s http://localhost:8888/health/circuit)

echo "  Liveness:        HTTP $LIVE $([ "$LIVE" = "200" ] && echo "✓" || echo "✗")"
echo "  Circuit breaker: $CIRCUIT"
echo ""

echo "════════════════════════════════════════"
echo "  Access URLs"
echo "════════════════════════════════════════"
echo ""
echo "  Start Jaeger UI port-forward:"
echo "  kubectl port-forward -n monitoring svc/jaeger 16686:16686 &"
echo ""
echo "  Then open: http://localhost:16686"
echo ""
echo "  Week 3 deployment complete"
echo "════════════════════════════════════════"

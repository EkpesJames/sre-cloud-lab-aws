#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# deploy-distributed.sh — builds and deploys all three services
# Run from the root of your cloud-sre-lab project
# ─────────────────────────────────────────────────────────────────────────────

set -e

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $1"; }

echo "════════════════════════════════════════"
echo "  Distributed Booking System — Deploy"
echo "  API Gateway + Booking + Payment"
echo "════════════════════════════════════════"
echo ""

# ── Load credentials ──────────────────────────────────────────────────────────
[[ -f .env ]] && export $(grep -v '^#' .env | grep -v '^$' | xargs)

# ── Step 1: Build all images ──────────────────────────────────────────────────
log "Building images..."

docker build \
  -t api-gateway:local \
  -f api-gateway/Dockerfile \
  --build-arg SERVICE=api-gateway .
ok "api-gateway image built"

docker build \
  -t booking-service:local \
  -f booking-service/Dockerfile \
  --build-arg SERVICE=booking-service .
ok "booking-service image built"

docker build \
  -t payment-service:local \
  -f payment-service/Dockerfile \
  --build-arg SERVICE=payment-service .
ok "payment-service image built"

# ── Step 2: Import into k3s ───────────────────────────────────────────────────
log "Importing images into k3s containerd..."
docker save api-gateway:local     | sudo k3s ctr images import -
docker save booking-service:local | sudo k3s ctr images import -
docker save payment-service:local | sudo k3s ctr images import -
ok "All images imported"

# ── Step 3: Apply K8s manifests ───────────────────────────────────────────────
log "Applying Kubernetes manifests..."

# Update API gateway configmap
kubectl apply -f k8s/gateway/configmap.yaml
ok "API gateway configmap applied"

# Deploy booking service
kubectl apply -f k8s/booking/booking-service.yaml
ok "Booking service deployed"

# Deploy payment service
kubectl apply -f k8s/payment/payment-service.yaml
ok "Payment service deployed"

# Apply Prometheus rules
kubectl apply -f k8s/prometheus-rules-distributed.yaml
ok "PrometheusRule applied"

# ── Step 4: Update API gateway deployment image ───────────────────────────────
log "Updating API gateway to use new image..."
kubectl set image deployment/cloud-lab \
  cloud-lab=api-gateway:local \
  -n app 2>/dev/null || \
kubectl rollout restart deployment/cloud-lab -n app
ok "API gateway updated"

# ── Step 5: Wait for all services ────────────────────────────────────────────
log "Waiting for all services to be ready..."

kubectl rollout status deployment/cloud-lab -n app --timeout=120s
ok "API gateway ready"

kubectl rollout status deployment/booking-service -n app --timeout=120s
ok "Booking service ready"

kubectl rollout status deployment/payment-service -n app --timeout=120s
ok "Payment service ready"

# ── Step 6: Verify ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Pod status"
echo "════════════════════════════════════════"
kubectl get pods -n app
echo ""
kubectl get svc -n app
echo ""

echo "════════════════════════════════════════"
echo "  Port-forwards needed"
echo "════════════════════════════════════════"
echo ""
echo "  Add to sre-lab.sh or run manually:"
echo "  kubectl port-forward -n app svc/cloud-lab 8888:80 &"
echo "  kubectl port-forward -n app svc/booking-service 8889:80 &"
echo "  kubectl port-forward -n app svc/payment-service 8890:80 &"
echo ""
echo "  Test the full booking flow:"
echo "  curl -X POST http://localhost:8888/book \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"event_type\":\"concert\",\"seats\":2}'"
echo ""
echo "════════════════════════════════════════"
echo "  Deployment complete"
echo "════════════════════════════════════════"

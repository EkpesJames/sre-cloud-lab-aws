#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# k8s-apply.sh — applies all Week 1 Kubernetes manifests in the correct order
# Run from the root of your cloud-sre-lab project
# ─────────────────────────────────────────────────────────────────────────────

set -e

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $1"; }

log "Starting Week 1 deployment..."

# ── Step 1: Namespaces first — everything else depends on these ───────────────
log "Creating namespaces..."
kubectl apply -f k8s/namespaces/namespaces.yaml
ok "Namespaces created"

# ── Step 2: ConfigMap — app reads this on startup ─────────────────────────────
log "Applying ConfigMap..."
kubectl apply -f k8s/app/configmap.yaml
ok "ConfigMap applied"

# ── Step 3: Secret — must exist before Deployment starts ─────────────────────
log "Checking Secret exists..."
if kubectl get secret cloud-lab-secrets -n app >/dev/null 2>&1; then
  ok "Secret already exists — skipping"
else
  warn "Secret not found. Creating it now from your .env file..."
  if [[ -f .env ]]; then
    source .env
    kubectl create secret generic cloud-lab-secrets \
      --namespace=app \
      --from-literal=SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL}" \
      --from-literal=SMTP_USERNAME="${SMTP_USERNAME}" \
      --from-literal=SMTP_PASSWORD="${SMTP_PASSWORD}" \
      --from-literal=SMTP_FROM="${SMTP_FROM}" \
      --from-literal=ALERT_EMAIL_TO="${ALERT_EMAIL_TO}"
    ok "Secret created from .env"
  else
    warn "No .env file found. Creating secret with placeholder values..."
    warn "Update with real values: kubectl edit secret cloud-lab-secrets -n app"
    kubectl create secret generic cloud-lab-secrets \
      --namespace=app \
      --from-literal=SLACK_WEBHOOK_URL="REPLACE_ME" \
      --from-literal=SMTP_USERNAME="REPLACE_ME" \
      --from-literal=SMTP_PASSWORD="REPLACE_ME" \
      --from-literal=SMTP_FROM="REPLACE_ME" \
      --from-literal=ALERT_EMAIL_TO="REPLACE_ME"
  fi
fi

# ── Step 4: Build app image locally ──────────────────────────────────────────
log "Building app Docker image..."
docker build -t cloud-lab:local -f docker/Dockerfile .
ok "Image built: cloud-lab:local"

# ── Step 5: Import image into k3s containerd ─────────────────────────────────
# k3s uses containerd, not Docker — images must be explicitly imported
log "Importing image into k3s containerd..."
docker save cloud-lab:local | sudo k3s ctr images import -
ok "Image imported into k3s"

# ── Step 6: Patch deployment.yaml to use local image ─────────────────────────
log "Patching deployment to use local image..."
sed -i 's|ghcr.io/REPLACE_WITH_YOUR_GITHUB_USERNAME/cloud-lab:latest|cloud-lab:local|g' \
  k8s/app/deployment.yaml 2>/dev/null || true

# ── Step 7: Deploy ────────────────────────────────────────────────────────────
log "Applying Deployment..."
kubectl apply -f k8s/app/deployment.yaml
ok "Deployment applied"

log "Applying Service..."
kubectl apply -f k8s/app/service.yaml
ok "Service applied"

log "Applying PodDisruptionBudget..."
kubectl apply -f k8s/app/pdb.yaml
ok "PodDisruptionBudget applied"

log "Applying HorizontalPodAutoscaler..."
kubectl apply -f k8s/app/hpa.yaml
ok "HPA applied"

# ── Step 8: Wait for rollout ──────────────────────────────────────────────────
log "Waiting for deployment rollout..."
kubectl rollout status deployment/cloud-lab -n app --timeout=120s
ok "Rollout complete"

# ── Step 9: Verify everything ─────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Deployment status"
echo "════════════════════════════════════════"
kubectl get pods -n app -o wide
echo ""
kubectl get svc -n app
echo ""
kubectl get hpa -n app
echo ""

# ── Step 10: Quick health check ───────────────────────────────────────────────
log "Running health checks..."
sleep 5

LIVE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:30080/health/live)
READY=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:30080/health/ready)
METRICS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:30080/metrics)

echo ""
echo "  Liveness probe  → HTTP $LIVE  $([ "$LIVE" = "200" ] && echo "✓" || echo "✗")"
echo "  Readiness probe → HTTP $READY  $([ "$READY" = "200" ] && echo "✓" || echo "✗")"
echo "  Metrics         → HTTP $METRICS  $([ "$METRICS" = "200" ] && echo "✓" || echo "✗")"
echo ""

if [[ "$LIVE" = "200" && "$READY" = "200" ]]; then
  echo "  App is live at: http://localhost:30080"
  echo "  Metrics at:     http://localhost:30080/metrics"
else
  warn "Health checks not passing yet — pods may still be starting"
  warn "Run: kubectl get pods -n app -w"
fi

echo ""
echo "════════════════════════════════════════"
echo "  Week 1 deployment complete"
echo "════════════════════════════════════════"


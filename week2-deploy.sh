#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# week2-deploy.sh — deploys full observability stack via Helm
# Run from the root of your cloud-sre-lab project
# ─────────────────────────────────────────────────────────────────────────────

set -e

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $1"; }

# ── Load credentials from .env ────────────────────────────────────────────────
if [[ -f .env ]]; then
  export $(grep -v '^#' .env | grep -v '^$' | xargs)
  ok "Loaded credentials from .env"
else
  warn "No .env file found — Alertmanager notifications will not work"
fi

log "Starting Week 2 observability deployment..."

# ── Step 1: Add Helm repos ────────────────────────────────────────────────────
log "Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
ok "Helm repos updated"

# ── Step 2: Create monitoring namespace (if not already created) ──────────────
log "Ensuring monitoring namespace exists..."
kubectl apply -f k8s/namespaces/namespaces.yaml
ok "Namespaces ready"

# ── Step 3: Create Alertmanager config secret ─────────────────────────────────
# envsubst resolves ${VAR} placeholders with real values from .env
log "Creating Alertmanager config secret..."
envsubst < monitoring/alertmanager.yml > /tmp/alertmanager-resolved.yml

kubectl create secret generic alertmanager-config \
  --namespace=monitoring \
  --from-file=alertmanager.yaml=/tmp/alertmanager-resolved.yml \
  --dry-run=client -o yaml | kubectl apply -f -
ok "Alertmanager secret created"

# ── Step 4: Create Grafana dashboard ConfigMap ────────────────────────────────
log "Creating Grafana dashboard ConfigMap..."
kubectl create configmap grafana-dashboards \
  --namespace=monitoring \
  --from-file=sre-overview.json=grafana/dashboards/sre-overview.json \
  --dry-run=client -o yaml | kubectl apply -f -
ok "Grafana dashboard ConfigMap created"

# ── Step 5: Deploy kube-prometheus-stack ──────────────────────────────────────
log "Deploying kube-prometheus-stack (Prometheus + Grafana + Alertmanager)..."
log "This takes 2-3 minutes..."
helm upgrade --install kube-prometheus \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values k8s/monitoring/kube-prometheus-stack-values.yaml \
  --timeout 5m \
  --wait
ok "kube-prometheus-stack deployed"

# ── Step 6: Deploy Loki stack ─────────────────────────────────────────────────
log "Deploying Loki + Promtail..."
helm upgrade --install loki \
  grafana/loki-stack \
  --namespace monitoring \
  --values k8s/monitoring/loki-stack-values.yaml \
  --timeout 5m \
  --wait
ok "Loki stack deployed"

# ── Step 7: Apply PrometheusRule (alerts + recording rules) ───────────────────
log "Applying PrometheusRule (alerts and recording rules)..."
kubectl apply -f k8s/monitoring/prometheus-rules.yaml
ok "PrometheusRule applied"

# ── Step 8: Verify everything ─────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Observability stack status"
echo "════════════════════════════════════════"
kubectl get pods -n monitoring
echo ""
kubectl get svc -n monitoring | grep -E "NAME|grafana|prometheus|alertmanager|loki"
echo ""

# ── Step 9: Port-forward all UIs ─────────────────────────────────────────────
echo "════════════════════════════════════════"
echo "  Access URLs (via port-forward)"
echo "════════════════════════════════════════"
echo ""
echo "  Run these in separate terminals:"
echo ""
echo "  App:          kubectl port-forward -n app svc/cloud-lab 8888:80"
echo "  Prometheus:   kubectl port-forward -n monitoring svc/kube-prometheus-prometheus 9090:9090"
echo "  Grafana:      kubectl port-forward -n monitoring svc/kube-prometheus-grafana 3000:80"
echo "  Alertmanager: kubectl port-forward -n monitoring svc/kube-prometheus-alertmanager 9093:9093"
echo ""
echo "  Grafana login: admin / admin"
echo ""
echo "════════════════════════════════════════"
echo "  Week 2 deployment complete"
echo "════════════════════════════════════════"

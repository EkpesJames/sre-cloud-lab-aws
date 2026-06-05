#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# week6-deploy.sh — Week 6 capstone: secrets audit + documentation
# Run from the root of your cloud-sre-lab project
# ─────────────────────────────────────────────────────────────────────────────

set -e

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $1"; }

echo "════════════════════════════════════════"
echo "  Week 6 — Secrets + Documentation"
echo "════════════════════════════════════════"
echo ""

# ── Step 1: Run secrets audit ─────────────────────────────────────────────────
log "Running secrets audit..."
bash secrets-audit.sh
echo ""

# ── Step 2: Verify K8s secrets are up to date ─────────────────────────────────
log "Verifying Kubernetes secrets..."

if [[ -f .env ]]; then
  source .env

  # Recreate cloud-lab-secrets from current .env
  kubectl create secret generic cloud-lab-secrets \
    --namespace=app \
    --from-literal=SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL}" \
    --from-literal=SMTP_USERNAME="${SMTP_USERNAME}" \
    --from-literal=SMTP_PASSWORD="${SMTP_PASSWORD}" \
    --from-literal=SMTP_FROM="${SMTP_FROM}" \
    --from-literal=ALERT_EMAIL_TO="${ALERT_EMAIL_TO}" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "cloud-lab-secrets updated from .env"

  # Recreate alertmanager config secret
  envsubst < monitoring/alertmanager.yml > /tmp/alertmanager-resolved.yml
  kubectl create secret generic alertmanager-config \
    --namespace=monitoring \
    --from-file=alertmanager.yaml=/tmp/alertmanager-resolved.yml \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "alertmanager-config updated"

  # Restart alertmanager to pick up new config
  kubectl rollout restart statefulset \
    alertmanager-kube-prometheus-kube-prome-alertmanager \
    -n monitoring
  ok "Alertmanager restarted"
else
  warn "No .env file found — skipping K8s secret update"
fi

# ── Step 3: Verify GHCR secret ────────────────────────────────────────────────
log "Verifying GHCR pull secret..."
if kubectl get secret ghcr-secret -n app >/dev/null 2>&1; then
  ok "ghcr-secret exists"
else
  warn "ghcr-secret missing — creating from .env..."
  if [[ -n "${GHCR_PAT}" ]]; then
    kubectl create secret docker-registry ghcr-secret \
      --namespace=app \
      --docker-server=ghcr.io \
      --docker-username="${GHCR_USERNAME}" \
      --docker-password="${GHCR_PAT}" \
      --dry-run=client -o yaml | kubectl apply -f -
    ok "ghcr-secret created"
  else
    warn "GHCR_PAT not set in .env — skipping"
  fi
fi

# ── Step 4: Verify all pods healthy ───────────────────────────────────────────
echo ""
log "Final health check..."
kubectl get pods -n app
kubectl get pods -n monitoring
echo ""

# ── Step 5: Summary ───────────────────────────────────────────────────────────
echo "════════════════════════════════════════"
echo "  Week 6 Complete"
echo "════════════════════════════════════════"
echo ""
echo "  Documentation added:"
echo "  • docs/PRR.md              Production Readiness Review"
echo "  • docs/adr/ADR-001-*.md    Why k3s over minikube"
echo "  • docs/adr/ADR-002-*.md    Why burn rate alerting"
echo "  • docs/adr/ADR-003-*.md    Why Loki over Elasticsearch"
echo "  • secrets-audit.sh         Secrets verification tool"
echo "  • .env.example             Updated with all variables"
echo ""
echo "  Secrets managed via:"
echo "  • .env (local, gitignored)"
echo "  • Kubernetes Secrets (cluster)"
echo "  • GitHub Actions Secrets (CI/CD)"
echo "  • k3s registries.yaml (image pull)"
echo ""
echo "  Next: commit everything and push"
echo "  git add -A"
echo "  git commit -m 'feat: week 6 complete — PRR, ADRs, secrets management'"
echo "  git push origin main"
echo "════════════════════════════════════════"

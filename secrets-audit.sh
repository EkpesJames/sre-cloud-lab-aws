#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# secrets-audit.sh — audits the project for hardcoded secrets and verifies
# all credentials are properly managed via environment variables or K8s secrets
#
# Run from the root of your cloud-sre-lab project
# ─────────────────────────────────────────────────────────────────────────────

set -e

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $1"; }
fail() { echo "[$(date '+%H:%M:%S')] ✗ $1"; }

ISSUES=0

echo "════════════════════════════════════════"
echo "  Secrets Audit"
echo "  Cloud SRE Lab"
echo "════════════════════════════════════════"
echo ""

# ── Check 1: .env is not tracked by git ──────────────────────────────────────
log "Checking .env is not tracked by git..."
if git ls-files --error-unmatch .env 2>/dev/null; then
  fail ".env IS tracked by git — run: git rm --cached .env"
  ((ISSUES++))
else
  ok ".env is not tracked by git"
fi

# ── Check 2: No real secrets in committed files ───────────────────────────────
log "Scanning committed files for secret patterns..."

SECRET_PATTERNS=(
  "hooks\.slack\.com/services/[A-Z0-9]{9}/[A-Z0-9]{11}/[A-Za-z0-9]{24}"
  "smtp_auth_password:.*[a-z]{8,}"
  "password.*=.*[a-zA-Z0-9]{12,}"
  "ghp_[a-zA-Z0-9]{36}"
  "ya29\.[a-zA-Z0-9_-]+"
)

FOUND_SECRETS=false
for pattern in "${SECRET_PATTERNS[@]}"; do
  matches=$(git grep -r --no-color "$pattern" -- \
    ':!*.example' ':!*.md' ':!secrets-audit.sh' 2>/dev/null || true)
  if [[ -n "$matches" ]]; then
    fail "Potential secret found matching pattern: $pattern"
    echo "$matches" | head -5
    FOUND_SECRETS=true
    ((ISSUES++))
  fi
done

if ! $FOUND_SECRETS; then
  ok "No hardcoded secrets found in committed files"
fi

# ── Check 3: .env.example exists and has no real values ──────────────────────
log "Checking .env.example..."
if [[ -f ".env.example" ]]; then
  if grep -qE "hooks\.slack\.com/services/[A-Z]" .env.example 2>/dev/null; then
    fail ".env.example contains real Slack webhook URL"
    ((ISSUES++))
  elif grep -qE "ghp_[a-zA-Z0-9]{36}" .env.example 2>/dev/null; then
    fail ".env.example contains real GitHub PAT"
    ((ISSUES++))
  else
    ok ".env.example exists with placeholder values only"
  fi
else
  warn ".env.example not found — create one for documentation"
  ((ISSUES++))
fi

# ── Check 4: K8s secrets exist in cluster ────────────────────────────────────
log "Checking Kubernetes secrets are configured..."
if kubectl get secret cloud-lab-secrets -n app >/dev/null 2>&1; then
  ok "cloud-lab-secrets exists in app namespace"
  # Verify it has required keys
  KEYS=$(kubectl get secret cloud-lab-secrets -n app \
    -o jsonpath='{.data}' 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(' '.join(data.keys()))
" 2>/dev/null || echo "")
  log "  Keys present: $KEYS"
else
  fail "cloud-lab-secrets not found in app namespace"
  ((ISSUES++))
fi

if kubectl get secret ghcr-secret -n app >/dev/null 2>&1; then
  ok "ghcr-secret exists in app namespace"
else
  warn "ghcr-secret not found — image pulls may fail"
fi

if kubectl get secret alertmanager-config -n monitoring >/dev/null 2>&1; then
  ok "alertmanager-config exists in monitoring namespace"
else
  fail "alertmanager-config not found in monitoring namespace"
  ((ISSUES++))
fi

# ── Check 5: registries.yaml exists for k3s ──────────────────────────────────
log "Checking k3s registry credentials..."
if [[ -f "/etc/rancher/k3s/registries.yaml" ]]; then
  ok "k3s registries.yaml exists"
  # Check it has content but not print the actual token
  if sudo grep -q "username" /etc/rancher/k3s/registries.yaml 2>/dev/null; then
    ok "registries.yaml has credentials configured"
  else
    warn "registries.yaml exists but may be missing credentials"
  fi
else
  fail "/etc/rancher/k3s/registries.yaml not found"
  ((ISSUES++))
fi

# ── Check 6: GitHub Actions secrets ──────────────────────────────────────────
log "Checking .env has required variables..."
if [[ -f ".env" ]]; then
  REQUIRED_VARS=(
    "SLACK_WEBHOOK_URL"
    "SMTP_PASSWORD"
    "SMTP_USERNAME"
    "SMTP_FROM"
    "ALERT_EMAIL_TO"
  )
  for var in "${REQUIRED_VARS[@]}"; do
    if grep -q "^${var}=" .env 2>/dev/null; then
      val=$(grep "^${var}=" .env | cut -d= -f2)
      if [[ -z "$val" || "$val" == "REPLACE_ME" ]]; then
        warn "$var is empty or placeholder in .env"
      else
        ok "$var is set in .env"
      fi
    else
      warn "$var not found in .env"
    fi
  done
else
  warn ".env file not found — credentials not configured locally"
fi

# ── Check 7: alertmanager.yml uses env vars not hardcoded values ─────────────
log "Checking alertmanager.yml uses env var placeholders..."
if grep -q '\${SLACK_WEBHOOK_URL}' monitoring/alertmanager.yml 2>/dev/null; then
  ok "alertmanager.yml uses \${SLACK_WEBHOOK_URL} placeholder"
else
  fail "alertmanager.yml may have hardcoded Slack webhook"
  ((ISSUES++))
fi

if grep -q '\${SMTP_PASSWORD}' monitoring/alertmanager.yml 2>/dev/null; then
  ok "alertmanager.yml uses \${SMTP_PASSWORD} placeholder"
else
  fail "alertmanager.yml may have hardcoded SMTP password"
  ((ISSUES++))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Audit Summary"
echo "════════════════════════════════════════"
echo ""

if [[ $ISSUES -eq 0 ]]; then
  ok "All secrets checks passed — no issues found"
  echo ""
  echo "  Secrets are managed via:"
  echo "  • .env file (local, not in git)"
  echo "  • Kubernetes Secrets (cluster)"
  echo "  • GitHub Actions Secrets (CI/CD)"
  echo "  • k3s registries.yaml (image pull)"
else
  fail "$ISSUES issue(s) found — fix before pushing to GitHub"
fi

echo "════════════════════════════════════════"

#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# week5-deploy.sh — sets up chaos engineering and capacity baseline
# Run from the root of your cloud-sre-lab project
# ─────────────────────────────────────────────────────────────────────────────

set -e

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $1"; }

echo "════════════════════════════════════════"
echo "  Week 5 — Chaos Engineering"
echo "════════════════════════════════════════"
echo ""

# ── Step 1: Install Chaos Mesh ────────────────────────────────────────────────
log "Installing Chaos Mesh..."
bash install-chaos-mesh.sh
ok "Chaos Mesh installed"

# ── Step 2: Verify CRDs are ready ────────────────────────────────────────────
log "Waiting for Chaos Mesh CRDs..."
sleep 10
kubectl get crds | grep chaos-mesh.org | wc -l
ok "CRDs registered"

# ── Step 3: List available scenarios ─────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Available chaos scenarios"
echo "════════════════════════════════════════"
echo ""
echo "  1. Pod kill (rolling)     → chaos/pod-kill.yaml"
echo "     Kills one pod every 60s. Tests K8s self-healing."
echo ""
echo "  2. Network delay          → chaos/network-delay.yaml"
echo "     Adds 200ms latency. Triggers HighLatency alerts."
echo ""
echo "  3. CPU stress             → chaos/cpu-stress.yaml"
echo "     80% CPU on one pod. Tests HPA scaling."
echo ""
echo "  4. Full outage            → chaos/full-outage.yaml"
echo "     Kills ALL pods. Tests AppDown alert pipeline."
echo ""
echo "════════════════════════════════════════"
echo "  How to run a scenario"
echo "════════════════════════════════════════"
echo ""
echo "  # Apply scenario"
echo "  kubectl apply -f chaos/pod-kill.yaml"
echo ""
echo "  # Watch what happens"
echo "  kubectl get pods -n app -w"
echo ""
echo "  # Check chaos status"
echo "  kubectl get podchaos -n app"
echo ""
echo "  # Stop scenario"
echo "  kubectl delete -f chaos/pod-kill.yaml"
echo ""
echo "════════════════════════════════════════"
echo "  Capacity baseline"
echo "════════════════════════════════════════"
echo ""
echo "  Run after chaos testing:"
echo "  bash capacity-baseline.sh"
echo ""
echo "  Week 5 setup complete"
echo "════════════════════════════════════════"

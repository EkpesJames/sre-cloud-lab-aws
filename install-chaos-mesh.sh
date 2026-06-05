#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# install-chaos-mesh.sh — installs Chaos Mesh into k3s cluster
# Run from the root of your cloud-sre-lab project
# ─────────────────────────────────────────────────────────────────────────────

set -e

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $1"; }

echo "════════════════════════════════════════"
echo "  Installing Chaos Mesh"
echo "════════════════════════════════════════"
echo ""

# ── Step 1: Add Chaos Mesh Helm repo ─────────────────────────────────────────
log "Adding Chaos Mesh Helm repository..."
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update
ok "Helm repo added"

# ── Step 2: Create namespace ──────────────────────────────────────────────────
log "Creating chaos-testing namespace..."
kubectl create namespace chaos-testing --dry-run=client -o yaml | kubectl apply -f -
ok "Namespace ready"

# ── Step 3: Install Chaos Mesh ────────────────────────────────────────────────
log "Installing Chaos Mesh (this takes 2-3 minutes)..."
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-testing \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/k3s/containerd/containerd.sock \
  --timeout 5m \
  --wait
ok "Chaos Mesh installed"

# ── Step 4: Verify ────────────────────────────────────────────────────────────
echo ""
log "Verifying installation..."
kubectl get pods -n chaos-testing
echo ""

# ── Step 5: Check CRDs ───────────────────────────────────────────────────────
log "Checking Chaos Mesh CRDs..."
kubectl get crds | grep chaos-mesh.org | head -10
echo ""

echo "════════════════════════════════════════"
echo "  Chaos Mesh installed successfully"
echo "════════════════════════════════════════"
echo ""
echo "  Available chaos types:"
echo "  - PodChaos    → kill, failure, container-kill"
echo "  - NetworkChaos→ delay, loss, partition"
echo "  - StressChaos → CPU, memory stress"
echo "  - HTTPChaos   → abort, delay, replace"
echo ""
echo "  Run chaos scenarios:"
echo "  kubectl apply -f chaos/pod-kill.yaml"
echo "  kubectl apply -f chaos/network-delay.yaml"
echo "  kubectl apply -f chaos/cpu-stress.yaml"
echo ""
echo "  Stop a scenario:"
echo "  kubectl delete -f chaos/pod-kill.yaml"
echo "════════════════════════════════════════"

#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# setup-github-runner.sh
# Sets up a GitHub Actions self-hosted runner on your WSL2 machine
# This allows the deploy job to run kubectl against your local k3s cluster
#
# Run this ONCE after setting up your GitHub repo
# Prerequisites: k3s installed, kubectl working, GitHub PAT with repo scope
# ─────────────────────────────────────────────────────────────────────────────

set -e

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $1"; }

echo "════════════════════════════════════════"
echo "  GitHub Actions Runner Setup"
echo "  WSL2 + k3s self-hosted runner"
echo "════════════════════════════════════════"
echo ""

# ── Get inputs ────────────────────────────────────────────────────────────────
read -p "Enter your GitHub username: " GITHUB_USER
read -p "Enter your repo name (e.g. sre-cloud-lab): " REPO_NAME
echo ""
echo "  Get your runner token at:"
echo "  https://github.com/$GITHUB_USER/$REPO_NAME/settings/actions/runners/new"
echo "  Click: Linux → copy the token from the --token line"
echo ""
read -p "Enter your runner registration token: " RUNNER_TOKEN
echo ""

# ── Install dependencies ──────────────────────────────────────────────────────
log "Installing dependencies..."
sudo apt-get update -qq
sudo apt-get install -y curl tar libssl-dev libkrb5-dev zlib1g libicu-dev
ok "Dependencies installed"

# ── Create runner directory ───────────────────────────────────────────────────
RUNNER_DIR="$HOME/actions-runner"
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

# ── Download latest runner ────────────────────────────────────────────────────
log "Fetching latest runner version..."
RUNNER_VERSION=$(curl -s \
  https://api.github.com/repos/actions/runner/releases/latest \
  | grep '"tag_name"' \
  | cut -d'"' -f4 \
  | sed 's/v//')

log "Downloading GitHub Actions runner v${RUNNER_VERSION}..."
curl -sL -o actions-runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

tar xzf actions-runner.tar.gz
rm actions-runner.tar.gz
ok "Runner downloaded"

# ── Configure runner ──────────────────────────────────────────────────────────
log "Configuring runner..."
./config.sh \
  --url "https://github.com/$GITHUB_USER/$REPO_NAME" \
  --token "$RUNNER_TOKEN" \
  --name "wsl2-k3s-runner" \
  --labels "self-hosted,wsl2,k3s,linux" \
  --work "_work" \
  --unattended
ok "Runner configured"

# ── Ensure kubectl is available to the runner ─────────────────────────────────
log "Configuring kubectl access..."
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config 2>/dev/null || true
sudo chown $USER:$USER ~/.kube/config 2>/dev/null || true
ok "kubectl configured"

# ── Install as systemd service ────────────────────────────────────────────────
log "Installing runner as systemd service..."
sudo ./svc.sh install
sudo ./svc.sh start
ok "Runner service started"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Runner setup complete"
echo "════════════════════════════════════════"
echo ""
echo "  Runner name : wsl2-k3s-runner"
echo "  Labels      : self-hosted, wsl2, k3s, linux"
echo "  Directory   : $RUNNER_DIR"
echo ""
echo "  Check status:"
echo "  sudo $RUNNER_DIR/svc.sh status"
echo ""
echo "  View in GitHub:"
echo "  https://github.com/$GITHUB_USER/$REPO_NAME/settings/actions/runners"
echo ""
echo "  Once the runner shows as 'Idle' in GitHub,"
echo "  the deploy job will run automatically on"
echo "  every push to main."
echo "════════════════════════════════════════"

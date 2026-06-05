#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# sre-lab.sh — Master control script for Cloud SRE Lab
#
# Services:
#   API Gateway     → http://localhost:8888  (cloud-lab deployment)
#   Booking Service → http://localhost:8889
#   Payment Service → http://localhost:8890
#
# Usage:
#   ./sre-lab.sh start              Start everything
#   ./sre-lab.sh stop               Stop everything cleanly
#   ./sre-lab.sh restart            Stop then start
#   ./sre-lab.sh status             Health check all services and pods
#   ./sre-lab.sh deploy             Build and deploy all three services
#   ./sre-lab.sh logs [service]     Tail logs (gateway|booking|payment|prometheus|grafana|alertmanager|jaeger)
#   ./sre-lab.sh traffic [mode]     Generate traffic (bookings|mixed|spike|cascade|slow-burn|slo-breach)
#   ./sre-lab.sh chaos [type]       Run chaos scenario
#   ./sre-lab.sh outage [service]   Scale service to 0 (gateway|booking|payment|all)
#   ./sre-lab.sh recover [service]  Restore service after outage
#   ./sre-lab.sh book               Send one test booking through all three services
#   ./sre-lab.sh secrets            Run secrets audit
#   ./sre-lab.sh open               Print all access URLs
# ─────────────────────────────────────────────────────────────────────────────

set -e

# ── Helpers ───────────────────────────────────────────────────────────────────
log()    { echo "[$(date '+%H:%M:%S')] $1"; }
ok()     { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
warn()   { echo "[$(date '+%H:%M:%S')] ⚠ $1"; }
fail()   { echo "[$(date '+%H:%M:%S')] ✗ $1"; }
header() { echo ""; echo "════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════"; echo ""; }

# ── Port-forward management ───────────────────────────────────────────────────
start_pf() {
  local name=$1 ns=$2 svc=$3 ports=$4
  kubectl port-forward -n "$ns" "svc/$svc" $ports \
    >> "/tmp/pf-${name}.log" 2>&1 &
  echo $! > "/tmp/pf-${name}.pid"
  ok "$name → http://localhost:${ports%%:*}"
}

stop_pf() {
  local name=$1
  local pidfile="/tmp/pf-${name}.pid"
  if [[ -f "$pidfile" ]]; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
  fi
}

stop_all_pf() {
  for svc in gateway booking payment prometheus grafana alertmanager jaeger; do
    stop_pf "$svc"
  done
  pkill -f "kubectl port-forward" 2>/dev/null || true
  ok "All port-forwards stopped"
}

start_all_pf() {
  log "Starting port-forwards..."
  start_pf "gateway"      "app"        "cloud-lab"                              "8888:80"
  start_pf "booking"      "app"        "booking-service"                        "8889:80"
  start_pf "payment"      "app"        "payment-service"                        "8890:80"
  start_pf "prometheus"   "monitoring" "kube-prometheus-kube-prome-prometheus"  "9090:9090"
  start_pf "grafana"      "monitoring" "kube-prometheus-grafana"                "3000:80"
  start_pf "alertmanager" "monitoring" "kube-prometheus-kube-prome-alertmanager" "9093:9093"
  # Jaeger — use pod direct due to WSL2 service routing issue
  log "Starting Jaeger port-forward (pod direct)..."
  JAEGER_POD=$(kubectl get pod -n monitoring -l app=jaeger \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -n "$JAEGER_POD" ]]; then
    kubectl port-forward -n monitoring pod/$JAEGER_POD 16686:16686 \
      >> /tmp/pf-jaeger.log 2>&1 &
    echo $! > /tmp/pf-jaeger.pid
    ok "jaeger → http://localhost:16686"
  else
    warn "Jaeger pod not found — skipping"
  fi
  sleep 8
}

# ── Health checks ─────────────────────────────────────────────────────────────
check() {
  local name=$1 url=$2
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
  if [[ "$code" == "200" ]]; then
    ok "$name"
  else
    warn "$name (HTTP $code)"
  fi
}

run_health_checks() {
  echo ""
  echo "  Application services:"
  check "  API Gateway     → http://localhost:8888" \
    "http://localhost:8888/health/live"
  check "  Booking Service → http://localhost:8889" \
    "http://localhost:8889/health/live"
  check "  Payment Service → http://localhost:8890" \
    "http://localhost:8890/health/live"
  echo ""
  echo "  Observability:"
  check "  Prometheus      → http://localhost:9090" \
    "http://localhost:9090/-/healthy"
  check "  Grafana         → http://localhost:3000" \
    "http://localhost:3000/api/health"
  check "  Alertmanager    → http://localhost:9093" \
    "http://localhost:9093/-/healthy"
  # Jaeger needs extra time after pod direct port-forward
  local jaeger_code
  jaeger_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 "http://localhost:16686/api/services" 2>/dev/null)
  if [[ "$jaeger_code" == "200" ]]; then
    ok "  Jaeger          → http://localhost:16686"
  else
    # Retry once after 5 seconds
    sleep 5
    jaeger_code=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 5 "http://localhost:16686/api/services" 2>/dev/null)
    [[ "$jaeger_code" == "200" ]] && \
      ok "  Jaeger          → http://localhost:16686" || \
      warn "  Jaeger          → http://localhost:16686 (HTTP $jaeger_code)"
  fi
  echo ""
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_start() {
  header "Cloud SRE Lab — Starting"

  log "Starting k3s..."
  sudo systemctl start k3s
  ok "k3s started"

  log "Waiting for node..."
  until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
    echo "  ... waiting"; sleep 3
  done
  ok "Node ready"

  log "Waiting for app pods..."
  kubectl wait --for=condition=ready pod -l app=cloud-lab -n app --timeout=120s
  ok "API Gateway ready"

  kubectl wait --for=condition=ready pod -l app=booking-service -n app --timeout=120s 2>/dev/null \
    && ok "Booking Service ready" || warn "Booking Service still starting"

  kubectl wait --for=condition=ready pod -l app=payment-service -n app --timeout=120s 2>/dev/null \
    && ok "Payment Service ready" || warn "Payment Service still starting"

  log "Waiting for monitoring stack..."
  for label in \
    "app.kubernetes.io/name=prometheus" \
    "app.kubernetes.io/name=grafana" \
    "app.kubernetes.io/name=alertmanager"; do
    name=$(echo "$label" | cut -d= -f2)
    kubectl wait --for=condition=ready pod \
      -l "$label" -n monitoring \
      --timeout=120s 2>/dev/null \
      && ok "$name ready" || warn "$name still starting"
  done

  log "Waiting for Jaeger..."
  kubectl wait --for=condition=ready pod \
    -l app=jaeger -n monitoring \
    --timeout=180s 2>/dev/null \
    && ok "jaeger ready" || warn "jaeger still starting — will retry port-forward"

  stop_all_pf 2>/dev/null || true
  sleep 2
  start_all_pf
  run_health_checks
  cmd_open
}

cmd_stop() {
  header "Cloud SRE Lab — Stopping"
  pkill -f "generate-traffic" 2>/dev/null && ok "Traffic stopped" || true
  stop_all_pf
  sudo systemctl stop k3s
  ok "k3s stopped"
  echo ""
  echo "  All data preserved. Restart with: ./sre-lab.sh start"
  echo ""
}

cmd_restart() {
  cmd_stop
  sleep 3
  cmd_start
}

cmd_status() {
  header "Cloud SRE Lab — Status"

  echo "  Pods:"
  echo ""
  echo "  [app namespace]"
  kubectl get pods -n app --no-headers 2>/dev/null | \
    awk '{printf "  %-45s %s\n", $1, $3}' || warn "k3s not running"
  echo ""
  echo "  [monitoring namespace]"
  kubectl get pods -n monitoring --no-headers 2>/dev/null | \
    awk '{printf "  %-45s %s\n", $1, $3}'
  echo ""
  echo "  HPA:"
  kubectl get hpa -n app --no-headers 2>/dev/null | \
    awk '{printf "  %-30s replicas: %s/%s  cpu: %s\n", $1, $7, $6, $5}'
  echo ""
  run_health_checks
}

cmd_deploy() {
  header "Building and Deploying All Services"

  [[ -f .env ]] && export $(grep -v '^#' .env | grep -v '^$' | xargs)

  log "Building images..."
  docker build -t api-gateway:local     -f api-gateway/Dockerfile .
  ok "api-gateway built"
  docker build -t booking-service:local -f booking-service/Dockerfile .
  ok "booking-service built"
  docker build -t payment-service:local -f payment-service/Dockerfile .
  ok "payment-service built"

  log "Importing into k3s..."
  docker save api-gateway:local     | sudo k3s ctr images import -
  docker save booking-service:local | sudo k3s ctr images import -
  docker save payment-service:local | sudo k3s ctr images import -
  ok "All images imported"

  log "Applying manifests..."
  kubectl apply -f k8s/namespaces/namespaces.yaml
  kubectl apply -f k8s/gateway/configmap.yaml
  kubectl apply -f k8s/app/configmap.yaml
  kubectl apply -f k8s/booking/booking-service.yaml
  kubectl apply -f k8s/payment/payment-service.yaml
  kubectl apply -f k8s/monitoring/prometheus-rules-distributed.yaml

  # Update/create secrets
  kubectl create secret generic cloud-lab-secrets \
    --namespace=app \
    --from-literal=SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL}" \
    --from-literal=SMTP_USERNAME="${SMTP_USERNAME}" \
    --from-literal=SMTP_PASSWORD="${SMTP_PASSWORD}" \
    --from-literal=SMTP_FROM="${SMTP_FROM}" \
    --from-literal=ALERT_EMAIL_TO="${ALERT_EMAIL_TO}" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "Secrets applied"

  log "Rolling restarts..."
  kubectl set image deployment/cloud-lab cloud-lab=api-gateway:local -n app
  kubectl rollout status deployment/cloud-lab -n app --timeout=120s
  ok "API Gateway deployed"

  kubectl rollout restart deployment/booking-service -n app
  kubectl rollout status deployment/booking-service -n app --timeout=120s
  ok "Booking Service deployed"

  kubectl rollout restart deployment/payment-service -n app
  kubectl rollout status deployment/payment-service -n app --timeout=120s
  ok "Payment Service deployed"

  echo ""
  kubectl get pods -n app
}

cmd_logs() {
  local target="${2:-gateway}"
  case "$target" in
    gateway|api|api-gateway)
      kubectl logs -n app -l app=cloud-lab -f --tail=50
      ;;
    booking|booking-service)
      kubectl logs -n app -l app=booking-service -f --tail=50
      ;;
    payment|payment-service)
      kubectl logs -n app -l app=payment-service -f --tail=50
      ;;
    prometheus)
      kubectl logs -n monitoring \
        prometheus-kube-prometheus-kube-prome-prometheus-0 -f --tail=50
      ;;
    grafana)
      kubectl logs -n monitoring -l app.kubernetes.io/name=grafana \
        --container grafana -f --tail=50
      ;;
    alertmanager)
      kubectl logs -n monitoring \
        alertmanager-kube-prometheus-kube-prome-alertmanager-0 \
        --container alertmanager -f --tail=50
      ;;
    jaeger)
      kubectl logs -n monitoring -l app=jaeger -f --tail=50
      ;;
    all)
      kubectl logs -n app -l app=cloud-lab --tail=20 &
      kubectl logs -n app -l app=booking-service --tail=20 &
      kubectl logs -n app -l app=payment-service --tail=20 &
      wait
      ;;
    *)
      kubectl logs -n app "$target" -f --tail=50
      ;;
  esac
}

cmd_traffic() {
  local mode="${2:-bookings}"
  log "Starting traffic: $mode"
  bash generate-traffic.sh "$mode"
}

cmd_chaos() {
  local type="${2:-help}"
  case "$type" in
    pod-kill)
      kubectl apply -f chaos/pod-kill.yaml
      ok "Pod kill chaos running — kills one gateway pod every 60s"
      echo "  Watch: kubectl get pods -n app -w"
      echo "  Stop:  ./sre-lab.sh chaos stop"
      ;;
    network-delay)
      kubectl apply -f chaos/network-delay.yaml
      ok "Network delay — 200ms injected on gateway pods for 5 minutes"
      echo "  Watch: http://localhost:9090 → slo:api_gateway:latency_p95_5m"
      ;;
    cpu-stress)
      kubectl apply -f chaos/cpu-stress.yaml
      ok "CPU stress — 80% CPU on one pod for 3 minutes"
      echo "  Watch: kubectl top pods -n app"
      ;;
    payment-outage)
      log "Scaling payment-service to 0 — cascades to booking then gateway"
      kubectl scale deployment/payment-service -n app --replicas=0
      ok "Payment service down — watch cascade failure"
      echo "  Watch: http://localhost:9090/alerts"
      echo "  Restore: ./sre-lab.sh recover payment"
      ;;
    full-outage)
      warn "Killing ALL pods across ALL services"
      read -p "  Are you sure? (yes/no): " confirm
      [[ "$confirm" == "yes" ]] || { log "Cancelled"; exit 0; }
      kubectl apply -f chaos/full-outage.yaml
      ok "Full outage triggered — AppDown alert fires within 15s"
      ;;
    stop)
      kubectl delete podchaos --all -n app 2>/dev/null && ok "PodChaos stopped" || true
      kubectl delete networkchaos --all -n app 2>/dev/null && ok "NetworkChaos stopped" || true
      kubectl delete stresschaos --all -n app 2>/dev/null && ok "StressChaos stopped" || true
      kubectl scale deployment/payment-service -n app --replicas=2 2>/dev/null || true
      ok "All chaos stopped"
      ;;
    *)
      echo "  Usage: ./sre-lab.sh chaos [type]"
      echo ""
      echo "  Types:"
      echo "    pod-kill        Kill one gateway pod every 60s"
      echo "    network-delay   Add 200ms latency to gateway"
      echo "    cpu-stress      80% CPU stress for 3 minutes"
      echo "    payment-outage  Kill payment service — triggers cascade failure"
      echo "    full-outage     Kill all pods across all services"
      echo "    stop            Stop all running chaos"
      ;;
  esac
}

cmd_outage() {
  local svc="${2:-all}"
  case "$svc" in
    gateway)
      kubectl scale deployment/cloud-lab -n app --replicas=0
      ok "API Gateway scaled to 0 — AppDown alert fires within 15s"
      ;;
    booking)
      kubectl scale deployment/booking-service -n app --replicas=0
      ok "Booking Service scaled to 0"
      ;;
    payment)
      kubectl scale deployment/payment-service -n app --replicas=0
      ok "Payment Service scaled to 0 — booking requests will fail"
      ;;
    all)
      kubectl scale deployment/cloud-lab -n app --replicas=0
      kubectl scale deployment/booking-service -n app --replicas=0
      kubectl scale deployment/payment-service -n app --replicas=0
      ok "All services scaled to 0 — full outage"
      ;;
  esac
  echo "  Restore with: ./sre-lab.sh recover $svc"
}

cmd_recover() {
  local svc="${2:-all}"
  case "$svc" in
    gateway)
      kubectl scale deployment/cloud-lab -n app --replicas=2
      sleep 5
      kubectl wait --for=condition=ready pod \
        -l app=cloud-lab -n app --timeout=60s 2>/dev/null \
        && ok "API Gateway recovered" \
        || ok "API Gateway recovering — pods starting"
      ;;
    booking)
      kubectl scale deployment/booking-service -n app --replicas=2
      sleep 5
      kubectl wait --for=condition=ready pod \
        -l app=booking-service -n app --timeout=60s 2>/dev/null \
        && ok "Booking Service recovered" \
        || ok "Booking Service recovering — pods starting"
      ;;
    payment)
      kubectl scale deployment/payment-service -n app --replicas=2
      sleep 5
      kubectl wait --for=condition=ready pod \
        -l app=payment-service -n app --timeout=60s 2>/dev/null \
        && ok "Payment Service recovered" \
        || ok "Payment Service recovering — pods starting"
      ;;
    all)
      kubectl scale deployment/cloud-lab -n app --replicas=2
      kubectl scale deployment/booking-service -n app --replicas=2
      kubectl scale deployment/payment-service -n app --replicas=2
      sleep 5
      kubectl wait --for=condition=ready pod \
        -l app=cloud-lab -n app --timeout=60s 2>/dev/null \
        && ok "API Gateway recovered" \
        || ok "API Gateway recovering"
      kubectl wait --for=condition=ready pod \
        -l app=booking-service -n app --timeout=60s 2>/dev/null \
        && ok "Booking Service recovered" \
        || ok "Booking Service recovering"
      kubectl wait --for=condition=ready pod \
        -l app=payment-service -n app --timeout=60s 2>/dev/null \
        && ok "Payment Service recovered" \
        || ok "Payment Service recovering"
      ;;
  esac
}

cmd_book() {
  header "Test Booking — Full Distributed Flow"
  log "Sending booking request through all three services..."
  echo ""
  curl -s -X POST http://localhost:8888/book \
    -H "Content-Type: application/json" \
    -d "{\"event_type\":\"concert\",\"seats\":2}" | python3 -m json.tool
  echo ""
  log "Check trace in Jaeger: http://localhost:16686"
  log "Search service: api-gateway"
}

cmd_secrets() {
  bash secrets-audit.sh
}

cmd_open() {
  echo ""
  echo "════════════════════════════════════════"
  echo "  Access URLs"
  echo "════════════════════════════════════════"
  echo ""
  echo "  Application:"
  echo "  API Gateway     → http://localhost:8888"
  echo "  Booking Service → http://localhost:8889"
  echo "  Payment Service → http://localhost:8890"
  echo ""
  echo "  Observability:"
  echo "  Prometheus      → http://localhost:9090"
  echo "  Grafana         → http://localhost:3000  (admin/admin)"
  echo "  Alertmanager    → http://localhost:9093"
  echo "  Jaeger          → http://localhost:16686"
  echo ""
  echo "  Quick commands:"
  echo "  ./sre-lab.sh book                    Test full booking flow"
  echo "  ./sre-lab.sh traffic bookings        Generate booking traffic"
  echo "  ./sre-lab.sh traffic cascade         Simulate cascade failure"
  echo "  ./sre-lab.sh chaos payment-outage    Kill payment service"
  echo "  ./sre-lab.sh outage payment          Scale payment to 0"
  echo "  ./sre-lab.sh recover all             Restore all services"
  echo "  ./sre-lab.sh status                  Health check everything"
  echo "  ./sre-lab.sh logs booking            Tail booking service logs"
  echo "  ./sre-lab.sh stop                    Shut down cleanly"
  echo "════════════════════════════════════════"
}

# ── Entry point ───────────────────────────────────────────────────────────────
case "${1:-help}" in
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  restart)  cmd_restart ;;
  status)   cmd_status ;;
  deploy)   cmd_deploy ;;
  logs)     cmd_logs "$@" ;;
  traffic)  cmd_traffic "$@" ;;
  chaos)    cmd_chaos "$@" ;;
  outage)   cmd_outage "$@" ;;
  recover)  cmd_recover "$@" ;;
  book)     cmd_book ;;
  secrets)  cmd_secrets ;;
  open)     cmd_open ;;
  *)
    echo ""
    echo "  Cloud SRE Lab — Distributed Booking System"
    echo ""
    echo "  Services: API Gateway (8888) → Booking (8889) → Payment (8890)"
    echo ""
    echo "  Usage: ./sre-lab.sh <command> [options]"
    echo ""
    echo "  Lifecycle:"
    echo "    start                    Start k3s + all services + port-forwards"
    echo "    stop                     Stop everything cleanly"
    echo "    restart                  Stop then start"
    echo "    status                   Health check all services"
    echo "    deploy                   Build + deploy all three services"
    echo ""
    echo "  Testing:"
    echo "    book                     Send one test booking through all services"
    echo "    traffic [mode]           Generate traffic"
    echo "      modes: bookings|mixed|spike|cascade|slow-burn|slo-breach"
    echo ""
    echo "  Chaos:"
    echo "    chaos [type]             Run chaos scenario"
    echo "      types: pod-kill|network-delay|cpu-stress|payment-outage|full-outage|stop"
    echo "    outage [service]         Scale to 0 (gateway|booking|payment|all)"
    echo "    recover [service]        Restore after outage"
    echo ""
    echo "  Ops:"
    echo "    logs [service]           Tail logs (gateway|booking|payment|all|...)"
    echo "    secrets                  Run secrets audit"
    echo "    open                     Show all access URLs"
    echo ""
    ;;
esac

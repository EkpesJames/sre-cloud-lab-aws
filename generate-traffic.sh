#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# generate-traffic.sh — Traffic simulation for distributed booking system
#
# Usage:
#   ./generate-traffic.sh mixed         Realistic mixed traffic (default)
#   ./generate-traffic.sh bookings      Full booking flow: API → Booking → Payment
#   ./generate-traffic.sh normal        Steady baseline on all endpoints
#   ./generate-traffic.sh spike         Sudden burst of booking requests
#   ./generate-traffic.sh error-flood   Drive up error rates
#   ./generate-traffic.sh slow-burn     Sustained load for 5 minutes
#   ./generate-traffic.sh slo-breach    Trigger SLO breach scenario
#   ./generate-traffic.sh cascade       Simulate cascade failure scenario
# ─────────────────────────────────────────────────────────────────────────────

GATEWAY_URL="http://localhost:8888"
BOOKING_URL="http://localhost:8889"
PAYMENT_URL="http://localhost:8890"

EVENT_TYPES=("concert" "theatre" "sports" "conference" "comedy")
PAYMENT_METHODS=("card" "bank_transfer" "wallet")

log() { echo "[$(date '+%H:%M:%S')] $1"; }

# ── Single booking request through full stack ─────────────────────────────────
book() {
  local event="${EVENT_TYPES[$((RANDOM % ${#EVENT_TYPES[@]}))]}"
  local seats=$((RANDOM % 4 + 1))
  curl -s -o /dev/null -X POST "${GATEWAY_URL}/book" \
    -H "Content-Type: application/json" \
    -d "{\"event_type\":\"${event}\",\"seats\":${seats}}"
}

# ── Direct gateway hit (legacy endpoint) ─────────────────────────────────────
hit_gateway() {
  curl -s -o /dev/null "${GATEWAY_URL}/"
}

# ── Direct booking service hit ────────────────────────────────────────────────
hit_booking() {
  local event="${EVENT_TYPES[$((RANDOM % ${#EVENT_TYPES[@]}))]}"
  curl -s -o /dev/null -X POST "${BOOKING_URL}/bookings" \
    -H "Content-Type: application/json" \
    -d "{\"event_type\":\"${event}\",\"seats\":$((RANDOM % 4 + 1))}"
}

# ── Direct payment service hit ────────────────────────────────────────────────
hit_payment() {
  curl -s -o /dev/null -X POST "${PAYMENT_URL}/payments" \
    -H "Content-Type: application/json" \
    -d "{\"amount\":$((RANDOM % 200 + 20)).00,\"method\":\"card\"}"
}

# ── Traffic profiles ──────────────────────────────────────────────────────────

profile_bookings() {
  log "Profile: BOOKINGS — full booking flow for 2 minutes"
  local end=$(($(date +%s) + 120))
  while [[ $(date +%s) -lt $end ]]; do
    book &
    sleep 0.5
  done
  wait
  log "Bookings profile complete"
}

profile_normal() {
  log "Profile: NORMAL — steady traffic on all services for 2 minutes"
  local end=$(($(date +%s) + 120))
  while [[ $(date +%s) -lt $end ]]; do
    hit_gateway &
    book &
    hit_payment &
    sleep 1
  done
  wait
  log "Normal profile complete"
}

profile_spike() {
  log "Profile: SPIKE — burst of 50 concurrent booking requests"
  log "Phase 1: Baseline"
  for i in {1..10}; do book; sleep 0.2; done

  log "Phase 2: Spike — 50 concurrent bookings"
  for i in {1..50}; do book & done
  wait

  log "Phase 3: Recovery"
  for i in {1..10}; do book; sleep 0.3; done
  log "Spike profile complete"
}

profile_error_flood() {
  log "Profile: ERROR FLOOD — hitting bad endpoints to drive up error rates"
  for i in {1..30}; do
    curl -s -o /dev/null "${GATEWAY_URL}/nonexistent" &
    curl -s -o /dev/null -X POST "${BOOKING_URL}/bookings" \
      -H "Content-Type: application/json" \
      -d '{}' &
    book &
  done
  wait
  log "Error flood complete"
}

profile_slow_burn() {
  log "Profile: SLOW BURN — sustained booking traffic for 5 minutes"
  local end=$(($(date +%s) + 300))
  local count=0
  while [[ $(date +%s) -lt $end ]]; do
    book
    ((count++))
    sleep 0.3
    if (( count % 20 == 0 )); then
      log "  $count bookings sent..."
    fi
  done
  log "Slow burn complete — $count total bookings"
}

profile_slo_breach() {
  log "Profile: SLO BREACH — designed to trigger burn rate alerts"
  log "Phase 1: Establish baseline"
  for i in {1..20}; do book; sleep 0.1; done

  log "Phase 2: Overload — concurrent requests"
  for round in {1..5}; do
    for i in {1..20}; do book & done
    wait
    sleep 2
  done

  log "Phase 3: Recovery"
  for i in {1..10}; do book; sleep 0.5; done
  log "SLO breach profile complete — check Grafana burn rate panels"
}

profile_cascade() {
  log "Profile: CASCADE — simulates a cascade failure scenario"
  log "This profile shows how payment service degradation affects the full stack"
  log ""
  log "Step 1: Normal baseline across all services"
  for i in {1..15}; do book; sleep 0.2; done

  log "Step 2: Payment service stress — rapid payment requests"
  log "Watch payment-service error rate climb..."
  for i in {1..40}; do
    hit_payment &
    sleep 0.05
  done
  wait

  log "Step 3: Booking requests now hitting degraded payment service"
  log "Watch booking-service errors increase as payment calls fail..."
  for i in {1..30}; do book & done
  wait
  sleep 5

  log "Step 4: API gateway sees booking failures"
  log "Watch CascadeFailureDetected alert in Prometheus..."
  for i in {1..20}; do book; sleep 0.1; done

  log "Cascade profile complete"
  log "Check: http://localhost:9090/alerts for CascadeFailureDetected"
  log "Check: http://localhost:16686 for traces showing failure propagation"
}

profile_mixed() {
  log "Profile: MIXED — randomised realistic traffic for 3 minutes"
  local end=$(($(date +%s) + 180))
  while [[ $(date +%s) -lt $end ]]; do
    action=$((RANDOM % 5))
    case $action in
      0) book ;;
      1) hit_gateway ;;
      2) for i in {1..5}; do book & done; wait ;;
      3) sleep $((RANDOM % 4 + 1)) ;;
      4) hit_payment ;;
    esac
    sleep 0.2
  done
  log "Mixed profile complete"
}

# ── Entry point ───────────────────────────────────────────────────────────────
PROFILE="${1:-mixed}"
log "Starting traffic profile: ${PROFILE^^}"
log "Gateway:  ${GATEWAY_URL}"
log "Booking:  ${BOOKING_URL}"
log "Payment:  ${PAYMENT_URL}"
echo "────────────────────────────────────────"

case "$PROFILE" in
  bookings)    profile_bookings ;;
  normal)      profile_normal ;;
  spike)       profile_spike ;;
  error-flood) profile_error_flood ;;
  slow-burn)   profile_slow_burn ;;
  slo-breach)  profile_slo_breach ;;
  cascade)     profile_cascade ;;
  mixed)       profile_mixed ;;
  *)
    echo "Unknown profile: $PROFILE"
    echo "Usage: $0 {bookings|normal|spike|error-flood|slow-burn|slo-breach|cascade|mixed}"
    exit 1
    ;;
esac

log "Done."

# Tool Guide — Distributed Booking System

Reference for every tool and service — what it does, how to use it,
how to test it, and what a healthy result looks like.

---

## sre-lab.sh — Master control script

Single script for everything. No other scripts needed day-to-day.

```bash
./sre-lab.sh start              # Start k3s + all services + port-forwards
./sre-lab.sh stop               # Stop everything cleanly
./sre-lab.sh status             # Full health check
./sre-lab.sh book               # Send one test booking through all three services
./sre-lab.sh traffic bookings   # Generate sustained booking traffic
./sre-lab.sh logs gateway       # Tail API gateway logs
./sre-lab.sh chaos payment-outage # Kill payment service — triggers cascade
./sre-lab.sh outage payment     # Scale payment to 0
./sre-lab.sh recover all        # Restore all services
./sre-lab.sh open               # Show all URLs
```

**Healthy start output:**
```
✓ API Gateway ready
✓ Booking Service ready
✓ Payment Service ready
✓ prometheus ready
✓ grafana ready
✓ alertmanager ready
✓ jaeger ready
✓ API Gateway    → http://localhost:8888
✓ Booking Service→ http://localhost:8889
✓ Payment Service→ http://localhost:8890
```

---

## API Gateway (`gateway.py`)

**What it is:** Entry point. Routes `/book` requests to Booking Service.
Also has a legacy `/` endpoint for basic health testing.

**Port:** 8888

**Endpoints:**

| Endpoint | Method | Purpose |
|---|---|---|
| `/` | GET | Legacy endpoint — 30% error rate |
| `/book` | POST | Full booking flow — calls booking service |
| `/health/live` | GET | Liveness probe |
| `/health/ready` | GET | Readiness probe |
| `/health/circuit` | GET | Circuit breaker state |
| `/metrics` | GET | Prometheus metrics |

**How to test:**

```bash
# Liveness
curl http://localhost:8888/health/live
# Expected: {"status":"alive","service":"api-gateway"}

# Full booking flow
curl -X POST http://localhost:8888/book \
  -H "Content-Type: application/json" \
  -d '{"event_type":"concert","seats":2}'
# Expected: booking_id, payment_id, trace_id, status: confirmed

# Circuit breaker state
curl http://localhost:8888/health/circuit
# Expected: {"state":"closed",...}
```

---

## Booking Service (`booking.py`)

**What it is:** Creates booking records and calls Payment Service.
Middle tier of the distributed system.

**Port:** 8889

**Endpoints:**

| Endpoint | Method | Purpose |
|---|---|---|
| `/bookings` | POST | Create a booking (calls payment service) |
| `/health/live` | GET | Liveness probe |
| `/health/ready` | GET | Readiness probe — 503 if circuit open |
| `/health/circuit` | GET | Circuit breaker state |
| `/metrics` | GET | Prometheus metrics |

**How to test:**

```bash
# Direct booking (bypasses gateway)
curl -X POST http://localhost:8889/bookings \
  -H "Content-Type: application/json" \
  -d '{"event_type":"theatre","seats":1}'
# Expected: booking_id, payment result, trace_id

# Check circuit breaker
curl http://localhost:8889/health/circuit
```

**Key metrics:**
```promql
slo:booking_service:success_rate_5m
slo:booking_service:bookings_per_minute
```

---

## Payment Service (`payment.py`)

**What it is:** Processes payments. Strictest SLO (99.9%).
Called by Booking Service. No downstream dependencies.

**Port:** 8890

**Endpoints:**

| Endpoint | Method | Purpose |
|---|---|---|
| `/payments` | POST | Process a payment |
| `/health/live` | GET | Liveness probe |
| `/health/ready` | GET | Readiness probe |
| `/metrics` | GET | Prometheus metrics |

**How to test:**

```bash
# Direct payment (bypasses gateway and booking)
curl -X POST http://localhost:8890/payments \
  -H "Content-Type: application/json" \
  -d '{"amount":150.00,"method":"card","booking_id":"BK-TEST-001"}'
# Expected: payment_id, status: approved, trace_id

# Check SLO metrics
# Prometheus: slo:payment_service:success_rate_5m
# Expected: ~0.95 (5% error rate)
```

**Key metrics:**
```promql
slo:payment_service:success_rate_5m
slo:payment_service:payments_per_minute
slo:payment_service:revenue_per_minute
```

---

## Full distributed flow test

```bash
# One command tests everything end to end
./sre-lab.sh book
```

**Expected response:**
```json
{
  "booking_id": "BK-1234567890-1234",
  "event_type": "concert",
  "seats": 2,
  "amount": 291.03,
  "payment": {
    "payment_id": "PAY-1234567890-5678",
    "status": "approved",
    "trace_id": "b9e5260a2c44383d92ad60cc4edc508b"
  },
  "status": "confirmed",
  "trace_id": "b9e5260a2c44383d92ad60cc4edc508b"
}
```

**What to verify:**
1. `booking_id` starts with `BK-` — Booking Service ran
2. `payment_id` starts with `PAY-` — Payment Service ran
3. `trace_id` is the same in both `payment` and root — cross-service tracing working
4. Open Jaeger at `http://localhost:16686` — search `api-gateway` — find that trace ID — should show 3 services

---

## Traffic profiles

```bash
./generate-traffic.sh bookings     # Full booking flow — most realistic
./generate-traffic.sh cascade      # Stress payment → watch cascade up the chain
./generate-traffic.sh spike        # Sudden burst of 50 concurrent bookings
./generate-traffic.sh slow-burn    # Sustained load for 5 minutes
./generate-traffic.sh slo-breach   # Designed to trigger burn rate alerts
./generate-traffic.sh mixed        # Randomised across all endpoints
```

**Most useful for demos:** `bookings` for normal operation, `cascade` for showing failure propagation.

---

## Cascade failure scenario

Shows how payment degradation cascades up through all three services.

```bash
# Step 1: Start traffic
./generate-traffic.sh bookings &

# Step 2: Kill payment service
./sre-lab.sh outage payment

# Step 3: Watch cascade in Prometheus
# slo:payment_service:success_rate_5m → drops to 0
# slo:booking_service:success_rate_5m → drops (payment calls failing)
# slo:api_gateway:success_rate_5m     → drops (booking calls failing)

# Step 4: Check alerts firing
# http://localhost:9090/alerts
# PaymentServiceDown → fires first
# BookingServiceHighErrorRate → fires next
# CascadeFailureDetected → fires when both gateway and booking degraded

# Step 5: Check traces in Jaeger
# http://localhost:16686 → filter Error: true
# See payment span failing, booking span catching the error

# Step 6: Recover
./sre-lab.sh recover payment
# Watch all three services recover in Grafana
```

---

## Prometheus — per-service queries

**Success rates:**
```promql
slo:api_gateway:success_rate_5m
slo:booking_service:success_rate_5m
slo:payment_service:success_rate_5m
```

**Burn rates (critical threshold: 14.4x):**
```promql
slo:api_gateway:error_budget_burn_rate_1h
slo:booking_service:error_budget_burn_rate_1h
slo:payment_service:error_budget_burn_rate_1h
```

**Business metrics:**
```promql
slo:booking_service:bookings_per_minute
slo:payment_service:payments_per_minute
slo:payment_service:revenue_per_minute
```

---

## Jaeger — cross-service tracing

**What to look for:**

1. Go to `http://localhost:16686`
2. Select service: `api-gateway`
3. Click **Find Traces**
4. Click any trace
5. You should see **3 services** in the trace:
   - `api-gateway` — root span, calls booking
   - `booking-service` — child span, calls payment
   - `payment-service` — grandchild span, processes payment

**Finding a failed trace:**
1. Select service: `api-gateway`
2. Check **Errors only**
3. Click a failed trace
4. Look at which service's span is red — that's where the failure originated

---

## Secrets audit

```bash
./sre-lab.sh secrets
```

Checks all three services have their credentials properly managed via Kubernetes Secrets, `.env`, and k3s registry config.

---

## Complete demo sequence (15 minutes)

```bash
# 1. Start everything
./sre-lab.sh start

# 2. Show normal operation
./sre-lab.sh book
# → Show the full response with booking ID, payment ID, trace ID

# 3. Open Jaeger — find the trace
# → Show 3-service span in Jaeger

# 4. Start traffic
./generate-traffic.sh bookings &

# 5. Show Prometheus metrics (wait 2 minutes)
# → slo:payment_service:success_rate_5m
# → slo:booking_service:bookings_per_minute

# 6. Trigger cascade failure
./sre-lab.sh outage payment
# → Watch PaymentServiceDown fire in Prometheus
# → Watch cascade alerts fire
# → Show Jaeger error traces

# 7. Recover
./sre-lab.sh recover payment
# → Watch all services recover in Grafana

# 8. Run chaos
./sre-lab.sh chaos pod-kill
# → Watch pods killed and replaced in kubectl get pods -w

# 9. Stop
./sre-lab.sh chaos stop
./sre-lab.sh stop
```

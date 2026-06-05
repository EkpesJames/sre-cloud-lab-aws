# Cloud SRE Lab — Distributed Booking System

[![CI/CD Pipeline](https://github.com/EkpesJames/sre-cloud-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/EkpesJames/sre-cloud-lab/actions/workflows/ci.yml)

A production-grade SRE portfolio project demonstrating end-to-end reliability
engineering across a distributed microservices booking system — running on
Kubernetes (k3s on WSL2) with a full CI/CD pipeline.

**Author:** EJ — Quality & Reliability Engineer transitioning to SRE
**Repo:** https://github.com/EkpesJames/sre-cloud-lab

---

## What this project demonstrates

| SRE Practice | Implementation |
|---|---|
| Per-service SLOs | API Gateway 99%, Booking 99.5%, Payment 99.9% |
| Error budget burn rate | Multi-window (1h + 6h) alerts per service |
| Distributed tracing | Same trace ID across all three services in Jaeger |
| Cascade failure detection | CascadeFailureDetected alert when multiple services degrade |
| Circuit breaker | Per service — opens at 50% errors, closes after 30s |
| Retry with backoff | Exponential backoff 1s/2s/4s on all downstream calls |
| Graceful shutdown | Zero dropped requests during rolling updates |
| Chaos engineering | Chaos Mesh — pod kill, network delay, CPU stress |
| Full observability | Metrics (Prometheus) + Logs (Loki) + Traces (Jaeger) |
| CI/CD pipeline | Test + Trivy scan + GHCR push + k3s deploy + Slack notify |
| Secrets management | K8s Secrets, GitHub Actions Secrets, k3s registry config |
| Production Readiness | PRR document, Architecture Decision Records, postmortems |

---

## Architecture

```
Client
  │
  ▼
API Gateway (gateway.py)        port 8888
  │  SLO: 99.0% · p95 < 500ms
  │  Error rate: 30% (intentional for demo)
  │  Circuit breaker threshold: 50%
  │
  ▼  POST /book
Booking Service (booking.py)    port 8889
  │  SLO: 99.5% · p95 < 300ms
  │  Error rate: 10%
  │  Calls Payment Service with retry + backoff
  │
  ▼  POST /payments
Payment Service (payment.py)    port 8890
     SLO: 99.9% · p95 < 200ms
     Error rate: 5% (strictest — revenue impact)

All three services feed into:
  Prometheus + Grafana (metrics)
  Loki + Promtail (logs)
  Jaeger + OpenTelemetry (traces)
  Alertmanager → Slack + Email (alerts)
```

---

## Quick Start Guide

```bash
git clone https://github.com/EkpesJames/sre-cloud-lab.git
cd sre-cloud-lab
cp .env.example .env
nano .env                # fill in credentials
./sre-lab.sh start       # start everything
./sre-lab.sh book        # test the full booking flow
```

---

## Access URLs

| Tool | URL | Login |
|---|---|---|
| API Gateway | http://localhost:8888 | — |
| Booking Service | http://localhost:8889 | — |
| Payment Service | http://localhost:8890 | — |
| Grafana | http://localhost:3000 | admin/admin |
| Prometheus | http://localhost:9090 | — |
| Alertmanager | http://localhost:9093 | — |
| Jaeger | http://localhost:16686 | — |

---

## sre-lab.sh — Command reference

### Lifecycle
```bash
./sre-lab.sh start          # Start k3s + all pods + port-forwards + health checks
./sre-lab.sh stop           # Stop everything cleanly (data preserved)
./sre-lab.sh restart        # Stop then start
./sre-lab.sh status         # Health check all services and pods
./sre-lab.sh open           # Print all URLs and quick commands
./sre-lab.sh deploy         # Build + deploy all three services to Kubernetes
```

### Testing
```bash
./sre-lab.sh book           # Send one test booking through all three services
```

### Traffic
```bash
./sre-lab.sh traffic bookings    # Full booking flow for 2 minutes
./sre-lab.sh traffic mixed       # Randomised traffic across all endpoints
./sre-lab.sh traffic spike       # 50 concurrent booking requests
./sre-lab.sh traffic cascade     # Stress payment first — watch cascade
./sre-lab.sh traffic slow-burn   # Sustained load for 5 minutes
./sre-lab.sh traffic slo-breach  # Overload designed to trigger alerts
```

### Chaos
```bash
./sre-lab.sh chaos pod-kill        # Kill one gateway pod every 60s
./sre-lab.sh chaos network-delay   # Add 200ms latency to gateway for 5min
./sre-lab.sh chaos cpu-stress      # 80% CPU stress for 3 minutes
./sre-lab.sh chaos payment-outage  # Kill payment service — cascades up
./sre-lab.sh chaos full-outage     # Kill all pods — AppDown alert fires
./sre-lab.sh chaos stop            # Stop all running chaos
```

### Outage simulation
```bash
./sre-lab.sh outage gateway   # Scale gateway to 0
./sre-lab.sh outage booking   # Scale booking to 0
./sre-lab.sh outage payment   # Scale payment to 0
./sre-lab.sh outage all       # Scale everything to 0
./sre-lab.sh recover gateway  # Restore gateway to 2 replicas
./sre-lab.sh recover booking  # Restore booking to 2 replicas
./sre-lab.sh recover payment  # Restore payment to 2 replicas
./sre-lab.sh recover all      # Restore everything
```

### Logs
```bash
./sre-lab.sh logs gateway      # API Gateway logs
./sre-lab.sh logs booking      # Booking Service logs
./sre-lab.sh logs payment      # Payment Service logs
./sre-lab.sh logs all          # All three services
./sre-lab.sh logs prometheus   # Prometheus logs
./sre-lab.sh logs grafana      # Grafana logs
./sre-lab.sh logs alertmanager # Alertmanager logs
./sre-lab.sh logs jaeger       # Jaeger logs
```

### Utilities
```bash
./sre-lab.sh secrets    # Audit all secrets — none in git, all in K8s
```

---

## SLOs

| Service | Availability | Latency p95 | Error budget/month |
|---|---|---|---|
| API Gateway | 99.0% | < 500ms | 7h 18m |
| Booking Service | 99.5% | < 300ms | 3h 39m |
| Payment Service | 99.9% | < 200ms | 43 minutes |

---

## Alerts

| Alert | Condition | Severity |
|---|---|---|
| AppDown | Gateway unreachable | Critical |
| HighLatencyWarning | p95 > 500ms | Warning |
| HighLatencyCritical | p95 > 1000ms | Critical |
| HighErrorRateWarning | Error rate > 5% | Warning |
| HighErrorRateCritical | Error rate > 10% | Critical |
| ErrorBudgetBurnRateFast | Burn rate > 14.4x | Critical |
| BookingServiceDown | Booking unreachable | Critical |
| PaymentServiceDown | Payment unreachable | Critical |
| PaymentServiceHighErrorRate | Error rate > 1% | Critical |
| CascadeFailureDetected | Gateway + Booking both degraded | Critical |

---

## CI/CD pipeline

```
push to main
    ↓
Test  → ruff lint + 29 pytest tests
    ↓
Build → docker build ×3 + Trivy CVE scan + push to GHCR
    ↓
Deploy → k3s pull ×3 + kubectl rolling update ×3 + Slack notify
```

---

## What is next — AWS

- EKS cluster (Terraform)
- ALB Ingress Controller
- ECR for container images
- RDS for persistent booking data
- AWS Secrets Manager
- CloudWatch integration

# Production Readiness Review — Cloud Lab API

**Service:** Cloud Lab API
**Version:** 1.0.0
**Review date:** 2026-05
**Reviewer:** EJ
**Status:** ✅ Ready for production (lab environment)

---

## Purpose

A Production Readiness Review (PRR) is a structured checklist completed before
a service goes live. It ensures the team has thought through reliability,
operability, security, and observability — not just functionality. This PRR
covers the Cloud Lab API as deployed to Kubernetes via the CI/CD pipeline.

---

## 1. Service Overview

| Item | Detail |
|---|---|
| Service name | cloud-lab-api |
| Language / framework | Python 3.11 / FastAPI |
| Deployment target | Kubernetes (k3s) |
| Replicas | 2–6 (HPA managed) |
| Dependencies | None (simulated dependency for demo) |
| Data storage | None (stateless) |
| External integrations | Slack (alerts), Yahoo SMTP (alerts), GHCR (images), Jaeger (traces) |

---

## 2. Reliability

### SLOs defined
- ✅ Availability SLO: 99% success rate over 30-day rolling window
- ✅ Latency SLO: p95 < 500ms
- ✅ Error budget: 1% per month (~7h 18m equivalent)
- ✅ SLO document: `docs/SLO.md`

### Error budget policy
- ✅ Feature releases paused when budget exhausted
- ✅ Postmortem required when >25% budget consumed in single incident

### Resilience patterns
- ✅ Circuit breaker — opens at 50% error rate, half-open after 30s
- ✅ Retry with exponential backoff — 3 attempts, 1s/2s/4s backoff
- ✅ Graceful shutdown — SIGTERM handling, drains in-flight requests
- ✅ PodDisruptionBudget — minimum 2 pods always available
- ✅ HorizontalPodAutoscaler — scales 2–6 replicas on CPU

### Chaos testing completed
- ✅ Pod kill — Kubernetes self-healing validated (18s recovery)
- ✅ Network delay — HighLatency alert confirmed firing
- ✅ CPU stress — HPA scaling behaviour observed
- ✅ Full outage — AppDown alert and Slack notification confirmed

### Capacity baseline
- ✅ Load test completed — see `docs/capacity-baseline-results.md`

---

## 3. Observability

### Metrics
- ✅ Prometheus scraping all pods via service discovery
- ✅ Recording rules pre-computing SLIs (success rate, latency percentiles)
- ✅ Error budget burn rate calculated (1h and 6h windows)
- ✅ Circuit breaker state exposed as metric
- ✅ kube-state-metrics — Kubernetes object health
- ✅ Grafana SRE dashboard — 9 panels, committed as code

### Logs
- ✅ Structured JSON logging — timestamp, level, message, trace_id
- ✅ Loki collecting logs from all pods via Promtail DaemonSet
- ✅ Logs queryable in Grafana alongside metrics

### Traces
- ✅ OpenTelemetry SDK instrumented
- ✅ Trace ID in every request response and log line
- ✅ Jaeger receiving and displaying traces
- ✅ Error traces filterable in Jaeger UI

### Alerting
- ✅ AppDown — critical, routes to Slack
- ✅ HighLatencyWarning — warning, routes to email
- ✅ HighLatencyCritical — critical, routes to Slack
- ✅ HighErrorRateWarning — warning, routes to email
- ✅ HighErrorRateCritical — critical, routes to Slack
- ✅ ErrorBudgetBurnRateFast — critical, 14.4x threshold
- ✅ ErrorBudgetBurnRateSlow — warning, 6x threshold
- ✅ All alerts tested and confirmed firing

---

## 4. Operability

### Runbooks
- ✅ AppDown — `runbooks/AppDown.md`
- ✅ HighLatency — `runbooks/HighLatency.md`
- ✅ HighErrorRate — `runbooks/HighErrorRate.md`
- ⚠️ ErrorBudget — `runbooks/ErrorBudget.md` (to be written)

### Health endpoints
- ✅ `/health/live` — liveness probe (K8s restarts on failure)
- ✅ `/health/ready` — readiness probe (K8s removes from LB on failure)
- ✅ `/health/circuit` — circuit breaker state
- ✅ `/metrics` — Prometheus metrics

### Deployment
- ✅ Rolling update strategy — maxUnavailable: 1, maxSurge: 1
- ✅ CI/CD pipeline — push to main triggers test → build → scan → deploy
- ✅ Trivy image scanning — blocks on CRITICAL CVEs
- ✅ Automated rollout verification — `kubectl rollout status`
- ✅ Slack deployment notifications — success and failure

### Postmortems
- ✅ Template: `docs/postmortem-template.md`
- ✅ Postmortem #1: `docs/postmortem-pod-kill.md`
- ✅ Postmortem #2: `docs/postmortem-network-delay.md`

---

## 5. Security

### Secrets management
- ✅ No secrets committed to git
- ✅ `.env` in `.gitignore`
- ✅ `.env.example` with placeholders committed
- ✅ Credentials in Kubernetes Secrets
- ✅ GHCR credentials in k3s registries.yaml
- ✅ CI/CD credentials in GitHub Actions Secrets
- ✅ `secrets-audit.sh` for verification

### Container hardening
- ✅ Non-root user (UID 1000)
- ✅ Read-only root filesystem
- ✅ No privilege escalation
- ✅ All capabilities dropped
- ✅ Writable /tmp via emptyDir volume

### Network
- ⚠️ NetworkPolicy not implemented (WSL2 limitation — add for cloud deployment)
- ✅ Services use ClusterIP internally
- ✅ No sensitive ports exposed externally

### Image security
- ✅ Trivy scanning in CI pipeline
- ✅ Base image: python:3.11-slim (minimal attack surface)
- ✅ Image tagged with git SHA for traceability

---

## 6. Known limitations (WSL2)

These are intentional trade-offs for local lab operation:

| Limitation | Reason | Production equivalent |
|---|---|---|
| node-exporter disabled | Host path mount restriction | Enable on real Linux nodes |
| Per-pod circuit breaker | No shared cache | Redis or distributed state |
| In-memory Jaeger storage | Resets on pod restart | Persistent backend (Cassandra/ES) |
| NetworkPolicy not enforced | WSL2 CNI limitation | Full enforcement on cloud |
| Single-node cluster | Local lab only | Multi-node with zone affinity |

---

## 7. Open action items

| Item | Priority | Owner | Due |
|---|---|---|---|
| Write ErrorBudget runbook | Medium | EJ | 2026-06 |
| Add NetworkPolicy manifests | Low | EJ | Cloud deployment |
| Add pod restart rate alert | Medium | EJ | 2026-06 |
| Implement Redis for shared circuit breaker state | Low | EJ | Future |
| Add Terraform for cloud deployment | Low | EJ | Future |

---

## Sign-off

This service meets production readiness standards for a lab environment.
The following conditions must be met before deploying to a real production
environment:

- [ ] NetworkPolicy implemented and tested
- [ ] Multi-node cluster with pod anti-affinity rules
- [ ] Persistent storage for Jaeger traces
- [ ] Redis for distributed circuit breaker state
- [ ] Terraform IaC for reproducible cloud infrastructure
- [ ] On-call rotation configured in Grafana OnCall or PagerDuty
- [ ] Load testing at production traffic volumes

**Reviewed by:** EJ
**Date:** 2026-05

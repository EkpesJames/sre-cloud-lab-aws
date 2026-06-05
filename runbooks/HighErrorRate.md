# Runbook: HighErrorRate

**Alerts:** `HighErrorRateWarning` / `HighErrorRateCritical`
**Severity:** Warning (>5% errors) / Critical (>10% errors)
**Team:** Platform
**Last reviewed:** 2026-05
**Prometheus expressions:**
- Warning: `slo:error_rate_5m > 0.05`
- Critical: `slo:error_rate_5m > 0.10`

---

## What this alert means

More than 5% (warning) or 10% (critical) of requests are returning errors
over the last 5 minutes. The availability SLO target is 99% success rate —
a 5% error rate means you are already 5x over your allowed failure rate.

At 10% errors the circuit breaker may trip open (threshold: 50% per pod),
causing cascading 503s and accelerating error budget consumption.

---

## Immediate impact

| Alert | SLO status | Budget burn |
|---|---|---|
| Warning (>5%) | Breaching — 5x over budget | Elevated |
| Critical (>10%) | Actively breaching — 10x over budget | Rapid |

---

## Diagnosis steps

### Step 1 — Confirm and quantify

In Prometheus (`http://localhost:9090`):

```promql
# Overall error rate
slo:error_rate_5m

# Per-pod error rate breakdown
rate(http_requests_total{status="error"}[5m]) by (pod)
/
rate(http_requests_total[5m]) by (pod)

# Raw error count per pod
rate(http_requests_total{status="error"}[5m]) by (pod)
```

Is the error rate elevated on all pods or just one? If just one → likely a
pod-specific issue. If all → likely a code change or shared dependency.

---

### Step 2 — Check circuit breaker state

```bash
curl http://localhost:8888/health/circuit
```

If `state: open` — the error rate tripped the circuit breaker (>50% errors
on that pod). The circuit breaker is now rejecting all requests with 503,
which will show as `status="rejected"` in metrics, not `status="error"`.

```promql
# Check for rejected requests
rate(http_requests_total{status="rejected"}[5m]) by (pod)
```

If the circuit breaker is open, focus on fixing the root cause of errors
rather than the circuit breaker itself — it will close automatically once
the error rate recovers.

---

### Step 3 — Check pod logs

```bash
# Errors from all app pods
kubectl logs -n app -l app=cloud-lab --tail=50 | grep "error\|ERROR\|exception"

# Logs from a specific pod
kubectl logs -n app <pod-name> --tail=50

# Follow logs in real time
kubectl logs -n app -l app=cloud-lab -f
```

Look for: Python exceptions, dependency failures, memory errors, timeouts.

---

### Step 4 — Check recent deployments

A bad deployment is the most common cause of a sudden error rate spike:

```bash
kubectl rollout history deployment/cloud-lab -n app
```

If a recent rollout coincides with the error spike:
```bash
# Roll back immediately
kubectl rollout undo deployment/cloud-lab -n app
kubectl rollout status deployment/cloud-lab -n app

# Confirm error rate dropping
# Prometheus query: slo:error_rate_5m
```

---

### Step 5 — Check dependency health

```bash
# Is the simulated dependency healthy?
curl http://localhost:8888/health/ready

# Restore if broken (lab simulation)
curl http://localhost:8888/health/dependency/restore
```

In production, check the health of real downstream dependencies —
databases, external APIs, message queues.

---

### Step 6 — Check traces for error patterns

Open Jaeger at `http://localhost:16686`:
- Select `cloud-lab-api` service
- Filter by `Error: true`
- Look for patterns — same endpoint, same pod, same time window

This reveals whether errors are from a specific code path or evenly
distributed.

---

### Step 7 — Check resource pressure

Memory pressure can cause intermittent failures:

```bash
kubectl top pods -n app
kubectl describe pod -n app <pod-name> | grep -A5 "Limits"
```

If memory is near the limit (128Mi), pods may be getting OOMKilled between
restarts, causing intermittent errors.

---

## Mitigation options

| Cause | Mitigation |
|---|---|
| Bad deployment | `kubectl rollout undo deployment/cloud-lab -n app` |
| Dependency down | Fix dependency, restore health probe |
| Memory pressure | Increase memory limit, scale up replicas |
| Traffic overload | Scale up: `kubectl scale deployment cloud-lab -n app --replicas=4` |
| Circuit breaker open | Fix root errors — breaker closes automatically |
| Single bad pod | `kubectl delete pod -n app <pod-name>` |

---

## Post-incident checklist

- [ ] `slo:error_rate_5m` below 1% for 5+ minutes
- [ ] Circuit breaker state is `closed` on all pods
- [ ] `curl http://localhost:8888/health/ready` returns 200
- [ ] HighErrorRate alerts resolved in Alertmanager
- [ ] Slack resolved notification received
- [ ] Grafana error panel showing green
- [ ] Error budget burn rate returning to normal
- [ ] Root cause identified and documented

---

## Error budget context

With a 99% SLO target, 1% of requests may fail per month.

| Error rate | Budget exhausted in |
|---|---|
| 1% | 30 days (sustainable) |
| 5% | 6 days |
| 10% | 3 days |
| 30% (lab default) | 1 day |

At 10% errors for more than 3 days, the monthly error budget is exhausted
and feature releases should be paused until reliability is restored.

---

## Write a postmortem if

- Error rate exceeded 10% for more than 5 minutes
- Circuit breaker tripped open
- A deployment caused the error spike
- Error budget consumed more than 25% in a single incident

Use the template at `docs/postmortem-template.md`.

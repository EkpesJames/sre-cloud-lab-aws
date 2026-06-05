# Runbook: HighLatency

**Alerts:** `HighLatencyWarning` / `HighLatencyCritical`
**Severity:** Warning (p95 > 500ms) / Critical (p95 > 1000ms)
**Team:** Platform
**Last reviewed:** 2026-05
**Prometheus expressions:**
- Warning: `slo:latency_p95_5m > 0.5`
- Critical: `slo:latency_p95_5m > 1.0`

---

## What this alert means

The 95th percentile response time has exceeded the SLO threshold. This means
at least 5% of your users are experiencing slow responses. At the critical
threshold, 1 in 20 users is waiting more than 1 second per request.

The latency SLO is: **p95 < 500ms**.

---

## Immediate impact

| Alert | User impact | Error budget |
|---|---|---|
| Warning (>500ms) | 5% of users experiencing slow responses | Consuming elevated |
| Critical (>1000ms) | 5% of users waiting 1s+ per request | Burning rapidly |

---

## Diagnosis steps

### Step 1 — Confirm and quantify

In Prometheus (`http://localhost:9090`), run these queries:

```promql
# Current p50, p95, p99 latency
slo:latency_p50_5m
slo:latency_p95_5m
slo:latency_p99_5m

# Per-pod latency breakdown
histogram_quantile(0.95,
  rate(http_request_duration_seconds_bucket[5m])
) by (pod)
```

Is the latency elevated on all pods or just one? If just one → likely a
resource issue on that specific pod. If all → upstream cause.

---

### Step 2 — Check resource usage

```bash
# CPU and memory across all app pods
kubectl top pods -n app

# Node-level resources
kubectl top nodes
```

High CPU usage causes request queuing, which directly increases latency.

If CPU is above 80% on a pod:
```bash
# Check if HPA is scaling up
kubectl get hpa -n app

# HPA should be adding pods — watch it
kubectl get pods -n app -w
```

If HPA isn't scaling, check if it has reached maxReplicas (6):
```bash
kubectl describe hpa cloud-lab-hpa -n app
```

---

### Step 3 — Check circuit breaker state

```bash
curl http://localhost:8888/health/circuit
```

If the circuit breaker is `open`, requests are being rejected with 503 and
retried — this creates artificial latency spikes. Wait for it to close or
investigate the underlying error rate that tripped it.

---

### Step 4 — Check for traffic spike

```bash
# Current request rate
# Prometheus query: slo:request_rate_5m
```

If request rate spiked sharply, the HPA may not have scaled fast enough.
The HPA has a 30-second stabilisation window before scaling up.

```bash
# Check HPA events
kubectl describe hpa cloud-lab-hpa -n app | grep -A20 "Events:"
```

---

### Step 5 — Check traces in Jaeger

Open `http://localhost:16686`, select `cloud-lab-api` service, and filter
for slow traces (set minimum duration to 500ms).

Look for:
- Which specific operation is slow
- Whether the latency is in the app code or in a downstream call
- Whether slow traces correlate with specific pods

---

### Step 6 — Check recent deployments

A code change may have introduced a slow operation:

```bash
kubectl rollout history deployment/cloud-lab -n app
```

If a recent deployment coincides with the latency spike:
```bash
# Roll back to previous version
kubectl rollout undo deployment/cloud-lab -n app
kubectl rollout status deployment/cloud-lab -n app
```

---

## Mitigation options

| Cause | Mitigation |
|---|---|
| CPU saturation | Wait for HPA to scale, or manually increase replicas |
| Traffic spike | `kubectl scale deployment cloud-lab -n app --replicas=4` |
| Slow code path | Roll back the recent deployment |
| Circuit breaker churn | Investigate error rate, fix root cause |
| Single slow pod | Delete the pod — K8s will replace it |

```bash
# Manually scale up immediately if HPA is too slow
kubectl scale deployment cloud-lab -n app --replicas=4

# Delete a single problematic pod
kubectl delete pod -n app <pod-name>
```

---

## Post-incident checklist

- [ ] `slo:latency_p95_5m` returned below 500ms for 5+ minutes
- [ ] HighLatency alerts resolved in Alertmanager
- [ ] HPA replica count returned to normal (2)
- [ ] Grafana latency panel showing green
- [ ] Root cause identified (traffic, resource, code, dependency)

---

## Write a postmortem if

- p95 latency exceeded 1 second for more than 5 minutes
- A code change caused the latency regression
- HPA failed to scale in time

Use the template at `docs/postmortem-template.md`.

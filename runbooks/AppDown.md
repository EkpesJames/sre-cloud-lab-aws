# Runbook: AppDown

**Alert:** `AppDown`
**Severity:** Critical
**Team:** Platform
**Last reviewed:** 2026-05
**Prometheus expression:** `up{service="cloud-lab-api"} == 0`

---

## What this alert means

Prometheus cannot scrape the `/metrics` endpoint on one or more `cloud-lab` pods.
The pod is either crashed, failing its readiness probe, or has been evicted by
Kubernetes. Every second this fires, error budget is consumed at maximum rate.

---

## Immediate impact

| Area | Impact |
|---|---|
| Availability SLO | Actively breaching — 99% target |
| Error budget | Burning at maximum rate |
| Users | Requests failing or being routed to remaining healthy pods |
| Circuit breaker | May trip open if error rate exceeds 50% on surviving pods |

---

## Diagnosis steps

Work through these in order. Stop when you find the cause.

### Step 1 — Confirm the alert is real

```bash
# Check if the app responds at all
curl -v http://localhost:8888/health/live
curl -v http://localhost:8888/health/ready

# Check circuit breaker state
curl http://localhost:8888/health/circuit
```

If liveness returns 200 but readiness returns 503 — the app is alive but not
ready. Check the readiness reason (dependency or circuit breaker). Go to Step 4.

If both fail — the pod is genuinely down. Continue to Step 2.

---

### Step 2 — Check pod state in Kubernetes

```bash
# See all app pods and their status
kubectl get pods -n app -o wide

# Watch for changes in real time
kubectl get pods -n app -w
```

| Pod status | Meaning | Next step |
|---|---|---|
| `Running` but not ready | Readiness probe failing | Step 4 |
| `CrashLoopBackOff` | App crashing repeatedly | Step 3 |
| `OOMKilled` | Out of memory | Step 5 |
| `Pending` | Can't be scheduled | Step 6 |
| `Terminating` | Pod being removed | Wait and observe |

---

### Step 3 — App crashing (CrashLoopBackOff)

```bash
# Get logs from the crashing pod
kubectl logs -n app <pod-name> --previous --tail=50

# Get logs from currently running container
kubectl logs -n app <pod-name> --tail=50

# Get full pod details including events
kubectl describe pod -n app <pod-name>
```

Look for: Python tracebacks, port binding errors, missing environment variables,
failed imports.

Check if a recent deployment caused it:
```bash
kubectl rollout history deployment/cloud-lab -n app
```

Roll back if needed:
```bash
kubectl rollout undo deployment/cloud-lab -n app
kubectl rollout status deployment/cloud-lab -n app
```

---

### Step 4 — Readiness probe failing

```bash
# Check readiness response directly
curl http://localhost:8888/health/ready

# Check circuit breaker state
curl http://localhost:8888/health/circuit
```

**If circuit breaker is open:**
The error rate exceeded 50%. Wait 30 seconds for half-open state. If it
doesn't recover automatically, check the underlying error source:
```bash
# Check error rate in Prometheus
# Query: slo:error_rate_5m
kubectl port-forward -n monitoring \
  svc/kube-prometheus-kube-prome-prometheus 9090:9090 &
```

**If dependency is unhealthy:**
```bash
# Restore the dependency (lab simulation)
curl http://localhost:8888/health/dependency/restore
```

---

### Step 5 — OOMKilled (out of memory)

```bash
kubectl describe pod -n app <pod-name> | grep -A5 "OOMKilled"

# Check current memory usage across pods
kubectl top pods -n app
```

Temporary fix — restart the pod:
```bash
kubectl delete pod -n app <pod-name>
```

Permanent fix — increase memory limit in `k8s/app/deployment.yaml`:
```yaml
resources:
  limits:
    memory: "256Mi"   # increase from 128Mi
```

Then apply:
```bash
kubectl apply -f k8s/app/deployment.yaml
kubectl rollout status deployment/cloud-lab -n app
```

---

### Step 6 — Pod stuck in Pending

```bash
kubectl describe pod -n app <pod-name> | grep -A10 "Events:"
```

Common causes:
- Insufficient CPU/memory on node
- Node not ready
- Image pull failure

Check node status:
```bash
kubectl get nodes
kubectl describe node <node-name> | grep -A10 "Conditions:"
```

---

### Step 7 — Prometheus scrape issue (app up but alert firing)

If the app responds but Prometheus still shows `up == 0`:

```bash
# Check Prometheus targets
curl -s http://localhost:9090/api/v1/targets | \
  python3 -m json.tool | grep -A10 "cloud-lab-app"

# Check pod annotations are correct
kubectl get pod -n app <pod-name> -o yaml | grep -A5 "annotations"
```

Pod must have these annotations for Prometheus service discovery:
```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "80"
prometheus.io/path: "/metrics"
```

---

## Recovery steps

```bash
# Scale up if replicas dropped to zero
kubectl scale deployment cloud-lab -n app --replicas=2

# Force restart all pods
kubectl rollout restart deployment/cloud-lab -n app

# Watch recovery
kubectl rollout status deployment/cloud-lab -n app

# Verify health
curl http://localhost:8888/health/live
curl http://localhost:8888/health/ready
curl http://localhost:8888/health/circuit
```

---

## Post-incident checklist

- [ ] All pods show `Running` and `1/1 Ready`
- [ ] `curl http://localhost:8888/health/live` returns 200
- [ ] `curl http://localhost:8888/health/ready` returns 200
- [ ] Circuit breaker state is `closed`
- [ ] Prometheus shows `up{service="cloud-lab-api"} == 1` for all pods
- [ ] AppDown alert resolved in Alertmanager (`http://localhost:9093`)
- [ ] Grafana availability panel returning to green
- [ ] Error budget burn rate returning to normal
- [ ] Slack resolved notification received

---

## Escalation

| Time elapsed | Action |
|---|---|
| 0–5 minutes | Follow this runbook |
| 5–15 minutes | Escalate to platform team lead |
| 15+ minutes | Escalate to service owner, consider rollback |

---

## Write a postmortem if

- Outage lasted more than 5 minutes
- Root cause was not immediately obvious
- A code or configuration change preceded the outage
- The PodDisruptionBudget was violated

Use the template at `docs/postmortem-template.md`.

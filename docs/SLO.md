# Service Level Objectives

**Service:** Cloud Lab API
**Last reviewed:** 2026-05

---

## SLO 1 — Availability

| Item | Value |
|---|---|
| Target | 99% of requests succeed |
| Measurement | Rolling 30-day window |
| Error budget | 1% of requests may fail (~7h 18m per month) |

**PromQL — check current availability:**
```promql
slo:success_rate_5m
```

**What 99% means in practice:**

| Period | Allowed failures |
|---|---|
| Per day | 1% of daily requests |
| Per week | 1% of weekly requests |
| Per month | 1% — approximately 7 hours of downtime equivalent |

---

## SLO 2 — Latency

| Item | Value |
|---|---|
| Target | 95% of requests complete in under 500ms |
| Stretch | 99% of requests complete in under 1000ms |
| Measurement | 5-minute rolling window |

**PromQL — check current latency:**
```promql
slo:latency_p95_5m
```

---

## Error budget burn rate

Burn rate measures how fast the error budget is being consumed.

| Burn rate | Meaning | Action |
|---|---|---|
| < 1x | Sustainable — budget refilling | Normal operations |
| 1–6x | Elevated — monitor | Review recent changes |
| 6–14.4x | High — budget at risk | Investigate immediately |
| > 14.4x | Critical — budget exhausted in < 2h | Page on-call now |

**PromQL — check burn rates:**
```promql
slo:error_budget_burn_rate_1h   # fast burn (1h window)
slo:error_budget_burn_rate_6h   # slow burn (6h window)
```

**Why 14.4x is the critical threshold:**
30 days × 24 hours = 720 hours. 720 ÷ 2 hours = 360. 360 ÷ 25 = 14.4.
A burn rate of 14.4x means the entire monthly budget is exhausted in 2 hours.

---

## Lab values

The lab intentionally runs at high error rates for demo purposes:

| Metric | Lab value | Production target |
|---|---|---|
| Error rate | ~30% | < 1% |
| Burn rate | ~30x | < 1x |
| Availability | ~70% | > 99% |

This means the error budget panels in Grafana will always show "exhausted"
in the lab. This is correct and intentional — it gives realistic data to
observe and explain.

---

## What happens when budget is exhausted

1. Feature releases are paused
2. Engineering focus shifts to reliability work
3. A postmortem is required for the contributing incident
4. SLO targets are reviewed at next monthly review

# Postmortem: Latency SLO Breach During Network Delay Chaos Test

**Date:** 2026-05
**Duration:** 5 minutes (intentional chaos duration)
**Severity:** High (SLO breach — p95 latency exceeded 500ms threshold)
**Author:** EJ
**Status:** Closed
**Scenario:** Chaos Mesh NetworkChaos — 200ms delay injected on all pods

---

## Summary

During chaos engineering testing, Chaos Mesh injected 200ms of artificial
network latency on all `cloud-lab` pods for 5 minutes. Combined with the app's
built-in 200ms processing delay, total p95 latency reached approximately 420ms
— approaching but not breaching the 500ms SLO threshold under normal load.
Under sustained traffic from `generate-traffic.sh spike`, p95 climbed to 680ms,
triggering the `HighLatencyWarning` alert. The circuit breaker did not open as
error rate remained below the 50% threshold. Full recovery occurred within
30 seconds of chaos removal.

---

## Impact

| Area | Detail |
|---|---|
| Duration | 5 minutes (intentional) |
| Peak p95 latency | 680ms (SLO target: 500ms) |
| SLO breach | Yes — latency SLO breached for ~3 minutes |
| Error budget consumed | ~8% of monthly budget |
| Alert fired | HighLatencyWarning (warning severity) |
| Slack notification | Received within 70 seconds of breach |
| Circuit breaker | Remained closed — error rate unaffected |

---

## Timeline

| Time | Event |
|---|---|
| 00:00 | `kubectl apply -f chaos/network-delay.yaml` — 200ms delay injected |
| 00:15 | `./generate-traffic.sh spike` started — load increased |
| 00:45 | p95 latency climbed to 420ms — approaching SLO threshold |
| 01:10 | p95 latency exceeded 500ms — `HighLatencyWarning` entered pending state |
| 02:10 | `HighLatencyWarning` fired (1 minute `for` window elapsed) |
| 02:40 | Slack warning notification received |
| 05:00 | Chaos Mesh duration elapsed — network delay removed automatically |
| 05:20 | p95 latency dropped to 210ms — within SLO |
| 05:50 | `HighLatencyWarning` resolved — Slack resolved notification received |

---

## Root cause

Intentional fault injection via Chaos Mesh NetworkChaos. The 200ms injected
delay combined with the app's 200ms built-in processing time created a baseline
of ~400ms. Under concurrent load the queuing effect pushed p95 above 500ms.

---

## What went well

- `HighLatencyWarning` alert fired correctly after 1 minute sustained breach
- Slack notification arrived within 70 seconds of alert firing
- Alert resolved automatically and Slack received resolved notification
- Circuit breaker correctly remained closed — latency increase alone does not
  indicate errors, and the breaker only responds to error rate
- Grafana latency percentile panel clearly showed all three lines (p50/p95/p99)
  climbing and recovering — excellent visual evidence of the scenario

---

## What could be improved

- The alert `for: 1m` window means 1 minute of SLO breach before notification.
  For production, a faster burn rate alert would catch this sooner — the
  `ErrorBudgetBurnRateFast` alert at 14.4x burn rate would fire faster
- No automated mitigation was triggered — in production, a latency SLO breach
  should trigger automatic scaling via KEDA or a custom HPA metric based on
  p95 latency rather than CPU

---

## Action items

| Action | Owner | Due | Status |
|---|---|---|---|
| Investigate latency-based HPA scaling | EJ | 2026-06 | Open |
| Add p99 latency alert at 2000ms as critical | EJ | 2026-06 | Open |
| Document network delay scenario in runbook | EJ | 2026-06 | Open |

---

## Lessons learned

Network latency and processing latency are additive. A service with 200ms
processing time has very little headroom before the 500ms SLO is breached under
any additional network degradation. The SLO target may need to be reviewed if
the service is deployed across regions where network latency is inherently higher.

The multi-window burn rate alerting (1h and 6h) did not fire during this test
because the incident was too short to significantly impact the 1h window. This
is correct behaviour — short incidents should not burn monthly budget at the
same rate as sustained outages.

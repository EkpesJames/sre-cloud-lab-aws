# Postmortem: Intermittent Pod Failures During Chaos Test

**Date:** 2026-05
**Duration:** ~60 seconds per cycle
**Severity:** Medium (automated recovery, no sustained outage)
**Author:** EJ
**Status:** Closed
**Scenario:** Chaos Mesh PodChaos — pod-kill, one pod every 60 seconds

---

## Summary

During scheduled chaos engineering testing, Chaos Mesh was configured to kill
one `cloud-lab` pod every 60 seconds. Each kill triggered a brief availability
dip as Kubernetes replaced the terminated pod. The PodDisruptionBudget
successfully maintained a minimum of one healthy pod throughout, preventing a
full outage. The AppDown alert did not fire because at least one pod remained
available. Recovery time per cycle averaged 18 seconds from kill to replacement
pod passing readiness probe.

---

## Impact

| Area | Detail |
|---|---|
| Duration per cycle | ~18 seconds recovery time |
| Availability impact | ~2-3% of requests failed per cycle |
| Error budget consumed | ~15% of monthly budget across full test |
| Alert fired | None — PDB maintained minimum availability |
| Users affected | Partial — some requests routed to surviving pod |

---

## Timeline

| Time | Event |
|---|---|
| 00:00 | `kubectl apply -f chaos/pod-kill.yaml` — chaos started |
| 00:01 | First pod killed — `cloud-lab-fc869786f-2mst4` terminated |
| 00:01 | Kubernetes scheduler detected pod failure |
| 00:03 | Replacement pod `cloud-lab-fc869786f-xk9p2` started |
| 00:15 | Replacement pod passed liveness probe |
| 00:18 | Replacement pod passed readiness probe — traffic restored |
| 01:01 | Second pod killed — cycle repeated |
| 05:00 | `kubectl delete -f chaos/pod-kill.yaml` — chaos stopped |
| 05:18 | All pods stable, error rate returned to baseline |

---

## Root cause

Intentional fault injection via Chaos Mesh PodChaos. Not an unplanned incident.
The purpose was to validate Kubernetes self-healing, PodDisruptionBudget
enforcement, and alert pipeline behaviour under pod failure conditions.

---

## What went well

- Kubernetes replaced killed pods automatically within 18 seconds
- PodDisruptionBudget prevented both pods being killed simultaneously
- Traffic was routed to the surviving pod during replacement
- No AppDown alert fired — the system remained partially available throughout
- Prometheus accurately tracked the brief availability dips
- Grafana dashboard showed clear dips and recoveries on the availability panel

---

## What could be improved

- Recovery time of 18 seconds is acceptable but could be reduced by pre-pulling
  the container image on the node (already present via containerd import)
- Startup probe `failureThreshold: 6` gives 30 seconds maximum startup — could
  be tightened to 20 seconds to fail faster on genuine startup issues
- No alert fired during the test — consider adding an alert for pod restart
  rate exceeding N restarts per hour as an early warning signal

---

## Action items

| Action | Owner | Due | Status |
|---|---|---|---|
| Add pod restart rate alert to alerts.yml | EJ | 2026-06 | Open |
| Reduce startup probe failureThreshold from 6 to 4 | EJ | 2026-06 | Open |
| Run pod-kill chaos monthly as part of reliability review | EJ | Ongoing | Open |

---

## Lessons learned

The PodDisruptionBudget is working exactly as designed — it is the most
important reliability control for this deployment pattern. Without it, Chaos
Mesh could have killed both pods simultaneously, causing a full outage.

The 18-second recovery time sets a concrete baseline. Any future change that
increases this time (larger image, slower startup) should be treated as a
reliability regression.

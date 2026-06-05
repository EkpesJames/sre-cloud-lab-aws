# ADR-002: Use multi-window burn rate alerting over simple threshold alerting

**Date:** 2026-05
**Status:** Accepted
**Author:** EJ

---

## Context

The alerting strategy needed to detect SLO breaches in a way that is:
- Fast enough to catch serious incidents before too much error budget is consumed
- Slow enough to avoid false positives from brief, self-recovering spikes
- Sensitive to both sudden outages and slow degradation over time

Two approaches were considered:

**Simple threshold alerting:** Fire when error rate exceeds X% for Y minutes.
Example: `error_rate > 5% for 5 minutes`.

**Multi-window burn rate alerting:** Fire when the error budget is being consumed
faster than sustainable, measured across multiple time windows simultaneously.

---

## Decision

Use **multi-window burn rate alerting** with two window pairs:

| Window | Burn rate threshold | Severity | Meaning |
|---|---|---|---|
| 1 hour | > 14.4x | Critical | Budget exhausted in < 2 hours |
| 6 hours | > 6x | Warning | Budget exhausted in < 5 days |

---

## Reasons

**Simple threshold alerting has a fundamental flaw.** A 5% error rate for
5 minutes triggers an alert — but so does a 5% error rate that lasts exactly
5 minutes and recovers on its own. The alert fires but the incident was
self-healing. Over time, this creates alert fatigue.

**Burn rate connects alerts to business impact.** A burn rate of 14.4x means
"at this rate, we will exhaust the entire monthly error budget in 2 hours."
This is a concrete, business-relevant statement. A simple "error rate > 5%"
alert is a technical statement that doesn't immediately convey urgency.

**The maths behind 14.4x.** The SLO window is 30 days. If we want to detect
when the budget will be exhausted within 2 hours:
```
30 days × 24 hours = 720 hours
720 hours ÷ 2 hours = 360
360 ÷ 25 (normalisation factor) = 14.4
```
A burn rate of 14.4x over a 1-hour window means the service is consuming
its monthly budget at 14.4 times the sustainable rate.

**Two windows catch different failure modes.** The 1-hour window catches
sudden, severe outages fast. The 6-hour window catches slow degradation
that a 1-hour window might miss — for example, a memory leak that gradually
increases error rate over hours rather than minutes.

**Implemented as recording rules.** The burn rate calculations are
pre-computed as Prometheus recording rules (`slo:error_budget_burn_rate_1h`,
`slo:error_budget_burn_rate_6h`) so alert evaluation is fast and dashboards
load instantly without expensive on-the-fly calculation.

---

## Consequences

**Positive:**
- Fewer false positives — brief spikes don't trigger critical alerts
- Business-relevant alert language — burn rate directly maps to budget impact
- Two-window approach catches both fast and slow failure modes
- Recording rules make dashboards fast

**Negative:**
- More complex to explain to stakeholders unfamiliar with SRE concepts
- Requires meaningful traffic volume to calculate accurate rates
- The 1h window needs at least 1 hour of data before burn rate stabilises
  (mitigated by also having simple error rate alerts as a secondary layer)

---

## Alternatives considered

| Approach | Reason rejected |
|---|---|
| Simple error rate threshold | Alert fatigue from brief self-healing spikes |
| Uptime/downtime SLO | Doesn't capture partial degradation |
| Single burn rate window only | Misses slow degradation (slow burn) |
| Alertmanager inhibition rules | Addresses symptoms not root cause |

---

## References

- Google SRE Workbook — Chapter 5: Alerting on SLOs
- Prometheus documentation — Multi-window, multi-burn-rate alerts

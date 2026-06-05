# Postmortem: [Incident Title]

**Date:** YYYY-MM-DD
**Duration:** HH:MM – HH:MM (X minutes)
**Severity:** Critical / High / Medium
**Author:** [Name]
**Status:** Draft / In Review / Closed

---

## Summary

One paragraph. What broke, for how long, what the user impact was, and what fixed it. Written for someone who wasn't involved.

---

## Impact

| Area | Detail |
|---|---|
| Duration | X minutes |
| Availability | X% during incident (SLO: 99%) |
| Error budget consumed | ~X% of monthly budget |
| Users affected | All / Partial |
| Requests failed | ~X |

---

## Timeline

All times in UTC.

| Time | Event |
|---|---|
| HH:MM | Alert fired — AppDown / HighLatency / etc |
| HH:MM | On-call acknowledged alert |
| HH:MM | Investigation began |
| HH:MM | Root cause identified |
| HH:MM | Mitigation applied |
| HH:MM | Service recovered |
| HH:MM | Alert resolved |

---

## Root cause

Clear technical explanation of what caused the incident. Avoid blame language. Focus on the system condition that allowed this to happen.

---

## Contributing factors

- Factor 1 (e.g. no memory limit set on container)
- Factor 2 (e.g. no automated restart policy)
- Factor 3 (e.g. alert threshold too slow to catch early degradation)

---

## What went well

- The alert fired within 10 seconds of the outage
- Recovery procedure in runbook was accurate and followed without issues
- Slack notification reached the team promptly

---

## What could be improved

- Detection could be faster with a shorter `for` window on AppDown
- Recovery required manual steps that could be automated

---

## Action items

| Action | Owner | Due date | Status |
|---|---|---|---|
| Add Docker restart policy to lab script | EJ | YYYY-MM-DD | Open |
| Reduce AppDown `for` from 10s to 5s | EJ | YYYY-MM-DD | Open |
| Add automated recovery script | EJ | YYYY-MM-DD | Open |

---

## Lessons learned

What does this postmortem teach us about the system, the process, or our assumptions?

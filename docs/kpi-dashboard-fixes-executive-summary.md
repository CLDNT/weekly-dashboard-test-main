# KPI Dashboard Fixes — Executive Summary

**Prepared for:** Owner / COO
**Environment:** Development (validated before promoting to production)
**Dashboard:** KPI Tracking Dashboard (OKR Scorecard, Practice Scorecard, Staff Detail, Escalations, Data Freshness)

---

## The problem, in one line

The same metric was showing **different numbers on different sheets**, and one
key tile (Open Escalations) was showing **zero** — because each sheet counted
people and hours slightly differently, and one data step ran in the wrong order.
We standardized the definitions so every sheet agrees, and fixed the ordering bug.

---

## What changed — in order

### Day 1 — Escalations

**1. Open Escalations tile showed 0 (it should have been 4).**
Cause: the weekly numbers were being calculated *before* the escalations data was
loaded each cycle, so it always captured "nothing."
Fix: reordered the pipeline so escalation data loads first. The tile now shows the
correct count.

**2. Open Escalations didn't match the Escalations sheet.**
Cause: the two places used different rules for "open" (one excluded escalations
with no customer assigned, the other didn't).
Fix: aligned the OKR tile to the Escalations sheet's definition. Both now agree.
- *Note:* one escalation (ES-232) has no customer assigned in Jira — a data-entry
  gap worth cleaning up at the source.

---

### Day 2 — Metric reconciliation across sheets

We found four metrics that appeared on multiple sheets with inconsistent numbers,
and reconciled three of them (the fourth, time compliance, was intentionally left
for a separate business decision).

**3. Headcount / staff count** — now identical on all sheets.
Cause: one sheet dropped people with no practice assigned; another counted the
current roster instead of who was employed that week.
Fix: standardized who counts (active, has capacity, submits time, not exempt,
employed as of that week; people with no practice show as "Not Assigned" instead
of disappearing).

**4. Total Billable Hours** — now identical on all sheets.
Cause: one sheet excluded people with no practice; the OKR number even counted
hours from inactive/opted-out people.
Fix: same standardized population applied everywhere.

**5. Billable Utilization %** — now identical on all sheets.
Cause (two parts): the population differences above, **plus** the Practice
Scorecard tile was **averaging each practice's percentage** instead of computing
the true company-wide rate. (Example: a small team at 90% and a large team at
40% averaged to ~65%, when the real company rate was ~46%.)
Fix: standardized the population and changed the Practice tile to compute the
true weighted company rate.

**Result:** headcount, billable hours, and billable utilization now match across
the OKR Scorecard, Practice Scorecard, and Staff Detail for **all 35 weeks of
2026** — verified 35/35.

---

### Day 2 — Additions and cleanup

**6. Added "NB Productive Hours" tile** to the OKR Scorecard (data already existed
for all weeks; just surfaced it).

**7. Removed the "MC Service Delivery" sheet.**
Reason: its tiles weren't meaningful — "Total MC Issues" summed a growing lifetime
backlog rather than weekly delivery, "Billable Hours" duplicated "Total Hours,"
the escalations column was blank, and the current partial week distorted the view.
We documented exactly how to rebuild an improved version (weekly throughput, open
backlog) if leadership wants an MC delivery view.

---

## The one thing we deliberately did NOT change

**Time Compliance %** still differs across sheets because each uses a genuinely
different business rule:
- OKR: counts anyone who logged *any* time.
- Staff Detail: counts people who logged *≥ 90%* of their expected hours.
- Practice: 90% rule, but shown as an average across practices.

This is a **business decision**, not a bug: *what threshold defines "compliant,"
and should it be company-wide or averaged?* Once you decide, we can align all
three the same way we did the others.

---

## Status & next steps

- All fixes are **live and verified in the development dashboard**.
- **Not yet in production** — pending your review/approval to promote.
- Every change is fully documented with rollback steps, so anything can be reverted.

**Decisions needed from you:**
1. Approve promoting these fixes to the production dashboard.
2. Decide the canonical **Time Compliance** definition (threshold + company-wide vs
   averaged) so we can reconcile the last metric.
3. Decide whether you want an improved **MC Service Delivery** view rebuilt.
4. Have someone assign a customer to escalation **ES-232** in Jira (data cleanup).

---

## Supporting detail (for the technical team)

- `docs/change-requests/2026-09-08-metric-reconciliation-rollback.md` — every
  change with exact rollback instructions.
- `docs/mc-service-delivery-sheet-guide.md` — MC sheet removal + rebuild guide.

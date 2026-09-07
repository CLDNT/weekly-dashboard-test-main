# Dashboard Data Refresh — Issue Register

**Date:** 2026-09-04
**Scope:** Dashboard data refresh process (Clockify + Jira → Lambda → RDS PostgreSQL → QuickSight SPICE), including SPICE ingestion and incremental import freshness.
**Basis:** Reconciled against the August 2026 fixes (migrations 104/105/106/107, NB custom-field rewrite) verified in source code and migration files on disk.
**Account:** 961341524729 | **Region:** us-east-1

---

## Severity Legend

| Severity | Meaning |
|---|---|
| **Critical** | Data shown is wrong or silently stale; requires immediate fix |
| **High** | Materially misleads decision-makers or causes silent data loss |
| **Medium** | Reduces trust or reliability; fix before next sprint |
| **Low** | Improvement opportunity; low risk if deferred |

---

## Open Issues

| # | Priority | Issue | Current Impact | Impact After Fix |
|---|----------|-------|----------------|------------------|
| A-1 | **Critical** | SPICE refresh has no success/failure verification. `refresh_quicksight_datasets()` is fire-and-forget; the pipeline sets `spice_triggered = len(ids)` and reports `success` regardless of whether ingestions complete. Failures that still slip through: (a) `42P16` view-recreation conflict when a changed view is reapplied with `CREATE OR REPLACE`; (b) any per-dataset ingestion failure (view dropped, column drift, VPC timeout), which is caught, logged to stdout, and ignored. *(The `get_quicksight_dataset_ids` NameError previously listed here is RESOLVED — see Resolved table.)* | Dashboards can serve the prior SPICE snapshot while the run reports success and emails green. COO sees stale numbers believing they're current, with no staleness indicator. | Capture each ingestion's terminal status (poll `describe_ingestion`); mark run ERROR + SNS alert on any FAILED/CANCELLED; use `DROP … CASCADE` + recreate for structural view changes to avoid `42P16`. Stale data becomes visible and actioned within one cycle. |
| B-1 | **High** | Incremental watermark = previous run's `end_date` (`datetime.now()`), not a data high-water mark. Retroactive Clockify edits to earlier weeks are never re-pulled. | Corrected/backdated entries — including late toggles of the new NB checkboxes — never reach the dashboard. Historical weeks frozen at first-import value. | Overlapping re-pull (last N weeks) or max-entry-date watermark; edited/backdated hours and NB reclassifications flow through on the next run. |
| B-3 | **High** | Per-user import failure is swallowed (`try/except: continue`) yet run logs `status='success'`, advancing the watermark past the gap. | A user's entire week of hours can silently drop; utilization/compliance understate with no error. Watermark then skips the gap permanently. | Failed users tracked; run marked ERROR (or gap re-queued). No silent data loss; watermark only advances on complete success. |
| A-2 | Medium | Three divergent dataset inventories (~47 in `get_all_dataset_ids`, 14 in runbook, 17 in `refresh_quicksight_datasets.py`). | A dataset in one list but not another refreshes inconsistently or never on schedule → silent staleness for those tiles. | Single source-of-truth list drives pipeline + script; every active dataset refreshes every cycle. |
| C-4 | Medium | `pWeekEnd`/`pWeekStart` IaC default stale (`2026-05-25`); patched live by non-fatal `update_analysis_week_parameter`. | Any CloudFormation redeploy resets all week-filtered KPI tiles to the wrong week until manually corrected. | Dynamic default sourced from `kpi_weekly_snapshots`; redeploy-safe. |
| A-3 | Medium | No SPICE freshness indicator on dashboards. `vw_data_freshness` exists but isn't surfaced. | Consumers can't tell if data is current; stale data is indistinguishable from fresh. | "Data as of {date}" tile on each sheet; staleness is self-evident. |
| A-4 | Medium | Known-failing datasets normalize FAILED state (`vw_daily_activity_trend`, `vw_import_activity`, `vw_skill_area_summary` — views don't exist in prod). | Operators trained to ignore FAILED; masks new/real refresh failures (alarm fatigue). | Dead datasets removed or views created; FAILED again means a real problem. |
| C-5 | Medium | `days_open` / age computed at import time, not live (`vw_escalations`). | Escalation age stale up to 6 days between weekly imports. | Compute live (`CURRENT_DATE - created_date`); always accurate. |
| ESC-01/02 | Medium | Escalation KPI tiles mislabeled — "High Priority" counts all open; "Avg Days Open" uses `MAX`. | COO reads wrong escalation figures (count and aging). | Priority filter added; AVG vs MAX corrected; labels match values. |
| MC-01 | Medium | MC Hours KPI uses `MAX` not `SUM` over pre-aggregated per-customer rows. | MC hours tile shows the single largest customer's hours, not the total — understated. | `SUM` aggregation; tile reflects true total MC hours. |
| CC-02/03 | Medium | No `AWS::QuickSight::DataSet` in IaC; account ID + dataset IDs hardcoded. | Accidental dataset deletion has no recovery path; a deleted dataset never refreshes. | Datasets in IaC, ARNs parameterized; recoverable and portable. |
| IaC-drift | Medium | Lambda code, EventBridge payloads, Bedrock/SES IAM live outside CloudFormation (8/28 doc). | A stack update can silently overwrite live behavior / drop permissions → break imports, compliance email, AI analysis. | IaC reconciled before any deploy; no silent drift. |
| 107-applied | Medium | Migration 107 status unconfirmed — header says "Awaiting approval" (8/20). | If not applied in prod, braced values persist → filter duplicates/missed rows in Streamlit and ad-hoc queries. | Confirm applied (or apply); brace-class bugs gone. |
| E-2 | Low | Streamlit "Last 4 Weeks"/"Active (7d)" include incomplete current week / day-of-week dependent. | Numbers shift by viewing day; looks stale/inconsistent. | Complete-week boundaries; stable figures. |

---

## Resolved by August Work (verified in code)

| # | Was-Priority | Issue | Impact Before Fix | Impact After Fix (now in effect) |
|---|--------------|-------|-------------------|----------------------------------|
| C-1 | Critical | CST-660 `ps_project_status` duplicate rows (INSERT-not-upsert) | Every Jira sync appended dupes; any non-`DISTINCT` aggregation double/triple-counted projects (drove the 24-vs-19 discrepancy). | `ON CONFLICT (jira_issue_id) DO UPDATE` + migration 104 restores `UNIQUE(jira_issue_id)` and dedups → one row per issue; counts correct. |
| NB | Critical | NB Productive/Non-Productive miscomputed via `project_type`/mapping heuristic | NB Non-Productive showed ~0.00 vs true ~750–875 hrs (97% under); NB Productive swept in all `billable=false`. | Migrations 105/106 read explicit Clockify checkbox fields → NB tiles accurate May-2026 onward (pre-April-2026 structurally unavailable). |
| E-1 | High | `{Bravo}` brace divergence between ORM and views | Duplicate filter values, missed rows on exact-match, ORM vs QuickSight disagreement. | Migration 107 strips braces in 4 base tables + `analyze_project_health.py:560` fix → clean matches (pending 107-applied confirmation above). |
| TU-03 | Medium | `vw_productive_utilization` NB column gap | Non-billable non-productive hours invisible on Time & Util sheet. | View rewritten by migration 106; superseded — needs re-verify against new definition, not the June finding. |
| A-1 (part) | High | `get_quicksight_dataset_ids` NameError broke the `production-jira-daily-refresh` path (payload with `refresh_quicksight:true` and no dataset IDs). | Daily Jira refresh threw NameError in the refresh tail; contributed to the ~35.6% Lambda error rate. | Deployed artifact defines `get_all_dataset_ids` (L465) and calls it correctly at the refresh fall-through (L2482–2487); zero old-name references in `lambda_contents/`. `outstanding-items.md` marks it Done. *Verified against on-disk package artifact, not live AWS function.* |

---

## Suggested Sequencing

1. **A-1** (Critical) — stop silent stale data; make refresh failures fatal + alarmed. Also clears the 35.6% error rate.
2. **B-1 + B-3** (High) — fix the watermark and silent per-user failures so the now-correct NB/CST-660 data actually stays fresh and complete.
3. **107-applied + IaC-drift** (Medium) — confirm 107 is live; reconcile IaC before any redeploy so fixes aren't overwritten.
4. Remaining Medium/Low tiles (A-2, C-4, ESC, MC-01, CC-02/03) in the next sprint.

---

## Verification Caveats

The following require confirmation to fully close out:

- Migration 107 is applied in prod (its header states "Awaiting approval" as of 8/20). — *runtime DB check needed.*
- ~~The `get_quicksight_dataset_ids` NameError is cleared in the deployed Lambda package.~~ **RESOLVED (2026-09-04):** confirmed in the extracted deployment artifact `lambda_contents/src/lambda_handler.py` — function defined as `get_all_dataset_ids` (L465) and called correctly at the refresh fall-through (L2482–2487); zero references to the old name remain in `lambda_contents/`. `docs/outstanding-items.md` also marks it Done. *Caveat: verified against the on-disk package artifact, not the live AWS function; `lambda-deployment-package.zip` (Aug 14) is newer than the extracted `lambda_contents/` (Jul 30), so confirm the running function's code SHA matches before final sign-off.*
- The NB 52-week backfill completed for all historical weeks. — *runtime DB check needed.*

**Note on A-1 scope:** the NameError was only one of the two documented refresh-tail failures. The `42P16` view-recreation conflict and the fire-and-forget "reports success regardless" design remain open, so A-1 stays Critical.


---

## Follow-Ups Surfaced by A-1/A-4 (logged 2026-09-07, dev 604775478093)

Once A-1 verification + A-4 skip-classification were live, the dev freshness view
resolved to **6 OK / 6 FAILED / 37 SKIPPED**. Of the 6 FAILED, three are **real
schema drift** between the QuickSight dataset `InputColumns` and the current DB view:

| Dataset | Ingestion error | Status |
|---|---|---|
| `clockify-pod-performance-prod` | `column "week_start_date" does not exist` | Deferred |
| `data-freshness` | `column "source" does not exist` | Deferred |
| `ps-project-status-view` | `column "jira_key" does not exist` | Deferred |

**Downstream impact assessment (why deferral is safe):** all three have been
**failing on every daily run for days** (Sep 5/6/7 `15:01` ingestions all FAILED;
no COMPLETED ingestion in recent history). They are **pre-existing failures** that
A-1/A-4 made *visible* — they were already broken before this work and are not
degrading further. Deferring does **not** introduce new downstream staleness; the
bound tiles were already stale/empty. Fixing them would *improve* those tiles but is
independent of the refresh-pipeline fixes.

**Fix (future work):** reconcile each dataset's `InputColumns` with its current view
definition (either update the dataset via `update_data_set`, or add/rename the
missing column in the view). Requires per-dataset investigation.

**Other 3 FAILED (not schema drift):**
- `project-directory` — transient `ThrottlingException` from a bulk 47-ingestion
  manual refresh; normal weekly cycle (~9 real datasets) won't hit this. Consider a
  small backoff in bulk refresh only.
- `mc-projects-at-risk`, `ps-projects-at-risk` — `ResourceNotFoundException` via a
  non-SSOT refresh call site (MC/PS at-risk step). Effectively skip-class; verify that
  call site also benefits from the SKIPPED_NOT_FOUND handling.


---

## Finding: dev DB is 5 migrations behind (logged 2026-09-07, dev 604775478093)

`schema_migrations` in dev has entries only **through 102** (last applied 2026-08-11).
Migrations **103–107 exist on disk but are NOT applied in dev:**

| Migration | Purpose | Evidence it's missing |
|---|---|---|
| 103_fix_nb_nonproductive_consistency | NB consistency fix | not in schema_migrations |
| 104_fix_ps_project_status_unique_constraint | CST-660 dedup + UNIQUE (register C-1) | not in schema_migrations |
| 105_add_nb_custom_fields_to_time_entries | NB custom-field columns | not in schema_migrations |
| 106_rewrite_nb_classification_from_custom_fields | NB reclassification (register NB) | not in schema_migrations |
| 107_strip_clockify_brace_formatting | strip `{...}` braces | **17,199 rows in `clockify_detailed_time_entries` still braced** (e.g. `{Alpha}`, `{"Free Agent"}`) |

**Implication:** the register's "Resolved by August Work" items (C-1 dedup, NB fix,
E-1 braces) were resolved in **prod**, but were **never applied in this dev
account**. So dev exhibits the brace bug and potentially the CST-660/NB issues.
The `107-applied` register item is therefore **confirmed NOT applied in dev**.

**Note on new migrations:** 108 (spice_refresh_log) and 109 (freshness SKIPPED) were
applied in dev via the `run_migration` Lambda mode, which does **not** write to
`schema_migrations`. They are live but untracked. Backfill their tracking rows when
the migration gap is reconciled (they are idempotent, so re-running is safe).

**Decision (2026-09-07):** log and defer. Applying 103–107 is a multi-migration data
mutation (104 dedups + adds a UNIQUE constraint; 107 rewrites ~17k rows) that should
be run deliberately in order with before/after snapshots — out of scope for this
pass. Note: new imports already strip braces at ingest (`get_custom_field_value`), so
only historical rows carry braces; 107 backfills those.


---

## C-5 applied (2026-09-07, dev 604775478093)

Migration `110_escalation_live_age.sql` applied — `vw_escalations` now computes
`days_open` / `days_to_resolve` live (`CURRENT_DATE - created_date` for open items;
`resolution_date - created_date` for resolved) instead of reading import-time values.
Column order preserved so `CREATE OR REPLACE VIEW` did not hit 42P16.

**VERIFIED WITH REAL DATA (2026-09-07):** imported the Jira ES board into dev
(158 escalations, 93 epics). Live-age check: `vw_escalations.days_open` matches
`CURRENT_DATE - created_date` for open items (ES-247=76, ES-253=49, ES-255=42…).
Definitive proof: forced base-table `escalations.days_open` for ES-247 to a bogus
`1`; the view still returned `76` (computed from dates), confirming it no longer
reads the frozen column. Base value then restored.

**Supporting changes made to enable the import (all dev):**
- `src/handlers/escalations.py`: DDL now runs with `master_database_url` (report_user
  lacks CREATE on schema public); removed an inline SQL `--` comment that broke the
  handler's naive `split(';')` executor; aligned its inline `vw_escalations` with
  migration 110 so the import does NOT clobber the C-5 fix.
- Added missing `UNIQUE (jira_issue_id)` constraint on the pre-existing `escalations`
  table (0 duplicates present) — the upsert's `ON CONFLICT (jira_issue_id)` requires
  it. This mirrors the register's C-1/migration-104 missing-constraint class.
- Escalations datasets (`escalations-detail`, `escalations-by-customer`) still absent
  in dev → SKIPPED_NOT_FOUND on refresh (non-fatal, per A-2/A-4). ESC-01/02 tile
  relabeling remains un-verifiable until those datasets are created in dev.



---

## ESC-01/02 fixed & verified in dev (2026-09-07, 604775478093)

The COO operational dashboard (where the original mislabeled escalation tiles live)
does **not exist in dev** — `coo-operational-analysis-prod` is prod-only. The
underlying view `vw_escalations_by_customer` already computes the correct
aggregations (`high_priority_count` filtered to High/Highest; `avg_days_open` = AVG).
The ESC-01/02 bug is purely in the prod COO tile field-well config.

To make the FIXED behavior demonstrable in dev:
- Created SPICE datasets `escalations-by-customer` (74 rows) and `escalations-detail`
  (143 rows) over the escalation views (initial ingestions COMPLETED). Both were
  already in the SSOT, so the pipeline refreshes them each cycle now that they exist.
- Added an **"Escalations" sheet** to `kpi-tracking-analysis-dev` and published
  `kpi-tracking-dashboard-dev` **version 5** (prior published v4). Tiles:
  - **ESC-01 High Priority** = `SUM(high_priority_count)` = **6** (High/Highest only).
    Old bug counted all open escalations.
  - **ESC-02 Avg Days Open** = `AVERAGE(avg_days_open)` = **52.0**. Old bug used MAX =
    **76.0** (verified the contrast in-DB).
  - Total Open = `SUM(open_escalations)` = 4, plus a by-customer detail table.

**Rollback:** republish dashboard v4; restore analysis def from
`s3://weekly-reporting-production-deployments-604775478093/lambda/backups/kpi-analysis-backup-esc-20260907-230808.json`;
optionally delete datasets `escalations-by-customer` / `escalations-detail`.
Builder script: `scripts/add_escalations_sheet.py`.

**Prod note:** the actual prod ESC-01/02 fix = correct the field-well config on the
COO dashboard's existing escalation tiles (High Priority → filter priority; Avg Days
Open → AVG not MAX). The dev Escalations sheet demonstrates the target values.


---

## MC-01 fixed & verified in dev (2026-09-07, 604775478093)

`vw_mc_ticket_activity` is one row per customer per week with pre-aggregated
`clockify_hours` / `billable_hours`. A "Total MC Hours" KPI must **SUM** across
customers; the old bug used MAX (only the largest customer's hours).

- Created SPICE dataset `mc-ticket-activity` (140 rows; was in SSOT but absent in dev
  → previously SKIPPED). Now refreshes each cycle.
- Added an **"MC Service Delivery"** sheet to `kpi-tracking-analysis-dev`; published
  `kpi-tracking-dashboard-dev` **version 6**. MC Hours tile = `SUM(clockify_hours)`.
- Verification: for the latest week, `SUM(total_issues)=1657` across 28 customer rows
  vs `MAX≈157` — proves SUM aggregation is applied. (MC `clockify_hours` are sparse in
  dev — mostly 0 — so SUM==MAX for hours this week coincidentally; the total_issues
  contrast demonstrates the aggregation fix unambiguously.)

**Rollback:** republish dashboard v5; restore analysis def from
`.../lambda/backups/kpi-analysis-backup-mc-20260907-232101.json`; optionally delete
dataset `mc-ticket-activity`. Builder: `scripts/add_mc_sheet.py`.

---

## Dev KPI dashboard — final sheet inventory (2026-09-07)

`kpi-tracking-dashboard-dev` published **version 6**, sheets:
OKR Scorecard · Practice Scorecard · Staff Detail · **Data Freshness (A-1/A-3)** ·
**Escalations (ESC-01/02)** · **MC Service Delivery (MC-01)**.
Rollback to pre-all-tiles = republish dashboard **v2**.


---

## E-2 fixed (2026-09-07, code only — not deployed)

`src/app.py` "Last 4 Weeks" quick-select previously set `end_date = current_sunday`,
including the **incomplete current week**, so the metric shifted by viewing day.
Fixed to span the **4 most recent COMPLETE weeks** ending at the last completed
Sunday (`current_monday - 1 day`). Compiles clean.

**Not deployed:** the Streamlit app runs on a separate host/deploy path from the
import Lambda. This is a source-only change; it ships on the next Streamlit deploy.
The rolling `vw_active_resources.hours_last_30_days` (CURRENT_DATE - 30 days) window
was left as-is — changing "active" window semantics is a product decision, not a
clear bug.

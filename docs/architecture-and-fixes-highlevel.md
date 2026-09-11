# Weekly Reporting — Architecture & Fixes (High-Level)

**Date:** 2026-08-28
**Account:** 961341524729 | **Region:** us-east-1
**Purpose:** A single high-level view of (1) the current architecture, (2) the data-accuracy fixes — NB classification via Clockify custom fields, and Clockify brace removal — (3) the impact of the refactored Lambda, and (4) the proposed new ingestion architecture.

> **Update (2026-08-28):** The NB Productive / NB Non-Productive metrics are now sourced from two explicit Clockify CHECKBOX custom fields (`Non Bill Productive`, `Non Bill Non Productive`), deployed to dev on 2026-08-17 and to the leadership account on 2026-08-18. This **supersedes** the earlier SQL-classifier approach (`project_type` + `ps_project_mapping` heuristic) that previous drafts of §2.1–§2.2 described. See §2.1 below for the current design and the archived note for the prior approach.

---

## 1. Current Architecture

The system pulls time-tracking data from Clockify and project data from Jira, stores it in RDS PostgreSQL, and serves executive dashboards through QuickSight. A single monolithic Lambda does all the work.

```
┌─────────────┐   ┌─────────────┐
│  Clockify   │   │    Jira     │
│     API     │   │    Cloud    │
└──────┬──────┘   └──────┬──────┘
       │                 │
       ▼                 ▼
┌─────────────────────────────────────────────┐
│   production-clockify-import (MONOLITH)       │
│   - src/lambda_handler.py — 2,034 lines       │
│   - 30 dispatch "modes" (import, jira, KPI,   │
│     views, compliance email, AI analysis,     │
│     11 diagnostics, run_query/run_migration)  │
│   - ~19 MB deployed ZIP, VPC-attached          │
│   - Deployed via shell script (outside CFN)   │
└──────────────────────┬────────────────────────┘
                       │ writes
                       ▼
┌─────────────────────────────────────────────┐
│   RDS PostgreSQL (single-AZ, db.t3.micro)     │
│   - Base tables (users, projects, entries)    │
│   - 50+ SQL views (create_views.sql, 139 KB)  │
│   - kpi_weekly_snapshots table                │
└──────────────────────┬────────────────────────┘
                       │ VPC data source (SSL disabled)
                       ▼
┌─────────────────────────────────────────────┐
│   QuickSight (47 SPICE datasets)              │
│   3 active dashboards: COO Operational,        │
│   Executive Summary, Weekly Reporting          │
└─────────────────────────────────────────────┘

Triggers: EventBridge (Mon 9 AM CT import, Mon noon CT KPI snapshot,
          daily 10 AM UTC Jira refresh, compliance email rules)
Secondary UI: ECS Fargate Streamlit dashboard (write ops, forecast uploads)
```

### Key characteristics and pain points

- **Single point of failure and change:** one 2,034-line handler with 30 modes. A bug in any mode shares the same execution environment as the production import. The full 19 MB package must be redeployed to fix any single mode.
- **IaC drift:** Lambda code, EventBridge payloads, and Bedrock/SES IAM permissions are managed outside CloudFormation. A stack update risks silently overwriting live behavior.
- **Reliability gaps:** single-AZ RDS, no DLQ on the import Lambda, migrations replay on every Streamlit restart (no tracking table), 9 duplicate migration numbers.
- **Accuracy gaps:** NB classification originally relied on an indirect `project_type` + `ps_project_mapping` heuristic in `kpi_snapshot.py` and the SQL views, which mis-computed both NB metrics (see §2.1). This has been replaced by two explicit Clockify checkbox custom fields. Older base data also carried Clockify's brace formatting (see §2.2).
- **Health at last check:** the import Lambda ran at ~35.6% error rate — core imports succeeded but the QuickSight-refresh tail failed (`get_quicksight_dataset_ids` NameError) and a view schema conflict (`42P16`) surfaced during view recreation.

---

## 2. Data-Accuracy Fixes

Two fixes correct the numbers the COO sees. The first replaces the indirect NB classification heuristic with two explicit Clockify custom fields; the second is a data-cleanup migration.

### 2.1 Fix — NB Classification via Clockify Custom Fields (current approach)

**Symptom:** Both NB tiles were wrong. NB Non-Productive showed ~0.00 when the true value was ~1,142 hrs/week (97% underreported, week 2026-06-29); NB Productive over-counted because it swept in all `billable = false` hours. The root cause was that NB status was *inferred* from `project_type` + `ps_project_mapping` + mapped-client heuristics in `kpi_snapshot.py` and the SQL views — an indirect classification that never matched how the business actually tags work.

**The fix (deployed dev 2026-08-17, leadership 2026-08-18):** classify NB work from two explicit Clockify **CHECKBOX** custom fields on time entries, set by staff at logging time, instead of inferring it:

- `Non Bill Productive` (Clockify field ID `69dfd7600828d1ece13fc540`)
- `Non Bill Non Productive` (Clockify field ID `69dfd83e8e5e4984d4a0a35e`)

Implementation:

1. **Ingest** — `clockify_client.get_time_entries()` now sends `hydrated=true` so custom-field values appear in the API response; `import_clockify_data.py` reads the two checkboxes from `customFieldValues` on each entry.

2. **Schema (migration 105)** — added `is_nb_productive BOOLEAN` and `is_nb_non_productive BOOLEAN` to `clockify_detailed_time_entries`.

3. **KPI logic** — `kpi_snapshot.py` replaced the `project_type` + `ps_project_mapping` + mapped-client CTE with direct reads: NB Productive = `WHERE te.is_nb_productive = TRUE`; NB Non-Productive = `WHERE te.is_nb_non_productive = TRUE` plus the per-user capacity gap `GREATEST(0, weekly_capacity − total_logged)`.

4. **Views (migration 106)** — `vw_productive_utilization`, `vw_practice_kpi_weekly`, and `vw_kpi_staff_weekly` rewritten to read the checkbox columns directly, dropping the JOINs to `clockify_projects` and `mapped_clients`. Required `DROP VIEW … CASCADE` + `CREATE` (not `CREATE OR REPLACE`) because the query structure changed; the CASCADE also dropped and recreated `vw_utilization_history`.

**Verified results (week 2026-08-10):**

| Account | NB Productive | NB Non-Productive |
|---------|---------------|-------------------|
| Leadership (961341524729) | 557.46 hrs (view) / 606.96 hrs (snapshot) | 749.63 hrs (view) / 874.70 hrs (snapshot, incl. capacity gap) |
| Dev (604775478093) | 589.44 hrs | 697.13 hrs (view) / 934.47 hrs (snapshot, incl. capacity gap) |

**Data availability caveat:** the checkboxes were added to Clockify in **April 2026**, so entries before then have both flags `FALSE`. Jan 2025 – Mar 2026 shows no NB custom-field data; May 2026 onward is fully adopted. Historical NB figures before April 2026 are not reconstructable from this source.

**Deployment dependencies:** requires Lambda redeploy, a full 52-week Clockify re-import (to populate the new columns), view rewrites, KPI snapshot backfill per week, and SPICE refresh. Two dashboard follow-ups were also needed: adding the NB tiles to the COO Operational Dashboard's week filter scope (they were showing unfiltered MAX), and re-passing `ThemeArn` on `update_dashboard` to avoid dropping the brand theme. See `docs/nb-custom-fields-deployment-dev.md` and `docs/nb-custom-fields-deployment-leadership.md`.

> **Archived — prior SQL-classifier approach (superseded):** Earlier drafts computed both metrics indirectly. NB Non-Productive was fixed by moving to a per-user Component A (`SUM(hours WHERE billable=false)`) + Component B (per-user capacity gap) formula, correcting a wrong-column write and an aggregate-level cancellation bug. NB Productive was to be fixed with a classifier `billable = false AND project_type IN ('Non Bill Productive','Overtime','Presales')` plus mapped-client logic. This heuristic proved fragile and dependent on project-type mapping accuracy, and was replaced by the explicit checkbox fields above. The earlier "~77 hrs/week correct NB Productive" figure came from that abandoned approach and does not match the checkbox-sourced numbers.

### 2.2 Fix — Clockify Brace Removal (Migration 107)

**Symptom:** Clockify returns DROPDOWN custom-field values wrapped in braces — `{Bravo}`, `{"Professional Services"}`. Older data imported before the ingest-time strip still carries braces in the base tables, causing:

- Duplicate filter values (`Bravo` vs `{Bravo}`)
- Missed rows on exact-match queries (`IN ('Alpha','Bravo')` misses `{Alpha}`)
- Every SQL view carrying a 4-layer `REPLACE(REPLACE(REPLACE(REPLACE(...)))` on every read.

**The fix:** Migration `107` applies `TRIM(REPLACE(REPLACE(REPLACE(REPLACE(col,'{',''),'}',''),'"',''),'\',''))` to the affected columns across four tables (`clockify_users`, `clockify_projects`, `clockify_detailed_time_entries`, `ps_project_mapping`). It is idempotent (a no-op on already-clean data) and loses no data — only formatting noise.

**Impact:**

- **Safe / no change:** all SQL views (their REPLACE becomes a no-op), KPI snapshot (`ILIKE` matching), forecast, MC audit, QuickSight dashboards, and the Python import path (already strips at ingest).
- **One code fix required:** `analyze_project_health.py:560` explicitly matched the **braced** form `'{"Managed Cloud Services"}'`. After cleanup that filter would never match, so it must change to `'Managed Cloud Services'`, then redeploy the Lambda.
- **Fixed for free:** five currently-broken Streamlit filters/counts (POD multiselect duplicates, MC resource count misses, practice distribution display) become correct automatically.

---

## 3. Impact of the Refactored Lambda

The current-state assessment recommends **not** aggressively splitting the monolith for an internal tool, but applying targeted refactors. The proposed ingestion spec goes further and decomposes it into single-responsibility functions. The impact either way:

### 3.1 What changes

- **Diagnostic modes retired (11 modes, ~400 lines):** `diagnose_*` and `debug_*` modes are removed from the handler. Ad-hoc queries move to a direct RDS connection via SSM port-forward. This shrinks the handler and reduces attack surface.
- **`run_query` / `run_migration` gated:** arbitrary SQL execution against production (invokable by anyone with `lambda:InvokeFunction`) is removed or placed behind an allowlist. This also eliminates the known duplicate-definition bug (`run_migration` defined twice; the second silently overrides the first).
- **Import path isolated:** separating the production import from AI analysis, compliance email, and diagnostics means a failure in one no longer shares the import's execution environment or its oversized 900s timeout.

### 3.2 Positive impact

- **Blast radius reduced:** a fault in analysis or diagnostics can no longer break the Monday import.
- **Right-sized timeouts and memory:** short operations (e.g., QuickSight refresh) no longer inherit a 15-minute timeout.
- **Smaller packages, faster cold start:** removing heavy/rarely-used code paths shrinks the deployment from ~19 MB toward ~2 MB for the extraction functions.
- **Security surface shrinks:** no arbitrary SQL path, fewer IAM permissions per function (least privilege per role).

### 3.3 Risks to manage during refactor

- **IaC reconciliation first:** because Bedrock/SES permissions and EventBridge payloads live outside CloudFormation today, they must be brought into IaC *before* any stack update — otherwise the refactor deploy silently deletes them and breaks compliance email and AI analysis.
- **KPI fixes must ship with the redeploy:** the NB custom-fields classification change (§2.1) and the `analyze_project_health.py` brace fix (§2.2) both require a Lambda redeploy plus a full re-import, view rewrites, historical backfill, and SPICE refresh. Sequence these together to avoid multiple redeploys.

---

## 4. Proposed New Architecture (Ingestion Pipeline Spec)

Replace the monolithic Lambda with an **AWS Step Functions** pipeline orchestrating lightweight, single-responsibility Lambdas. Raw API responses land immutably in S3, transforms produce Parquet, and Glue/Athena serve QuickSight — removing RDS from the read path and eliminating the VPC dependency.

```
EventBridge (Mon 9 AM CT / daily Jira / monthly full sync)
              │
              ▼
┌───────────────────────────────────────────────────────────┐
│         Step Functions: WeeklyIngestionPipeline             │
│                                                             │
│  ┌──────────┐   ┌──────────┐  (parallel extract)           │
│  │ clockify │   │   jira   │                                │
│  │  import  │   │  import  │                                │
│  └────┬─────┘   └────┬─────┘                                │
│       └──────┬───────┘                                      │
│              ▼                                              │
│      ┌───────────────────┐   ┌──────────────────┐          │
│      │ transform-and-     │──▶│ quicksight-      │          │
│      │ snapshot (Parquet  │   │ refresh (SPICE)  │          │
│      │ + KPI compute)     │   └──────────────────┘          │
│      └───────────────────┘                                  │
│   Retries, Catch, SNS success/partial/failure notifications │
└───────────────────────────────────────────────────────────┘
              │
              ▼
┌───────────────────────────────────────────────────────────┐
│   S3 Data Lake  s3://cdx-reporting-{env}/                   │
│   raw/     (immutable JSON, date-partitioned, versioned)    │
│   curated/ (Parquet, partitioned by week_start / snapshot)  │
│   athena-results/ (7-day lifecycle)                         │
└──────────────────────┬────────────────────────────────────┘
                       ▼
┌───────────────────────────────────────────────────────────┐
│   Glue Data Catalog + Athena (database: cdx_reporting)      │
│   Tables: time_entries, users, projects, jira_projects,     │
│           kpi_snapshots  |  Views: weekly summary, util…    │
└──────────────────────┬────────────────────────────────────┘
                       ▼
┌───────────────────────────────────────────────────────────┐
│   QuickSight (Athena data source — no VPC)                  │
│   ~12 consolidated SPICE datasets (down from 47)            │
└───────────────────────────────────────────────────────────┘
```

### 4.1 Components

| Component | Responsibility |
|-----------|----------------|
| `clockify-import` Lambda | Pure extraction of users/projects/entries → raw JSON in S3. No DB, no VPC. ~2 MB. |
| `jira-import` Lambda | Extract PS/MC issues + custom fields → raw JSON in S3. No VPC. |
| `transform-and-snapshot` Lambda | Read raw JSON, flatten to Parquet in `curated/`, compute weekly KPIs. Only function needing pandas/pyarrow; VPC only during transition for RDS write-back. |
| `quicksight-refresh` Lambda | Trigger SPICE ingestion on the consolidated datasets. |
| Step Functions | Orchestration: parallel extract, sequential transform, retries, catch, SNS alerts, full execution visibility. |
| S3 + Glue + Athena | Immutable raw store, Parquet curated layer, serverless SQL for QuickSight. |

### 4.2 Benefits over current

- **No VPC / no RDS in the read path:** QuickSight reads S3 via Athena; removes the SSL-disabled VPC data source and the single-AZ RDS availability risk.
- **Immutable, reprocessable raw data:** any historical week can be reprocessed from S3 without re-calling external APIs.
- **Observability:** Step Functions console shows each step at a glance; per-Lambda log groups; SNS success/partial/failure notifications.
- **Cost:** estimated **~$2/month** for the pipeline vs ~$85 today.
- **Dataset consolidation:** ~12 meaningful SPICE datasets replace the current 47 (mostly manual) datasets.

### 4.3 Migration approach (phased, reversible)

1. **Parallel write (wk 1–2):** run new pipeline alongside the monolith; both write; validate S3/Parquet parity against RDS views.
2. **Athena layer (wk 2–3):** deploy Glue crawler/tables + Athena views; build test dashboards on Athena.
3. **QuickSight cutover (wk 3–4):** switch datasets from RDS to Athena; validate all 3 dashboards; repoint EventBridge to Step Functions.
4. **Decommission (wk 4–5):** disable (not delete) old rules, keep RDS 2 weeks as safety net, then remove VPC SG, old Lambda, and RDS. S3 raw data allows reprocessing at any point → instant rollback by re-enabling old rules.

### 4.4 Where the §2 fixes live in the new design

The KPI computations move into `transform-and-snapshot`, computed from in-memory DataFrames rather than SQL. The **same corrected logic** must carry over: NB classification reads the two Clockify checkbox custom fields (`is_nb_productive` / `is_nb_non_productive`) flattened from raw JSON, plus the per-user capacity gap for NB Non-Productive. The `clockify-import` Lambda must send `hydrated=true` so the custom fields are present in the raw payload. The brace issue disappears structurally — transforms flatten clean values from raw JSON, so no `REPLACE` layers are needed in the Athena views.

---

## 5. Summary

| Area | Current | After Fixes / New Architecture |
|------|---------|-------------------------------|
| Compute | 1 monolith Lambda, 30 modes, 19 MB | Step Functions + 4 single-purpose Lambdas (~2 MB each) |
| Read path | QuickSight → VPC → RDS (SSL off) | QuickSight → Athena → S3 (no VPC) |
| NB classification | Indirect `project_type` + `ps_project_mapping` heuristic (mis-computed both tiles) | Explicit Clockify checkbox fields `is_nb_productive` / `is_nb_non_productive` (migrations 105/106) |
| NB Productive (wk 2026-08-10) | Wrong (swept in all `billable=false`) | ~557 hrs view / ~607 hrs snapshot (leadership); ~589 hrs (dev) |
| NB Non-Productive (wk 2026-08-10) | 0.00 (aggregate, wrong column) | ~750 hrs view / ~875 hrs snapshot incl. capacity gap (leadership) |
| Brace formatting | Braced values in base tables | Cleaned via Migration 107; structurally gone in new design |
| Reliability | Single-AZ RDS, no DLQ, migration replay | Immutable S3, retries, SNS alerts, reprocessable |
| Cost (pipeline) | ~$85/month | ~$2/month |

**Sequencing recommendation:** the NB custom-fields fix and brace cleanup have shipped (one combined Lambda redeploy + re-import + backfill + SPICE refresh). Reconcile IaC drift *before* beginning the ingestion-pipeline migration, so the new pipeline inherits the correct checkbox-based KPI logic and a clean IaC baseline.

---

*Sources: `docs/ingestion-pipeline-spec.md`, `docs/nb-custom-fields-deployment-dev.md`, `docs/nb-custom-fields-deployment-leadership.md`, `docs/migration-107-strip-clockify-braces-impact.md`, `docs/current-state-assessment.md`, `docs/lambda-health-report.md`. Archived NB heuristic sources: `docs/nb-nonproductive-investigation-2026-07-07.md`, `docs/nb-nonproductive-full-audit-2026-07-07.md`.*

# Dashboard Metric Reconciliation — Change & Rollback Log

**Date:** 2026-09-08
**Environment:** DEV only — AWS account `604775478093`, region `us-east-1`
**Author:** Kiro (applied on request)
**Scope:** KPI Tracking dashboard/analysis — reconcile shared metrics across the
OKR Scorecard, Practice Scorecard, and Staff Detail sheets.

> **PROD (`961341524729`) was NOT touched.** None of these changes have been
> promoted to prod, committed to git, or captured as migration files. They live
> only in the running dev DB, the dev Lambda deployment package, and the dev
> QuickSight analysis/dashboard, plus the repo working tree for two Python files.

---

## 1. Summary of what was reconciled

| Metric | Result after fixes (all 35 weeks 2026-01-05 → 2026-08-31) |
| --- | --- |
| Headcount / staff count | Matches across OKR / Practice / Staff |
| Total billable hours | Matches across OKR / Practice / Staff |
| Billable utilization % | Matches across OKR / Practice / Staff (data + tile) |
| Time compliance % | **Intentionally left divergent** — not changed per instruction |

Verification query result: 35/35 weeks match on headcount, billable hours, and
billable util.

---

## 2. Canonical population applied

The reconciliation standardized the "who counts" population to:

- `status = 'active'`
- `daily_capacity > 0`
- `time_submission` IS NULL OR `UPPER(TRIM(time_submission)) != 'NO'`
- `NOT COALESCE(reporting_excluded, FALSE)`
- pod NOT exempt: `pod_assignment IS NULL OR pod_assignment NOT ILIKE '%exempt%'`
- new-user cutoff: `created_at::DATE <= week_end` (week_start + 6)
- blank practice kept and bucketed as `'Not Assigned'` (not dropped)
- current in-progress week excluded

---

## 3. Changes made (with rollback for each)

### CHANGE 1 — Escalations pipeline ordering (earlier fix, related)

**File:** `src/handlers/pipeline.py`
**What:** Moved the escalations import from step 7 to step 3b (before the KPI
snapshot at step 4), so `open_escalations` is populated before the snapshot
reads it. Updated docstring.

**Rollback:** Move the `# ── 3b. Escalations import ──` block back to its original
position between step 6 (MC V2 Audit) and step 8 (Collect statistics), and
restore the docstring step list (escalations = step 7).

---

### CHANGE 2 — Escalation open-count definition (earlier fix, related)

**File:** `src/integrations/kpi_snapshot.py`, function `_compute_escalation_metrics`
**What:** Aligned the open/high/med/avg-days escalation counts with
`vw_escalations_by_customer`:
- open now = `status_category != 'Done'` (was `resolution_date IS NULL AND
  status_category NOT IN ('Done','Resolved')`)
- added `WHERE customer_name IS NOT NULL`

**Rollback — restore the original query:**

```sql
SELECT
    SUM(CASE WHEN resolution_date IS NULL
              AND COALESCE(status_category,'') NOT IN ('Done','Resolved')
             THEN 1 ELSE 0 END)                          AS open_escalations,
    SUM(CASE WHEN priority IN ('Highest','High')
              AND resolution_date IS NULL
              AND COALESCE(status_category,'') NOT IN ('Done','Resolved')
             THEN 1 ELSE 0 END)                          AS high_priority,
    SUM(CASE WHEN priority = 'Medium'
              AND resolution_date IS NULL
              AND COALESCE(status_category,'') NOT IN ('Done','Resolved')
             THEN 1 ELSE 0 END)                          AS med_priority,
    ROUND(AVG(CASE
        WHEN resolution_date IS NULL
         AND COALESCE(status_category,'') NOT IN ('Done','Resolved')
        THEN CURRENT_DATE - created_date::DATE
        ELSE NULL END)::NUMERIC, 2)                      AS avg_days_open,
    SUM(CASE
        WHEN resolution_date IS NOT NULL
         AND resolution_date >= :ys
        THEN 1 ELSE 0 END)                               AS resolved_ytd
FROM escalations
```
(remove the `WHERE customer_name IS NOT NULL` line.)

---

### CHANGE 3 — OKR billable-hours population filter

**File:** `src/integrations/kpi_snapshot.py`, function `_compute_utilization`,
the `hours` (billable/presales) subquery.
**What:** Added `status='active'`, `daily_capacity>0`, `time_submission!='NO'`
to the billable/presales subquery so it uses the canonical active population
(previously only `reporting_excluded` + exempt-pod were applied).

**Rollback — restore the original WHERE clause of the `hours` subquery to:**

```sql
        WHERE te.entry_date BETWEEN :ws AND :we
          AND te.duration_hours > 0
          AND NOT COALESCE(u.reporting_excluded, FALSE)
          AND (u.pod_assignment IS NULL OR u.pod_assignment NOT ILIKE '%exempt%')
```
(remove the three added lines: `AND u.status = 'active'`,
`AND u.daily_capacity > 0`, `AND (u.time_submission IS NULL OR
UPPER(TRIM(u.time_submission)) != 'NO')`.)

---

### CHANGE 4 — OKR headcount / available-hours new-user cutoff

**File:** `src/integrations/kpi_snapshot.py`, function `_compute_utilization`,
the `avail` (total_available / active_count) subquery.
**What:** Added `AND created_at::DATE <= :we` so headcount and the util
denominator are point-in-time consistent with the views (historical weeks were
counting today's roster).

**Rollback — restore the original `avail` query to (remove the cutoff line and
the `:we` param binding on that query):**

```sql
SELECT
    COALESCE(SUM(daily_capacity * 5), 0)  AS total_available,
    COUNT(*)                               AS active_count
FROM clockify_users
WHERE status = 'active'
  AND daily_capacity > 0
  AND (time_submission IS NULL OR UPPER(TRIM(time_submission)) != 'NO')
  AND NOT COALESCE(reporting_excluded, FALSE)
  AND (pod_assignment IS NULL OR pod_assignment NOT ILIKE '%exempt%')
```
Note: after rollback the `avail` query no longer needs a parameter; the original
used `.fetchone()` with no bind params.

---

### CHANGE 5 — `vw_practice_kpi_weekly` view (LIVE DDL, not a migration)

**Object:** PostgreSQL view `vw_practice_kpi_weekly` in the dev DB
(`production-weekly-reporting`, db `weekly_reporting`).
**Applied via:** Lambda `run_query_master` mode (owner credentials) — a
`CREATE OR REPLACE VIEW`.
**What changed (population only; all columns, NB heuristic, and `compliance_pct`
preserved):**
1. `active_users` WHERE: added `AND (u_1.pod_assignment IS NULL OR
   u_1.pod_assignment NOT ILIKE '%exempt%')`
2. Removed `AND cleaned.practice_alignment <> ''`; practice_alignment now
   `COALESCE(NULLIF(cleaned.practice_alignment, ''), 'Not Assigned')` (and the
   `lob_practice_mapping` join uses the same COALESCE).
3. Added `u_1.created_at::date AS user_created_date` to `active_users` and a
   final `WHERE u.user_created_date <= w.week_start + 6`.
4. Week spine: added `AND date_trunc('week', entry_date)::date <
   date_trunc('week', CURRENT_DATE)::date` (exclude current week).

> **IMPORTANT:** The live view before this change was the OLDER definition using
> the `project_type` / `mapped_clients` NB heuristic — **NOT** migration 106's
> `is_nb_productive` / `is_nb_non_productive` custom-field logic. Migration 106
> was never applied to this DB. The rollback DDL below restores that exact
> pre-change definition.

**Rollback — run this exact DDL via `run_query_master` to restore the original
view:**

```sql
CREATE OR REPLACE VIEW vw_practice_kpi_weekly AS
 WITH mapped_clients AS (
         SELECT DISTINCT lower(ps_project_mapping.clockify_client_name::text) AS client_lower
           FROM ps_project_mapping
          WHERE ps_project_mapping.is_active = true
        ), active_users AS (
         SELECT u_1.clockify_user_id,
            u_1.name,
            u_1.daily_capacity,
            u_1.daily_capacity * 5::double precision AS weekly_capacity,
            cleaned.practice_alignment,
            COALESCE(m.line_of_business, 'Internal'::character varying) AS line_of_business
           FROM clockify_users u_1
             CROSS JOIN LATERAL ( SELECT TRIM(BOTH FROM replace(replace(replace(replace(COALESCE(u_1.practice_alignment, ''::character varying)::text, '{'::text, ''::text), '}'::text, ''::text), '"'::text, ''::text), chr(39), ''::text)) AS practice_alignment) cleaned
             LEFT JOIN lob_practice_mapping m ON m.practice_alignment::text = cleaned.practice_alignment
          WHERE u_1.status::text = 'active'::text AND u_1.daily_capacity > 0::double precision AND NOT COALESCE(u_1.reporting_excluded, false) AND (u_1.time_submission IS NULL OR upper(TRIM(BOTH FROM u_1.time_submission)) <> 'NO'::text) AND cleaned.practice_alignment <> ''::text
        ), weekly_hours AS (
         SELECT te.clockify_user_id,
            date_trunc('week'::text, te.entry_date::timestamp with time zone)::date AS week_start,
            sum(te.duration_hours) AS hours_logged,
            sum(
                CASE
                    WHEN te.billable THEN te.duration_hours
                    ELSE 0::double precision
                END) AS billable_hours,
            sum(
                CASE
                    WHEN te.billable = false AND ((cp.project_type::text = ANY (ARRAY['Non Bill Productive'::character varying, 'Overtime'::character varying, 'Presales'::character varying]::text[])) OR cp.project_type IS NULL AND mc.client_lower IS NOT NULL OR (cp.project_type::text <> ALL (ARRAY['Non Bill Productive'::character varying, 'Non Bill Non Productive'::character varying, 'Overtime'::character varying, 'Presales'::character varying]::text[])) AND cp.project_type IS NOT NULL AND mc.client_lower IS NOT NULL) THEN te.duration_hours
                    ELSE 0::double precision
                END) AS productive_nb_hours,
            sum(
                CASE
                    WHEN te.billable = false AND NOT ((cp.project_type::text = ANY (ARRAY['Non Bill Productive'::character varying, 'Overtime'::character varying, 'Presales'::character varying]::text[])) OR cp.project_type IS NULL AND mc.client_lower IS NOT NULL OR (cp.project_type::text <> ALL (ARRAY['Non Bill Productive'::character varying, 'Non Bill Non Productive'::character varying, 'Overtime'::character varying, 'Presales'::character varying]::text[])) AND cp.project_type IS NOT NULL AND mc.client_lower IS NOT NULL) THEN te.duration_hours
                    ELSE 0::double precision
                END) AS nb_non_productive_hours
           FROM clockify_detailed_time_entries te
             LEFT JOIN clockify_projects cp ON te.clockify_project_id::text = cp.clockify_project_id::text
             LEFT JOIN mapped_clients mc ON lower(te.client_name::text) = mc.client_lower
          WHERE te.entry_date >= (date_trunc('week'::text, CURRENT_DATE::timestamp with time zone)::date - '364 days'::interval)
          GROUP BY te.clockify_user_id, (date_trunc('week'::text, te.entry_date::timestamp with time zone)::date)
        )
 SELECT u.line_of_business,
    u.practice_alignment,
    w.week_start,
    EXTRACT(year FROM w.week_start)::integer AS year_num,
    EXTRACT(quarter FROM w.week_start)::integer AS quarter_num,
    concat('Q', EXTRACT(quarter FROM w.week_start)::integer, ' ', EXTRACT(year FROM w.week_start)::integer) AS quarter_label,
    count(DISTINCT u.clockify_user_id) AS headcount,
    sum(u.weekly_capacity) AS total_capacity_hours,
    COALESCE(sum(h.hours_logged), 0::double precision) AS total_hours_logged,
    COALESCE(sum(h.billable_hours), 0::double precision) AS total_billable_hours,
    round((COALESCE(sum(h.billable_hours), 0::double precision) / NULLIF(sum(u.weekly_capacity), 0::double precision) * 100::double precision)::numeric, 1) AS billable_util_pct,
    round(((COALESCE(sum(h.billable_hours), 0::double precision) + COALESCE(sum(h.productive_nb_hours), 0::double precision)) / NULLIF(sum(u.weekly_capacity), 0::double precision) * 100::double precision)::numeric, 1) AS productive_util_pct,
    COALESCE(sum(h.productive_nb_hours), 0::double precision) AS total_productive_nb_hours,
    COALESCE(sum(h.nb_non_productive_hours), 0::double precision) AS total_nb_non_productive_hours,
    round((COALESCE(sum(h.hours_logged), 0::double precision) / NULLIF(sum(u.weekly_capacity), 0::double precision) * 100::double precision)::numeric, 1) AS total_util_pct,
    count(DISTINCT
        CASE
            WHEN h.hours_logged >= (u.weekly_capacity * 0.9::double precision) THEN u.clockify_user_id
            ELSE NULL::character varying
        END) AS compliant_count,
    round(count(DISTINCT
        CASE
            WHEN h.hours_logged >= (u.weekly_capacity * 0.9::double precision) THEN u.clockify_user_id
            ELSE NULL::character varying
        END)::numeric / NULLIF(count(DISTINCT u.clockify_user_id), 0)::numeric * 100::numeric, 1) AS compliance_pct
   FROM active_users u
     CROSS JOIN ( SELECT DISTINCT date_trunc('week'::text, clockify_detailed_time_entries.entry_date::timestamp with time zone)::date AS week_start
           FROM clockify_detailed_time_entries
          WHERE clockify_detailed_time_entries.entry_date >= (date_trunc('week'::text, CURRENT_DATE::timestamp with time zone)::date - '364 days'::interval)) w
     LEFT JOIN weekly_hours h ON u.clockify_user_id::text = h.clockify_user_id::text AND h.week_start = w.week_start
  GROUP BY u.line_of_business, u.practice_alignment, w.week_start
  ORDER BY w.week_start DESC, u.line_of_business, u.practice_alignment;
```

---

### CHANGE 6 — OKR Scorecard: new "NB Productive Hrs" tile

**Object:** QuickSight analysis `kpi-tracking-analysis-dev`, sheet
`sheet-kpi-s1` (OKR Scorecard); published to dashboard
`kpi-tracking-dashboard-dev`.
**What:** Added KPI tile `kpi-s1-nb-prod` titled "NB Productive Hrs":
- Value: `productive_nb_hours` (MAX), dataset identifier `kpi_snapshots`
- Target: `productive_nb_prev` (MAX), comparison DIFFERENCE
- Layout element at ColumnIndex 9, RowIndex 10, ColumnSpan 9, RowSpan 4.

**Rollback:** Remove the visual with `VisualId = 'kpi-s1-nb-prod'` from
`sheet-kpi-s1` `Visuals`, and remove the matching layout element
(`ElementId = 'kpi-s1-nb-prod'`) from that sheet's GridLayout. Update the
analysis and re-publish the dashboard.

---

### CHANGE 7 — Practice Scorecard: billable-util tile math

**Object:** QuickSight analysis `kpi-tracking-analysis-dev`, sheet
`sheet-kpi-s2` (Practice Scorecard), tile `kpi-s2-billable`; published to
dashboard `kpi-tracking-dashboard-dev`.
**What:**
1. Added calculated field on dataset identifier `kpi_practice`:
   `practice_billable_util_weighted =
    sum({total_billable_hours}) / nullIf(sum({total_capacity_hours}), 0) * 100`
2. Repointed tile `kpi-s2-billable` value from
   `AVERAGE(weighted_billable_util)` to `practice_billable_util_weighted`
   (aggregate expression, no aggregation wrapper).

Reason: the tile was averaging per-practice rates (unweighted), showing ~52.5
vs the true weighted org ratio 46.62.

**Rollback:** Restore the tile value FieldWell to:
```json
{"NumericalMeasureField": {
  "FieldId": "kp-f3",
  "Column": {"DataSetIdentifier": "kpi_practice", "ColumnName": "weighted_billable_util"},
  "AggregationFunction": {"SimpleNumericalAggregation": "AVERAGE"}
}}
```
Optionally remove the `practice_billable_util_weighted` calculated field.
(The `weighted_billable_util` calc field was NOT removed and still exists.)

---

## 4. Deployment & data operations performed

| Action | Detail |
| --- | --- |
| Lambda code | `production-clockify-import` (dev) updated 3× by patching `src/handlers/pipeline.py` and `src/integrations/kpi_snapshot.py` into the existing zip. |
| Snapshot backfill | `snapshot_kpis` re-run for all 35 weeks 2026-01-05 → 2026-08-31 (upserts on `week_start_date`). |
| SPICE refresh | `kpi-weekly-snapshots-prod`, `kpi-practice-weekly-prod`, `kpi-staff-weekly-prod` (dev account) — all COMPLETED. |
| Dashboard | `kpi-tracking-dashboard-dev` published versions 7 (NB tile) and 8 (util tile fix). |

### To fully reverse everything
1. Revert Python changes (CHANGES 1–4) in the repo working tree, re-patch the
   Lambda zip, and redeploy `production-clockify-import`.
2. Run the CHANGE 5 rollback DDL via `run_query_master`.
3. Re-run `snapshot_kpis` for all 35 weeks to overwrite the reconciled values.
4. Refresh the three SPICE datasets.
5. Revert CHANGES 6 & 7 in the analysis and re-publish the dashboard.

---

## 5. Not changed (by instruction)

- **Time compliance %** — left divergent across sheets:
  - OKR snapshot: compliant = `hours_logged > 0`, org-level.
  - Staff Detail: compliant = `hours_logged >= 90% of weekly capacity`, org-level.
  - Practice Scorecard: `>= 90%` threshold but shown as unweighted average of
    per-practice rates.
- **ES-232** (null-customer escalation) — data-quality item in Jira, not fixed.
- **Prod account** — untouched.
- **Migration files / git** — not updated; changes are runtime-only in dev.

# MC Service Delivery Sheet — Removal & Rebuild Guide

**Date removed:** 2026-09-08
**Environment:** DEV only — AWS account `604775478093`, region `us-east-1`
**Analysis:** `kpi-tracking-analysis-dev` · **Dashboard:** `kpi-tracking-dashboard-dev`

---

## 1. What was removed

- **Sheet** `sheet-kpi-mc` ("MC Service Delivery") — removed from the analysis and
  republished to the dashboard (**dashboard version 9**).
- The `mc_ticket_activity` **DataSetIdentifierDeclaration** was removed from the
  analysis (it was used only by this sheet — verified: 0 references elsewhere).

**NOT removed (still available for rebuild):**
- View `vw_mc_ticket_activity` (dev DB) — untouched.
- QuickSight dataset `mc-ticket-activity` — untouched.
- Original build script `scripts/add_mc_sheet.py` — untouched.

Removal was done live via `update_analysis` + `update_dashboard`; no data or
underlying objects were deleted.

---

## 2. Why it was removed

The sheet's tiles were only partially meaningful:

| Tile | Definition | Assessment |
| --- | --- | --- |
| Total MC Hours | `SUM(clockify_hours)` | ✅ Meaningful — weekly effort on MC/Managed IT/FinOps projects. |
| Total MC Billable Hours | `SUM(billable_hours)` | ⚠️ Redundant — equals Total MC Hours in current data (all MC time flags billable). |
| Total MC Issues | `SUM(total_issues)` | ❌ Misleading — `total_issues` is each customer's **cumulative open backlog**, so summing it produces a monotonically growing lifetime total, not a weekly delivery stat. |

Additional problems:
- The sheet did **not** exclude the current in-progress week (partial-week rows
  show near-zero hours next to completed weeks).
- `open_escalations` read 0 across all rows (either genuinely zero or a
  customer-name join mismatch) — a column of zeros in the table.
- No real service-delivery KPIs (throughput, backlog trend, SLA/on-time) were
  surfaced, even though the view exposes `updated_this_week`, `done_issues`,
  `open_issues`, `updated_wow_delta`, `health_overall`.

---

## 3. Underlying data — `vw_mc_ticket_activity`

**Grain:** one row per **MC customer per week** (~28 customers/week).

**Columns available:**

| Column | Meaning |
| --- | --- |
| `week_start` | Monday of the week |
| `customer_name` | MC customer |
| `jira_project_key` | Jira project |
| `total_issues` | **Cumulative** ticket count for the customer (NOT weekly) |
| `open_issues` | Currently open tickets |
| `in_progress_issues` | In-progress tickets |
| `done_issues` | Done tickets (cumulative) |
| `updated_this_week` | Tickets updated during the week (**throughput proxy**) |
| `updated_wow_delta` | `updated_this_week` minus prior week |
| `health_overall` | Jira health status |
| `clockify_hours` | MC/Managed IT/FinOps hours logged that week (from Clockify, project_type in Managed Cloud / Managed Cloud and Managed IT / Managed IT / FinOps) |
| `billable_hours` | Of those, billable |
| `open_escalations` | Open escalations for the customer (joined by lower(customer_name)) |

Sources joined: `mc_ticket_activity_snapshot` (Jira) + Clockify hours subquery +
open-escalations subquery.

---

## 4. How to rebuild the sheet (improved version)

The original build script is `scripts/add_mc_sheet.py`. To recreate a **more
meaningful** version, use it as a base with these changes:

### Recommended tiles

1. **Total MC Hours** — `SUM(clockify_hours)` (keep as-is; the MC-01 fix already
   changed this from MAX to SUM).
2. **Tickets Worked This Week** — `SUM(updated_this_week)` (replaces the
   misleading `SUM(total_issues)` — this is actual weekly throughput).
3. **Open Backlog** — `SUM(open_issues)` (current load; distinct from cumulative
   `total_issues`).
4. *(Optional)* **Total MC Billable Hours** — only keep if billable ≠ total once
   the Clockify billable flag is validated for MC projects; otherwise drop.

### Recommended table (by customer)

Group by `customer_name`, columns:
`SUM(clockify_hours)`, `SUM(updated_this_week)`, `SUM(open_issues)`,
`SUM(done_issues)`, `SUM(open_escalations)`.

### Mandatory filter — exclude the current in-progress week

Add a filter group scoped to the sheet on `week_start`:
- Either a `RelativeDatesFilter` (LAST N weeks) plus a
  `TimeRangeFilter` guard excluding the current week, mirroring the OKR sheet's
  `completed_weeks_filter` pattern in `scripts/build_kpi_dashboard.py`, or
- a filter `week_start < truncDate('WK', now())`.

### Before rebuilding — validate these two data issues

1. **Billable vs total:** confirm whether `billable_hours` legitimately differs
   from `clockify_hours` for MC projects. If they are always equal, drop the
   billable tile.
2. **open_escalations join:** confirm `escalations.customer_name` values match
   `mc_ticket_activity_snapshot.customer_name` (lowercased). If they never
   match, the column will read 0 — fix the join key or drop the column.

---

## 5. Rebuild procedure

1. Ensure the dataset identifier is re-declared in the analysis:
   `Identifier='mc_ticket_activity'`,
   `DataSetArn='arn:aws:quicksight:us-east-1:<ACCT>:dataset/mc-ticket-activity'`.
2. Build the sheet (SheetId `sheet-kpi-mc`, Name "MC Service Delivery") with the
   tiles/table above and the completed-week filter group.
3. `update_analysis` → poll to `UPDATE_SUCCESSFUL`.
4. Re-derive dashboard definition from the analysis, `update_dashboard`, poll,
   then `update_dashboard_published_version`.
5. Ensure the `mc-ticket-activity` SPICE dataset is on the pipeline refresh list
   (`src/handlers/quicksight.py` already includes `mc-ticket-activity`).

### Quick restore of the ORIGINAL (unimproved) sheet

Re-run the original script as-is:
```bash
python3 scripts/add_mc_sheet.py
```
Then publish the dashboard from the updated analysis. This restores the exact
sheet that was removed (3 tiles: Total MC Hours, Total MC Billable Hours, Total
MC Issues + by-customer table) — note it carries the limitations described in
§2.

---

## 6. Environment note

All actions were DEV only (`604775478093`). PROD (`961341524729`) is unaffected.
Changes are runtime-only (analysis/dashboard); not committed to git.

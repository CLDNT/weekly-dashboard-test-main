-- Optimized views for QuickSight reporting
-- Run this file after initializing the database

-- ============================================================
-- Pre-drop dependent views to avoid CASCADE conflicts
-- These views depend on base views that are recreated below.
-- Dropping them first allows clean recreation in dependency order.
-- ============================================================
DROP VIEW IF EXISTS vw_mc_projects_at_risk CASCADE;
DROP VIEW IF EXISTS vw_ps_projects_at_risk CASCADE;
DROP VIEW IF EXISTS vw_ps_delivery_projects CASCADE;
DROP VIEW IF EXISTS vw_staff_kpi_weekly CASCADE;
DROP VIEW IF EXISTS vw_staff_ontime_delivery CASCADE;
DROP VIEW IF EXISTS vw_project_closure_status CASCADE;

-- ============================================================
-- Schema Fixes
-- ============================================================
-- Allow NULL clockify_user_id in forecasts (for users not in Clockify)
ALTER TABLE ps_resource_forecasts ALTER COLUMN clockify_user_id DROP NOT NULL;

-- Migration 101: Add resolution_date to ps_project_status (Jira system field)
ALTER TABLE ps_project_status ADD COLUMN IF NOT EXISTS resolution_date TIMESTAMP WITH TIME ZONE;
CREATE INDEX IF NOT EXISTS idx_ps_resolution_date ON ps_project_status(resolution_date) WHERE resolution_date IS NOT NULL;

-- ============================================================
-- View 1: Weekly Time Summary by Practice Alignment and Location
-- ============================================================
DROP VIEW IF EXISTS vw_weekly_time_summary;
CREATE VIEW vw_weekly_time_summary AS
SELECT
    DATE_TRUNC('week', entry_date)::DATE AS week_start_date,
    DATE_TRUNC('week', entry_date)::DATE + INTERVAL '6 days' AS week_end_date,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')) AS practice_alignment,
    location,
    COUNT(DISTINCT clockify_user_id) AS unique_resources,
    COUNT(*) AS total_entries,
    SUM(duration_hours) AS total_hours,
    SUM(CASE WHEN billable THEN duration_hours ELSE 0 END) AS billable_hours,
    SUM(CASE WHEN NOT billable THEN duration_hours ELSE 0 END) AS non_billable_hours,
    AVG(duration_hours) AS avg_hours_per_entry
FROM clockify_detailed_time_entries
GROUP BY DATE_TRUNC('week', entry_date)::DATE,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')),
    location;

-- ============================================================
-- View 2: Resource Utilization Summary
-- ============================================================
DROP VIEW IF EXISTS vw_resource_utilization;
CREATE VIEW vw_resource_utilization AS
SELECT
    DATE_TRUNC('week', te.entry_date)::DATE AS week_start_date,
    te.clockify_user_id,
    te.user_name,
    u.cloudelligent_title,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')) AS practice_alignment,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.skill_area, '{', ''), '}', ''), '"', ''), '\', '')) AS skill_area,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')) AS pod_assignment,
    u.location,
    u.employment_designation,
    u.daily_capacity,
    u.daily_capacity * 5 AS weekly_capacity,
    -- Current workspace membership status
    CASE WHEN u.status = 'active' THEN 'Yes' ELSE 'No' END AS is_active_member,
    SUM(te.duration_hours) AS actual_hours,
    ROUND((SUM(te.duration_hours) / NULLIF(u.daily_capacity * 5, 0) * 100)::NUMERIC, 2) AS utilization_percent,
    SUM(CASE WHEN te.billable THEN te.duration_hours ELSE 0 END) AS billable_hours,
    ROUND((SUM(CASE WHEN te.billable THEN te.duration_hours ELSE 0 END) / NULLIF(SUM(te.duration_hours), 0) * 100)::NUMERIC, 2) AS billable_percent
FROM clockify_detailed_time_entries te
JOIN clockify_users u ON te.clockify_user_id = u.clockify_user_id
GROUP BY
    DATE_TRUNC('week', te.entry_date)::DATE,
    te.clockify_user_id,
    te.user_name,
    u.cloudelligent_title,
    u.practice_alignment,
    u.skill_area,
    u.pod_assignment,
    u.location,
    u.employment_designation,
    u.daily_capacity,
    u.status;

-- ============================================================
-- View 3: Project Time Tracking
-- ============================================================
DROP VIEW IF EXISTS vw_project_time_tracking;
CREATE VIEW vw_project_time_tracking AS
SELECT
    DATE_TRUNC('week', entry_date)::DATE AS week_start_date,
    project_name,
    client_name,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')) AS practice_alignment,
    COUNT(DISTINCT clockify_user_id) AS resources_assigned,
    SUM(duration_hours) AS total_hours,
    SUM(CASE WHEN billable THEN duration_hours ELSE 0 END) AS billable_hours,
    COUNT(*) AS entry_count,
    MIN(entry_date) AS first_entry_date,
    MAX(entry_date) AS last_entry_date
FROM clockify_detailed_time_entries
GROUP BY
    DATE_TRUNC('week', entry_date)::DATE,
    project_name,
    client_name,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', ''));

-- ============================================================
-- View 4: Client Time Summary
-- ============================================================
DROP VIEW IF EXISTS vw_client_time_summary;
CREATE VIEW vw_client_time_summary AS
SELECT
    DATE_TRUNC('week', entry_date)::DATE AS week_start_date,
    client_name,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')) AS practice_alignment,
    COUNT(DISTINCT project_name) AS active_projects,
    COUNT(DISTINCT clockify_user_id) AS resources_working,
    SUM(duration_hours) AS total_hours,
    SUM(CASE WHEN billable THEN duration_hours ELSE 0 END) AS billable_hours,
    COUNT(*) AS total_entries
FROM clockify_detailed_time_entries
WHERE client_name IS NOT NULL
GROUP BY
    DATE_TRUNC('week', entry_date)::DATE,
    client_name,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', ''));

-- ============================================================
-- View 5: Skill Area Distribution
-- ============================================================
DROP VIEW IF EXISTS vw_skill_area_summary;
CREATE VIEW vw_skill_area_summary AS
SELECT
    DATE_TRUNC('week', entry_date)::DATE AS week_start_date,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(skill_area, '{', ''), '}', ''), '"', ''), '\', '')) AS skill_area,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')) AS practice_alignment,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')) AS pod_assignment,
    location,
    COUNT(DISTINCT clockify_user_id) AS unique_resources,
    SUM(duration_hours) AS total_hours,
    SUM(CASE WHEN billable THEN duration_hours ELSE 0 END) AS billable_hours
FROM clockify_detailed_time_entries
WHERE skill_area IS NOT NULL
GROUP BY
    DATE_TRUNC('week', entry_date)::DATE,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(skill_area, '{', ''), '}', ''), '"', ''), '\', '')),
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')),
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')),
    location;

-- ============================================================
-- View 6: Daily Activity Trend
-- ============================================================
DROP VIEW IF EXISTS vw_daily_activity_trend;
CREATE VIEW vw_daily_activity_trend AS
SELECT
    entry_date,
    EXTRACT(DOW FROM entry_date) AS day_of_week,
    TO_CHAR(entry_date, 'Day') AS day_name,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')) AS practice_alignment,
    location,
    COUNT(DISTINCT clockify_user_id) AS active_resources,
    SUM(duration_hours) AS total_hours,
    SUM(CASE WHEN billable THEN duration_hours ELSE 0 END) AS billable_hours,
    COUNT(*) AS entry_count
FROM clockify_detailed_time_entries
GROUP BY entry_date,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')),
    location;

-- ============================================================
-- View 7: Resource Directory (Active Users)
-- ============================================================
DROP VIEW IF EXISTS vw_active_resources;
CREATE VIEW vw_active_resources AS
SELECT
    u.clockify_user_id,
    u.name,
    u.email,
    u.cloudelligent_title,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')) AS practice_alignment,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.skill_area, '{', ''), '}', ''), '"', ''), '\', '')) AS skill_area,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')) AS pod_assignment,
    u.location,
    u.employment_designation,
    u.daily_capacity,
    u.status,
    u.updated_at AS last_profile_update,
    COALESCE(recent.last_entry_date, NULL) AS last_time_entry_date,
    COALESCE(recent.hours_last_30_days, 0) AS hours_last_30_days
FROM clockify_users u
LEFT JOIN (
    SELECT
        clockify_user_id,
        MAX(entry_date) AS last_entry_date,
        SUM(CASE WHEN entry_date >= CURRENT_DATE - INTERVAL '30 days' THEN duration_hours ELSE 0 END) AS hours_last_30_days
    FROM clockify_detailed_time_entries
    GROUP BY clockify_user_id
) recent ON u.clockify_user_id = recent.clockify_user_id
WHERE u.status = 'active';

-- ============================================================
-- View 8: Import Activity Log
-- ============================================================
CREATE OR REPLACE VIEW vw_import_activity AS
SELECT
    log_id,
    import_type,
    import_category,
    start_date,
    end_date,
    records_imported,
    records_updated,
    records_skipped,
    status,
    error_message,
    started_at,
    completed_at,
    EXTRACT(EPOCH FROM (completed_at - started_at)) AS duration_seconds
FROM import_logs
ORDER BY completed_at DESC;

-- ============================================================
-- View 9: Practice Alignment Performance (Last 12 Weeks)
-- ============================================================
DROP VIEW IF EXISTS vw_practice_alignment_performance_12w;
CREATE VIEW vw_practice_alignment_performance_12w AS
SELECT
    DATE_TRUNC('week', entry_date)::DATE AS week_start_date,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')) AS practice_alignment,
    COUNT(DISTINCT clockify_user_id) AS unique_resources,
    SUM(duration_hours) AS total_hours,
    SUM(CASE WHEN billable THEN duration_hours ELSE 0 END) AS billable_hours,
    ROUND((SUM(CASE WHEN billable THEN duration_hours ELSE 0 END) / NULLIF(SUM(duration_hours), 0) * 100)::NUMERIC, 2) AS billable_percent,
    COUNT(DISTINCT project_name) AS active_projects,
    COUNT(DISTINCT client_name) AS active_clients
FROM clockify_detailed_time_entries
WHERE entry_date >= CURRENT_DATE - INTERVAL '12 weeks'
GROUP BY DATE_TRUNC('week', entry_date)::DATE,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', ''))
ORDER BY week_start_date DESC, practice_alignment;

-- ============================================================
-- View 10: Monthly Summary (for historical trending)
-- ============================================================
DROP VIEW IF EXISTS vw_monthly_summary;

CREATE VIEW vw_monthly_summary AS
SELECT
    DATE_TRUNC('month', entry_date)::DATE AS month_start_date,
    TO_CHAR(entry_date, 'YYYY-MM') AS year_month,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')) AS practice_alignment,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')) AS pod_assignment,
    location,
    COUNT(DISTINCT clockify_user_id) AS unique_resources,
    SUM(duration_hours) AS total_hours,
    SUM(CASE WHEN billable THEN duration_hours ELSE 0 END) AS billable_hours,
    ROUND((SUM(CASE WHEN billable THEN duration_hours ELSE 0 END) / NULLIF(SUM(duration_hours), 0) * 100)::NUMERIC, 2) AS billable_percent,
    COUNT(DISTINCT project_name) AS active_projects,
    COUNT(DISTINCT client_name) AS active_clients,
    AVG(duration_hours) AS avg_hours_per_entry
FROM clockify_detailed_time_entries
GROUP BY DATE_TRUNC('month', entry_date)::DATE, TO_CHAR(entry_date, 'YYYY-MM'),
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')),
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')),
    location;

-- ============================================================
-- View 11: Missing Time Submissions
-- Shows active users who haven't submitted time for the prior week
-- Uses week_start column for efficient filtering
-- Synced from migration 075
CREATE OR REPLACE VIEW vw_missing_time_submissions AS
WITH last_complete_week AS (
    SELECT (DATE_TRUNC('week', CURRENT_DATE)::DATE - 7)::DATE AS week_start_date
),
user_hours_last_week AS (
    SELECT te.clockify_user_id,
           SUM(te.duration_hours) AS total_hours,
           COUNT(*) AS entry_count
    FROM clockify_detailed_time_entries te
    WHERE te.week_start = (SELECT week_start_date FROM last_complete_week)
    GROUP BY te.clockify_user_id
),
last_clockify_import AS (
    SELECT (completed_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Chicago')::DATE AS last_updated_date,
           TO_CHAR(completed_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Chicago', 'HH:MI AM') AS last_updated_time
    FROM import_logs
    WHERE import_category = 'time_entries' AND status = 'success'
    ORDER BY completed_at DESC LIMIT 1
)
SELECT
    u.clockify_user_id, u.name, u.email,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.pod_assignment,     '{',''),'}',''),'"',''),chr(92),'')) AS pod_assignment,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.practice_alignment, '{',''),'}',''),'"',''),chr(92),'')) AS practice_alignment,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.skill_area,         '{',''),'}',''),'"',''),chr(92),'')) AS skill_area,
    u.location, u.daily_capacity, u.daily_capacity * 5 AS weekly_expected_hours,
    COALESCE(h.total_hours, 0) AS hours_submitted,
    COALESCE(h.entry_count, 0) AS entries_submitted,
    CASE WHEN COALESCE(h.total_hours, 0) = 0 THEN 'No Time Submitted' ELSE 'Complete' END AS submission_status,
    CASE
        WHEN COALESCE(h.total_hours, 0) = 0  THEN '0 Hours'
        WHEN COALESCE(h.total_hours, 0) < 20 THEN '1-19 Hours'
        WHEN COALESCE(h.total_hours, 0) < 30 THEN '20-29 Hours'
        ELSE '30+ Hours'
    END AS hours_bucket,
    (SELECT week_start_date   FROM last_complete_week)   AS week_start_date,
    (SELECT last_updated_date FROM last_clockify_import) AS last_updated_date,
    (SELECT last_updated_time FROM last_clockify_import) AS last_updated_time
FROM clockify_users u
LEFT JOIN user_hours_last_week h ON u.clockify_user_id = h.clockify_user_id
WHERE u.status = 'active'
  AND u.daily_capacity > 0
  AND (u.pod_assignment IS NULL OR u.pod_assignment NOT ILIKE '%exempt%')
  AND (u.time_submission IS NULL OR UPPER(TRIM(u.time_submission)) != 'NO')
  AND NOT COALESCE(u.reporting_excluded, FALSE)
  AND u.created_at::DATE <= (SELECT week_start_date FROM last_complete_week) + INTERVAL '6 days'
  AND COALESCE(h.total_hours, 0) = 0
ORDER BY u.pod_assignment, u.name;

-- ============================================================
-- View 12: Pod Performance Analysis with Trends
-- Averages are calculated over exactly 12 previous weeks
-- (weeks 2-13, excluding last week) with 0 hours for missing weeks
-- ============================================================
DROP VIEW IF EXISTS vw_pod_performance_analysis;
CREATE VIEW vw_pod_performance_analysis AS
WITH
-- Generate week numbers: week 1 = last complete week, week 2-13 = previous 12 weeks
all_weeks AS (
    SELECT
        (DATE_TRUNC('week', CURRENT_DATE)::DATE - (n * 7))::DATE AS week_start_date,
        n AS weeks_ago
    FROM generate_series(1, 13) AS n
),
-- All pods we care about
all_pods AS (
    SELECT unnest(ARRAY['Free Agent', 'Alpha', 'Bravo', 'Charlie', 'A2Z', 'Unassigned']) AS pod_name
),
-- Cross join to get all pod-week combinations
pod_weeks AS (
    SELECT
        w.week_start_date,
        w.weeks_ago,
        p.pod_name
    FROM all_weeks w
    CROSS JOIN all_pods p
),
-- Actual weekly hours per pod
-- Clean Clockify JSON formatting from pod_assignment: {Bravo} -> Bravo, {"Free Agent"} -> Free Agent
weekly_pod_hours AS (
    SELECT
        DATE_TRUNC('week', entry_date)::DATE AS week_start_date,
        COALESCE(NULLIF(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')), ''), 'Unassigned') AS pod_name,
        SUM(duration_hours) AS total_hours,
        SUM(CASE WHEN billable THEN duration_hours ELSE 0 END) AS billable_hours,
        COUNT(DISTINCT clockify_user_id) AS unique_resources
    FROM clockify_detailed_time_entries
    WHERE entry_date >= CURRENT_DATE - INTERVAL '120 days'
      AND COALESCE(NULLIF(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')), ''), 'Unassigned') IN ('Free Agent', 'Alpha', 'Bravo', 'Charlie', 'A2Z', 'Unassigned')
    GROUP BY DATE_TRUNC('week', entry_date)::DATE, COALESCE(NULLIF(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')), ''), 'Unassigned')
),
-- Join to fill in missing weeks with 0
complete_weekly_hours AS (
    SELECT
        pw.week_start_date,
        pw.weeks_ago,
        pw.pod_name,
        COALESCE(wph.total_hours, 0) AS total_hours,
        COALESCE(wph.billable_hours, 0) AS billable_hours,
        COALESCE(wph.unique_resources, 0) AS unique_resources
    FROM pod_weeks pw
    LEFT JOIN weekly_pod_hours wph
        ON pw.week_start_date = wph.week_start_date
        AND pw.pod_name = wph.pod_name
),
pod_averages AS (
    SELECT
        pod_name,
        -- Last week hours (weeks_ago = 1)
        MAX(CASE WHEN weeks_ago = 1 THEN total_hours END) AS last_week_hours,

        -- 4-week average: weeks 2-5 (previous 4 weeks before last week)
        (SELECT AVG(total_hours)
         FROM complete_weekly_hours cwh2
         WHERE cwh2.pod_name = cwh.pod_name
           AND cwh2.weeks_ago BETWEEN 2 AND 5
        ) AS avg_4_week_hours,

        -- 12-week average: weeks 2-13 (previous 12 weeks before last week)
        (SELECT AVG(total_hours)
         FROM complete_weekly_hours cwh2
         WHERE cwh2.pod_name = cwh.pod_name
           AND cwh2.weeks_ago BETWEEN 2 AND 13
        ) AS avg_12_week_hours,

        -- Previous week hours (weeks_ago = 2)
        MAX(CASE WHEN weeks_ago = 2 THEN total_hours END) AS previous_week_hours,

        -- Billable hours for last week
        MAX(CASE WHEN weeks_ago = 1 THEN billable_hours END) AS last_week_billable_hours,

        -- Resource count for last week
        MAX(CASE WHEN weeks_ago = 1 THEN unique_resources END) AS last_week_resources
    FROM complete_weekly_hours cwh
    GROUP BY pod_name
)
SELECT
    pod_name,
    COALESCE(last_week_hours, 0) AS last_week_hours,
    COALESCE(avg_4_week_hours, 0) AS avg_4_week_hours,
    COALESCE(avg_12_week_hours, 0) AS avg_12_week_hours,
    COALESCE(previous_week_hours, 0) AS previous_week_hours,
    COALESCE(last_week_billable_hours, 0) AS last_week_billable_hours,
    COALESCE(last_week_resources, 0) AS last_week_resources,

    -- Variance calculations
    ROUND((COALESCE(last_week_hours, 0) - COALESCE(avg_4_week_hours, 0))::NUMERIC, 2) AS variance_vs_4_week,
    ROUND((COALESCE(last_week_hours, 0) - COALESCE(avg_12_week_hours, 0))::NUMERIC, 2) AS variance_vs_12_week,

    -- Percentage changes
    CASE
        WHEN COALESCE(avg_4_week_hours, 0) > 0
        THEN ROUND(((COALESCE(last_week_hours, 0) - COALESCE(avg_4_week_hours, 0)) / COALESCE(avg_4_week_hours, 0) * 100)::NUMERIC, 1)
        ELSE 0
    END AS pct_change_vs_4_week,

    CASE
        WHEN COALESCE(avg_12_week_hours, 0) > 0
        THEN ROUND(((COALESCE(last_week_hours, 0) - COALESCE(avg_12_week_hours, 0)) / COALESCE(avg_12_week_hours, 0) * 100)::NUMERIC, 1)
        ELSE 0
    END AS pct_change_vs_12_week,

    -- Trend indicators
    CASE
        WHEN COALESCE(last_week_hours, 0) > COALESCE(previous_week_hours, 0) THEN 'Upward'
        WHEN COALESCE(last_week_hours, 0) < COALESCE(previous_week_hours, 0) THEN 'Downward'
        ELSE 'Stable'
    END AS weekly_trend,

    -- Billable percentage
    CASE
        WHEN COALESCE(last_week_hours, 0) > 0
        THEN ROUND((COALESCE(last_week_billable_hours, 0) / COALESCE(last_week_hours, 0) * 100)::NUMERIC, 1)
        ELSE 0
    END AS last_week_billable_pct,

    -- Performance indicators
    CASE
        WHEN COALESCE(last_week_hours, 0) > COALESCE(avg_4_week_hours, 0) * 1.1 THEN 'Above Average'
        WHEN COALESCE(last_week_hours, 0) < COALESCE(avg_4_week_hours, 0) * 0.9 THEN 'Below Average'
        ELSE 'Average'
    END AS performance_vs_4_week,

    -- Last week date for reference
    (SELECT week_start_date FROM all_weeks WHERE weeks_ago = 1) AS last_week_date
FROM pod_averages
ORDER BY
    CASE pod_name
        WHEN 'Free Agent' THEN 1
        WHEN 'Alpha' THEN 2
        WHEN 'Bravo' THEN 3
        WHEN 'Charlie' THEN 4
        WHEN 'A2Z' THEN 5
        ELSE 6
    END;

-- ============================================================
-- vw_practice_group_performance
-- Same structure as vw_pod_performance_analysis but uses a practice_group
-- bucketing driven by the Clockify project_type custom field:
--   project_type = 'Professional Services'       → 'Professional Services'
--   project_type = 'Non Bill Productive'         → 'Non-Billable Productive'
--   project_type = 'Non Bill Non Productive'     → 'Non-Billable Non-Productive'
--   project_type IN (MC types)                   → clockify_projects.pod_assignment (custom field)
--                                                    fallback → 'Managed Cloud' if no pod set
--   project_type IN (Overhead/Training/etc.)      → Non-Billable Productive
--   project_type IS NULL AND billable             → Unassigned
--   project_type IS NULL AND not billable         → Non-Billable Non-Productive
-- Uses only Clockify project custom fields — no ps_project_mapping dependency.
-- Used by the "Project Hours" dashboard tab.
-- ============================================================
DROP VIEW IF EXISTS vw_practice_group_performance;
CREATE VIEW vw_practice_group_performance AS
WITH
-- Generate week numbers: week 1 = last complete week, week 2-13 = previous 12 weeks
all_weeks AS (
    SELECT
        (DATE_TRUNC('week', CURRENT_DATE)::DATE - (n * 7))::DATE AS week_start_date,
        n AS weeks_ago
    FROM generate_series(1, 13) AS n
),
-- All practice groups (ensures rows appear even with 0 hours; no Free Agent)
all_groups AS (
    SELECT unnest(ARRAY[
        'Professional Services', 'Managed Cloud', 'Alpha', 'Bravo', 'Charlie', 'A2Z',
        'FinOps', 'Non-Billable Productive', 'Non-Billable Non-Productive', 'Unassigned', 'No Project'
    ]) AS practice_group
),
group_weeks AS (
    SELECT w.week_start_date, w.weeks_ago, g.practice_group
    FROM all_weeks w CROSS JOIN all_groups g
),
-- Classify each time entry using only Clockify project custom fields (project_type, pod_assignment).
-- No ps_project_mapping dependency — classification is driven entirely by Clockify data.
classified AS (
    SELECT
        DATE_TRUNC('week', te.entry_date)::DATE  AS week_start_date,
        te.billable,
        te.duration_hours,
        te.clockify_user_id,
        cp.project_type,
        COALESCE(cp.is_overtime, FALSE)          AS is_overtime,
        COALESCE(cp.is_presales, FALSE)          AS is_presales,
        NULLIF(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
            COALESCE(cp.pod_assignment, ''), '{',''),'}',''),'"',''),'\','')), '') AS project_pod
    FROM clockify_detailed_time_entries te
    LEFT JOIN clockify_projects cp ON te.clockify_project_id = cp.clockify_project_id
    WHERE te.entry_date >= CURRENT_DATE - INTERVAL '120 days'
      AND te.duration_hours > 0
),
-- Aggregate by practice_group
weekly_group_hours AS (
    SELECT
        week_start_date,
        CASE
            -- No project assigned at all
            WHEN project_type IS NULL AND project_pod IS NULL AND billable IS NULL THEN 'No Project'
            -- Overtime/Presales project_type values → Non-Billable Productive
            WHEN project_type IN ('Overtime', 'Presales')                          THEN 'Non-Billable Productive'
            -- Overtime/Presales boolean toggles (legacy)
            WHEN is_overtime OR is_presales                                        THEN 'Non-Billable Productive'
            -- Clockify project_type drives classification
            WHEN project_type = 'Professional Services'                            THEN 'Professional Services'
            WHEN project_type = 'Non Bill Productive'                              THEN 'Non-Billable Productive'
            WHEN project_type = 'Non Bill Non Productive'                          THEN 'Non-Billable Non-Productive'
            WHEN project_type IN ('Managed Cloud',
                                  'Managed Cloud and Managed IT',
                                  'Managed IT')                                    THEN COALESCE(project_pod, 'Managed Cloud')
            WHEN project_type = 'FinOps'                                           THEN 'FinOps'
            WHEN project_type IN ('Overhead',
                                  'Training and Certs',
                                  'Internal Initiatives',
                                  'Product Development')                           THEN 'Non-Billable Productive'
            -- project_type not set in Clockify
            WHEN project_type IS NULL AND billable = TRUE                          THEN 'Unassigned'
            WHEN project_type IS NULL AND billable = FALSE                         THEN 'Non-Billable Non-Productive'
            ELSE 'Unassigned'
        END                                                        AS practice_group,
        SUM(duration_hours)                                        AS total_hours,
        SUM(CASE WHEN billable THEN duration_hours ELSE 0 END)     AS billable_hours,
        COUNT(DISTINCT clockify_user_id)                           AS unique_resources
    FROM classified
    GROUP BY
        week_start_date,
        CASE
            WHEN project_type IS NULL AND project_pod IS NULL AND billable IS NULL THEN 'No Project'
            WHEN project_type IN ('Overtime', 'Presales')                          THEN 'Non-Billable Productive'
            WHEN is_overtime OR is_presales                                        THEN 'Non-Billable Productive'
            WHEN project_type = 'Professional Services'                            THEN 'Professional Services'
            WHEN project_type = 'Non Bill Productive'                              THEN 'Non-Billable Productive'
            WHEN project_type = 'Non Bill Non Productive'                          THEN 'Non-Billable Non-Productive'
            WHEN project_type IN ('Managed Cloud',
                                  'Managed Cloud and Managed IT',
                                  'Managed IT')                                    THEN COALESCE(project_pod, 'Managed Cloud')
            WHEN project_type = 'FinOps'                                           THEN 'FinOps'
            WHEN project_type IN ('Overhead',
                                  'Training and Certs',
                                  'Internal Initiatives',
                                  'Product Development')                           THEN 'Non-Billable Productive'
            WHEN project_type IS NULL AND billable = TRUE                          THEN 'Unassigned'
            WHEN project_type IS NULL AND billable = FALSE                         THEN 'Non-Billable Non-Productive'
            ELSE 'Unassigned'
        END
),
complete_weekly_hours AS (
    SELECT
        gw.week_start_date,
        gw.weeks_ago,
        gw.practice_group,
        COALESCE(wgh.total_hours,      0) AS total_hours,
        COALESCE(wgh.billable_hours,   0) AS billable_hours,
        COALESCE(wgh.unique_resources, 0) AS unique_resources
    FROM group_weeks gw
    LEFT JOIN weekly_group_hours wgh
           ON gw.week_start_date = wgh.week_start_date
          AND gw.practice_group  = wgh.practice_group
),
group_averages AS (
    SELECT
        practice_group,
        MAX(CASE WHEN weeks_ago = 1 THEN total_hours    END) AS last_week_hours,
        (SELECT AVG(total_hours) FROM complete_weekly_hours c2
          WHERE c2.practice_group = cwh.practice_group AND c2.weeks_ago BETWEEN 2 AND 5
        ) AS avg_4_week_hours,
        (SELECT AVG(total_hours) FROM complete_weekly_hours c2
          WHERE c2.practice_group = cwh.practice_group AND c2.weeks_ago BETWEEN 2 AND 13
        ) AS avg_12_week_hours,
        MAX(CASE WHEN weeks_ago = 2 THEN total_hours    END) AS previous_week_hours,
        MAX(CASE WHEN weeks_ago = 1 THEN billable_hours END) AS last_week_billable_hours,
        MAX(CASE WHEN weeks_ago = 1 THEN unique_resources END) AS last_week_resources
    FROM complete_weekly_hours cwh
    GROUP BY practice_group
)
SELECT
    practice_group,
    COALESCE(last_week_hours,           0) AS last_week_hours,
    COALESCE(avg_4_week_hours,          0) AS avg_4_week_hours,
    COALESCE(avg_12_week_hours,         0) AS avg_12_week_hours,
    COALESCE(previous_week_hours,       0) AS previous_week_hours,
    COALESCE(last_week_billable_hours,  0) AS last_week_billable_hours,
    COALESCE(last_week_resources,       0) AS last_week_resources,
    ROUND((COALESCE(last_week_hours, 0) - COALESCE(avg_4_week_hours,  0))::NUMERIC, 2) AS variance_vs_4_week,
    ROUND((COALESCE(last_week_hours, 0) - COALESCE(avg_12_week_hours, 0))::NUMERIC, 2) AS variance_vs_12_week,
    CASE WHEN COALESCE(avg_4_week_hours,  0) > 0
         THEN ROUND(((COALESCE(last_week_hours,0) - COALESCE(avg_4_week_hours,0))
                    / COALESCE(avg_4_week_hours,0) * 100)::NUMERIC, 1)
         ELSE 0 END AS pct_change_vs_4_week,
    CASE WHEN COALESCE(avg_12_week_hours, 0) > 0
         THEN ROUND(((COALESCE(last_week_hours,0) - COALESCE(avg_12_week_hours,0))
                    / COALESCE(avg_12_week_hours,0) * 100)::NUMERIC, 1)
         ELSE 0 END AS pct_change_vs_12_week,
    CASE WHEN COALESCE(last_week_hours,0) > COALESCE(previous_week_hours,0) THEN 'Upward'
         WHEN COALESCE(last_week_hours,0) < COALESCE(previous_week_hours,0) THEN 'Downward'
         ELSE 'Stable' END AS weekly_trend,
    CASE WHEN COALESCE(last_week_hours,0) > 0
         THEN ROUND((COALESCE(last_week_billable_hours,0)
                    / COALESCE(last_week_hours,0) * 100)::NUMERIC, 1)
         ELSE 0 END AS last_week_billable_pct,
    CASE WHEN COALESCE(last_week_hours,0) > COALESCE(avg_4_week_hours,0) * 1.1 THEN 'Above Average'
         WHEN COALESCE(last_week_hours,0) < COALESCE(avg_4_week_hours,0) * 0.9 THEN 'Below Average'
         ELSE 'Average' END AS performance_vs_4_week,
    (SELECT week_start_date FROM all_weeks WHERE weeks_ago = 1) AS last_week_date
FROM group_averages
ORDER BY
    CASE practice_group
        WHEN 'Professional Services'       THEN 1
        WHEN 'Managed Cloud'               THEN 2
        WHEN 'Alpha'                       THEN 3
        WHEN 'Bravo'                       THEN 4
        WHEN 'Charlie'                     THEN 5
        WHEN 'A2Z'                         THEN 6
        WHEN 'FinOps'                      THEN 7
        WHEN 'Non-Billable Productive'     THEN 8
        WHEN 'Non-Billable Non-Productive' THEN 9
        WHEN 'No Project'                  THEN 10
        ELSE 11
    END;

-- ============================================================
-- View 13: Contractor Time Weekly Trend (Last 5 Weeks)
-- Shows contractor hours for the previous week and 4-week trend
-- ============================================================
DROP VIEW IF EXISTS vw_contractor_weekly_trend;
CREATE VIEW vw_contractor_weekly_trend AS
WITH
-- Generate last 5 complete weeks
weekly_dates AS (
    SELECT
        (DATE_TRUNC('week', CURRENT_DATE)::DATE - (n * 7))::DATE AS week_start_date,
        (DATE_TRUNC('week', CURRENT_DATE)::DATE - (n * 7) + 6)::DATE AS week_end_date,
        n AS weeks_ago,
        CASE n
            WHEN 1 THEN 'Last Week'
            WHEN 2 THEN '2 Weeks Ago'
            WHEN 3 THEN '3 Weeks Ago'
            WHEN 4 THEN '4 Weeks Ago'
            WHEN 5 THEN '5 Weeks Ago'
        END AS week_label
    FROM generate_series(1, 5) AS n
),
-- Contractor hours per week
contractor_weekly_hours AS (
    SELECT
        DATE_TRUNC('week', te.entry_date)::DATE AS week_start_date,
        SUM(te.duration_hours) AS total_hours,
        SUM(CASE WHEN te.billable THEN te.duration_hours ELSE 0 END) AS billable_hours,
        COUNT(DISTINCT te.clockify_user_id) AS contractor_count,
        COUNT(DISTINCT te.project_name) AS projects_worked
    FROM clockify_detailed_time_entries te
    JOIN clockify_users u ON te.clockify_user_id = u.clockify_user_id
    WHERE u.employment_designation ILIKE '%contractor%'
      AND te.entry_date >= CURRENT_DATE - INTERVAL '6 weeks'
    GROUP BY DATE_TRUNC('week', te.entry_date)::DATE
)
SELECT
    wd.week_start_date,
    wd.week_end_date,
    wd.weeks_ago,
    wd.week_label,
    COALESCE(cwh.total_hours, 0) AS total_hours,
    COALESCE(cwh.billable_hours, 0) AS billable_hours,
    COALESCE(cwh.contractor_count, 0) AS contractor_count,
    COALESCE(cwh.projects_worked, 0) AS projects_worked,
    CASE
        WHEN COALESCE(cwh.total_hours, 0) > 0
        THEN ROUND((COALESCE(cwh.billable_hours, 0) / COALESCE(cwh.total_hours, 0) * 100)::NUMERIC, 1)
        ELSE 0
    END AS billable_percent
FROM weekly_dates wd
LEFT JOIN contractor_weekly_hours cwh ON wd.week_start_date = cwh.week_start_date
ORDER BY wd.weeks_ago;

-- ============================================================
-- View 14: Contractor Time Summary with Averages
-- Shows last week vs 4-week average for contractors
-- ============================================================
DROP VIEW IF EXISTS vw_contractor_time_summary;
CREATE VIEW vw_contractor_time_summary AS
WITH
contractor_weekly AS (
    SELECT
        DATE_TRUNC('week', te.entry_date)::DATE AS week_start_date,
        te.clockify_user_id,
        te.user_name,
        u.pod_assignment,
        u.practice_alignment,
        u.location,
        SUM(te.duration_hours) AS total_hours,
        SUM(CASE WHEN te.billable THEN te.duration_hours ELSE 0 END) AS billable_hours
    FROM clockify_detailed_time_entries te
    JOIN clockify_users u ON te.clockify_user_id = u.clockify_user_id
    WHERE u.employment_designation ILIKE '%contractor%'
      AND te.entry_date >= CURRENT_DATE - INTERVAL '6 weeks'
    GROUP BY
        DATE_TRUNC('week', te.entry_date)::DATE,
        te.clockify_user_id,
        te.user_name,
        u.pod_assignment,
        u.practice_alignment,
        u.location
),
last_week_date AS (
    SELECT (DATE_TRUNC('week', CURRENT_DATE)::DATE - 7)::DATE AS week_start
),
contractor_summary AS (
    SELECT
        clockify_user_id,
        user_name,
        pod_assignment,
        practice_alignment,
        location,
        -- Last week hours
        MAX(CASE WHEN week_start_date = (SELECT week_start FROM last_week_date) THEN total_hours END) AS last_week_hours,
        MAX(CASE WHEN week_start_date = (SELECT week_start FROM last_week_date) THEN billable_hours END) AS last_week_billable,
        -- 4-week average (weeks 2-5)
        AVG(CASE WHEN week_start_date < (SELECT week_start FROM last_week_date) THEN total_hours END) AS avg_4_week_hours,
        -- Count of weeks with time in prior 4 weeks
        COUNT(CASE WHEN week_start_date < (SELECT week_start FROM last_week_date) THEN 1 END) AS weeks_with_time
    FROM contractor_weekly
    GROUP BY clockify_user_id, user_name, pod_assignment, practice_alignment, location
)
SELECT
    user_name,
    -- Clean pod assignment formatting
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')) AS pod_assignment,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')) AS practice_alignment,
    location,
    COALESCE(last_week_hours, 0) AS last_week_hours,
    COALESCE(last_week_billable, 0) AS last_week_billable_hours,
    ROUND(COALESCE(avg_4_week_hours, 0)::NUMERIC, 2) AS avg_4_week_hours,
    -- Variance from average
    ROUND((COALESCE(last_week_hours, 0) - COALESCE(avg_4_week_hours, 0))::NUMERIC, 2) AS variance_vs_avg,
    -- Trend indicator
    CASE
        WHEN COALESCE(last_week_hours, 0) > COALESCE(avg_4_week_hours, 0) * 1.1 THEN 'Above Average'
        WHEN COALESCE(last_week_hours, 0) < COALESCE(avg_4_week_hours, 0) * 0.9 THEN 'Below Average'
        ELSE 'Average'
    END AS performance_indicator,
    (SELECT week_start FROM last_week_date) AS week_evaluated
FROM contractor_summary
WHERE COALESCE(last_week_hours, 0) > 0 OR COALESCE(avg_4_week_hours, 0) > 0
ORDER BY COALESCE(last_week_hours, 0) DESC;

-- ============================================================
-- View 15: Forecast vs Actual Comparison
-- Compares forecasted hours against actual logged hours
-- ============================================================
DROP VIEW IF EXISTS vw_forecast_vs_actual;
CREATE VIEW vw_forecast_vs_actual AS
WITH forecast_data AS (
    SELECT
        f.week_start_date,
        f.clockify_user_id,
        f.user_name,
        f.client_name,
        f.project_name,
        f.practice_area,
        f.location,
        f.forecasted_hours,
        f.actual_hours AS forecast_actual_hours
    FROM ps_resource_forecasts f
),
actual_data AS (
    SELECT
        te.week_start,
        te.user_name,
        te.client_name,
        te.project_name,
        SUM(te.duration_hours) AS actual_hours
    FROM clockify_detailed_time_entries te
    WHERE te.week_start IS NOT NULL
    GROUP BY te.week_start, te.user_name, te.client_name, te.project_name
)
SELECT
    COALESCE(f.week_start_date, a.week_start) AS week_start_date,
    COALESCE(f.user_name, a.user_name) AS user_name,
    f.clockify_user_id,
    COALESCE(f.project_name, a.project_name) AS project_name,
    COALESCE(f.client_name, a.client_name) AS client_name,
    f.practice_area,
    f.location,
    COALESCE(f.forecasted_hours, 0) AS forecasted_hours,
    COALESCE(a.actual_hours, 0) AS actual_hours,
    COALESCE(a.actual_hours, 0) - COALESCE(f.forecasted_hours, 0) AS variance_hours,
    CASE
        WHEN COALESCE(f.forecasted_hours, 0) > 0
        THEN ROUND(((COALESCE(a.actual_hours, 0) / f.forecasted_hours) * 100)::NUMERIC, 1)
        ELSE NULL
    END AS pct_of_forecast,
    CASE
        WHEN COALESCE(f.forecasted_hours, 0) = 0 AND COALESCE(a.actual_hours, 0) > 0 THEN 'Unforecasted'
        WHEN COALESCE(a.actual_hours, 0) = 0 AND COALESCE(f.forecasted_hours, 0) > 0 THEN 'No Actuals'
        WHEN COALESCE(a.actual_hours, 0) > COALESCE(f.forecasted_hours, 0) * 1.1 THEN 'Over'
        WHEN COALESCE(a.actual_hours, 0) < COALESCE(f.forecasted_hours, 0) * 0.9 THEN 'Under'
        ELSE 'On Track'
    END AS status
FROM forecast_data f
FULL OUTER JOIN actual_data a
    ON f.week_start_date = a.week_start
    AND LOWER(f.user_name) = LOWER(a.user_name)
    AND LOWER(COALESCE(f.client_name, '')) = LOWER(COALESCE(a.client_name, ''))
    AND LOWER(COALESCE(f.project_name, '')) = LOWER(COALESCE(a.project_name, ''))
WHERE EXISTS (
    SELECT 1 FROM clockify_users cu
    WHERE LOWER(cu.name) = LOWER(COALESCE(f.user_name, a.user_name))
)
ORDER BY week_start_date DESC, user_name, client_name, project_name;

-- ============================================================
-- View 16: PS Resource Forecast Pivot Data
-- Provides forecast data for pivot table visualization
-- Rows: Client, Project, PM, User
-- Columns: Week Start Date (to be pivoted in QuickSight)
-- Values: Forecasted Hours
-- ============================================================
DROP VIEW IF EXISTS vw_forecast_pivot;
CREATE VIEW vw_forecast_pivot AS
SELECT
    f.client_name,
    f.project_name,
    f.pm_name,
    f.user_name,
    f.project_type,
    f.stage,
    u.location,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')) AS practice_alignment,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')) AS pod_assignment,
    f.week_start_date,
    f.week_end_date,
    -- Week label for column headers (e.g., "Jan 27")
    TO_CHAR(f.week_start_date, 'Mon DD') AS week_label,
    -- ISO week for sorting
    EXTRACT(WEEK FROM f.week_start_date) AS week_number,
    EXTRACT(YEAR FROM f.week_start_date) AS year,
    f.forecasted_hours,
    f.actual_hours,
    -- Variance between forecast and actual
    f.forecasted_hours - COALESCE(f.actual_hours, 0) AS variance_hours,
    f.comments,
    f.created_at,
    f.updated_at
FROM ps_resource_forecasts f
LEFT JOIN clockify_users u ON f.clockify_user_id = u.clockify_user_id
WHERE f.week_start_date >= CURRENT_DATE - INTERVAL '4 weeks'  -- Include recent past
  AND f.week_start_date <= CURRENT_DATE + INTERVAL '16 weeks'  -- And future weeks
ORDER BY
    f.client_name,
    f.project_name,
    f.user_name,
    f.week_start_date;

-- ============================================================
-- View 16: PS Resource Forecast Summary by Client/Week
-- Aggregated view for high-level forecast overview
-- ============================================================
DROP VIEW IF EXISTS vw_forecast_summary_by_client;
CREATE VIEW vw_forecast_summary_by_client AS
SELECT
    f.client_name,
    f.project_name,
    f.pm_name,
    f.week_start_date,
    TO_CHAR(f.week_start_date, 'Mon DD') AS week_label,
    COUNT(DISTINCT f.user_name) AS resource_count,
    SUM(f.forecasted_hours) AS total_forecasted_hours,
    SUM(COALESCE(f.actual_hours, 0)) AS total_actual_hours,
    SUM(f.forecasted_hours) - SUM(COALESCE(f.actual_hours, 0)) AS variance_hours
FROM ps_resource_forecasts f
WHERE f.week_start_date >= CURRENT_DATE - INTERVAL '4 weeks'
  AND f.week_start_date <= CURRENT_DATE + INTERVAL '16 weeks'
GROUP BY
    f.client_name,
    f.project_name,
    f.pm_name,
    f.week_start_date
ORDER BY
    f.client_name,
    f.week_start_date;

-- ============================================================
-- View 16b: PS Resource Forecast Summary (by week)
-- Aggregated overview matching QuickSight dataset schema
-- ============================================================
DROP VIEW IF EXISTS vw_forecast_summary;
CREATE VIEW vw_forecast_summary AS
SELECT
    f.week_start_date,
    f.week_end_date,
    COUNT(DISTINCT f.user_name) AS resources_forecasted,
    COUNT(DISTINCT f.project_name) AS projects_forecasted,
    SUM(f.forecasted_hours) AS total_forecasted_hours,
    COUNT(*) AS forecast_count
FROM ps_resource_forecasts f
WHERE f.week_start_date >= CURRENT_DATE - INTERVAL '4 weeks'
  AND f.week_start_date <= CURRENT_DATE + INTERVAL '16 weeks'
GROUP BY f.week_start_date, f.week_end_date
ORDER BY f.week_start_date;

-- ============================================================
-- View 17: Users Over 40 Hours Forecasted Per Week
-- Shows users with total forecasted hours > 40 for any week
-- ============================================================
DROP VIEW IF EXISTS vw_forecast_over_40_hours;
CREATE VIEW vw_forecast_over_40_hours AS
WITH users_over_40 AS (
    -- Find users who have more than 40 hours total in a week
    SELECT
        user_name,
        week_start_date,
        SUM(forecasted_hours) AS total_weekly_hours
    FROM ps_resource_forecasts
    WHERE week_start_date >= CURRENT_DATE - INTERVAL '1 week'
      AND week_start_date <= CURRENT_DATE + INTERVAL '16 weeks'
    GROUP BY user_name, week_start_date
    HAVING SUM(forecasted_hours) > 40
)
-- Show individual client allocations for those users
SELECT
    f.user_name,
    u.location,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')) AS practice_alignment,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')) AS pod_assignment,
    f.week_start_date,
    TO_CHAR(f.week_start_date, 'Mon DD') AS week_label,
    f.client_name,
    f.project_name,
    f.pm_name AS project_manager,
    f.forecasted_hours AS client_hours,
    uo.total_weekly_hours,
    -- Show how many clients this person is split across that week
    (SELECT COUNT(DISTINCT client_name)
     FROM ps_resource_forecasts f2
     WHERE f2.user_name = f.user_name
       AND f2.week_start_date = f.week_start_date) AS client_count
FROM ps_resource_forecasts f
INNER JOIN users_over_40 uo
    ON f.user_name = uo.user_name
    AND f.week_start_date = uo.week_start_date
LEFT JOIN clockify_users u ON f.clockify_user_id = u.clockify_user_id
ORDER BY
    f.week_start_date,
    uo.total_weekly_hours DESC,
    f.user_name,
    f.client_name;

-- ============================================================
-- View 18: PS Project Status
-- Professional Services Project Status dashboard view
-- ============================================================
DROP VIEW IF EXISTS vw_ps_project_status CASCADE;
CREATE VIEW vw_ps_project_status AS
WITH last_sync AS (
    SELECT MAX(synced_at) AS last_synced_at FROM ps_project_status
),
-- Actual hours from Clockify, using mapping table when available
ps_actual_hours AS (
    SELECT
        p.jira_issue_id,
        COALESCE(
            -- First: task-name match for projects where Clockify uses tasks per client (e.g. 5x5x5)
            (SELECT SUM(te.duration_hours)
             FROM ps_project_mapping m
             JOIN clockify_detailed_time_entries te
                 ON LOWER(te.project_name) = LOWER(m.clockify_project_name)
                 AND LOWER(te.task_name) = LOWER(p.client_name)
             WHERE m.is_active = TRUE
               AND LOWER(m.ps_client_name) = LOWER(p.client_name)
               AND m.clockify_project_name IS NOT NULL
               AND te.task_name IS NOT NULL
               AND te.entry_date >= DATE_TRUNC('year', CURRENT_DATE)),
            -- Second: use explicit mapping from ps_project_mapping (client+project level)
            (SELECT SUM(te.duration_hours)
             FROM ps_project_mapping m
             JOIN clockify_detailed_time_entries te
                 ON LOWER(te.client_name) = LOWER(m.clockify_client_name)
                 AND (m.clockify_project_name IS NULL
                      OR LOWER(te.project_name) = LOWER(m.clockify_project_name))
             WHERE m.is_active = TRUE
               AND LOWER(m.ps_client_name) = LOWER(p.client_name)
               AND (m.ps_project_name IS NULL
                    OR LOWER(m.ps_project_name) = LOWER(p.project_name))
               AND te.entry_date >= DATE_TRUNC('year', CURRENT_DATE)),
            -- Third: direct client+project name match
            (SELECT SUM(te.duration_hours)
             FROM clockify_detailed_time_entries te
             WHERE LOWER(te.client_name) = LOWER(p.client_name)
               AND LOWER(te.project_name) = LOWER(p.project_name)
               AND te.entry_date >= DATE_TRUNC('year', CURRENT_DATE)),
            -- Fourth: all hours for matching client
            (SELECT SUM(te.duration_hours)
             FROM clockify_detailed_time_entries te
             WHERE LOWER(te.client_name) = LOWER(p.client_name)
               AND te.entry_date >= DATE_TRUNC('year', CURRENT_DATE))
        ) AS actual_hours
    FROM ps_project_status p
),
-- Last week's hours from Clockify, using mapping table when available
ps_last_week_hours AS (
    SELECT
        p.jira_issue_id,
        COALESCE(
            -- First: use explicit mapping from ps_project_mapping
            (SELECT SUM(te.duration_hours)
             FROM ps_project_mapping m
             JOIN clockify_detailed_time_entries te
                 ON LOWER(te.client_name) = LOWER(m.clockify_client_name)
                 AND (m.clockify_project_name IS NULL
                      OR LOWER(te.project_name) = LOWER(m.clockify_project_name))
             WHERE m.is_active = TRUE
               AND LOWER(m.ps_client_name) = LOWER(p.client_name)
               AND (m.ps_project_name IS NULL
                    OR LOWER(m.ps_project_name) = LOWER(p.project_name))
               AND te.entry_date >= (DATE_TRUNC('week', CURRENT_DATE) - INTERVAL '7 days')::DATE
               AND te.entry_date < DATE_TRUNC('week', CURRENT_DATE)::DATE),
            -- Second: direct client+project name match
            (SELECT SUM(te.duration_hours)
             FROM clockify_detailed_time_entries te
             WHERE LOWER(te.client_name) = LOWER(p.client_name)
               AND LOWER(te.project_name) = LOWER(p.project_name)
               AND te.entry_date >= (DATE_TRUNC('week', CURRENT_DATE) - INTERVAL '7 days')::DATE
               AND te.entry_date < DATE_TRUNC('week', CURRENT_DATE)::DATE),
            -- Third: all hours for matching client
            (SELECT SUM(te.duration_hours)
             FROM clockify_detailed_time_entries te
             WHERE LOWER(te.client_name) = LOWER(p.client_name)
               AND te.entry_date >= (DATE_TRUNC('week', CURRENT_DATE) - INTERVAL '7 days')::DATE
               AND te.entry_date < DATE_TRUNC('week', CURRENT_DATE)::DATE)
        ) AS last_week_hours
    FROM ps_project_status p
),
-- Clockify client/project names from the explicit mapping table
ps_clockify_names AS (
    SELECT DISTINCT ON (LOWER(m.ps_client_name), LOWER(COALESCE(m.ps_project_name, '')))
        LOWER(m.ps_client_name)                    AS ps_client_key,
        LOWER(COALESCE(m.ps_project_name, ''))     AS ps_project_key,
        m.clockify_client_name,
        m.clockify_project_name
    FROM ps_project_mapping m
    WHERE m.is_active = TRUE
      AND m.category = 'PS'
    ORDER BY LOWER(m.ps_client_name),
             LOWER(COALESCE(m.ps_project_name, '')),
             m.id DESC
),
-- Actual Clockify client name from time entries (preserves Clockify casing for unmapped projects)
ps_clockify_direct AS (
    SELECT DISTINCT ON (LOWER(te.client_name))
        LOWER(te.client_name)  AS client_key,
        te.client_name         AS clockify_client_name
    FROM clockify_detailed_time_entries te
    ORDER BY LOWER(te.client_name), te.entry_date DESC
),
-- Clockify project display name for mappings where clockify_project_name is NULL.
-- Picks the Clockify project with the most hours for the mapped client this year.
-- Used so the tracker shows the real Clockify project name instead of the Jira-parsed one.
ps_clockify_project_display AS (
    SELECT DISTINCT ON (ps_client_key, ps_project_key)
        ps_client_key,
        ps_project_key,
        clockify_project_name
    FROM (
        SELECT
            LOWER(m.ps_client_name)                AS ps_client_key,
            LOWER(COALESCE(m.ps_project_name, '')) AS ps_project_key,
            te.project_name                        AS clockify_project_name,
            SUM(te.duration_hours)                 AS total_hours
        FROM ps_project_mapping m
        JOIN clockify_detailed_time_entries te
            ON LOWER(te.client_name) = LOWER(m.clockify_client_name)
        WHERE m.is_active = TRUE
          AND m.category = 'PS'
          AND m.clockify_project_name IS NULL
          AND te.entry_date >= DATE_TRUNC('year', CURRENT_DATE)::DATE
        GROUP BY LOWER(m.ps_client_name), LOWER(COALESCE(m.ps_project_name, '')), te.project_name
    ) t
    ORDER BY ps_client_key, ps_project_key, total_hours DESC
),
-- Remaining forecast hours (future weeks only), using mapping table when available
ps_remaining_forecast AS (
    SELECT
        p.jira_issue_id,
        COALESCE(
            -- First: use explicit mapping from ps_project_mapping
            (SELECT SUM(f.forecasted_hours)
             FROM ps_project_mapping m
             JOIN ps_resource_forecasts f
                 ON LOWER(f.client_name) = LOWER(m.clockify_client_name)
                 AND (m.clockify_project_name IS NULL
                      OR LOWER(f.project_name) = LOWER(m.clockify_project_name))
             WHERE m.is_active = TRUE
               AND LOWER(m.ps_client_name) = LOWER(p.client_name)
               AND (m.ps_project_name IS NULL
                    OR LOWER(m.ps_project_name) = LOWER(p.project_name))
               AND f.week_start_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE),
            -- Second: direct client name match
            (SELECT SUM(f.forecasted_hours)
             FROM ps_resource_forecasts f
             WHERE LOWER(f.client_name) = LOWER(p.client_name)
               AND f.week_start_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE)
        ) AS remaining_forecast_hours
    FROM ps_project_status p
)
SELECT
    -- Client and project info (parsed from summary)
    p.client_name,
    p.project_name,
    -- Clockify names: explicit mapping → actual Clockify name from time entries → Jira name
    COALESCE(cn.clockify_client_name,  cd.clockify_client_name,  p.client_name)  AS clockify_client_name,
    COALESCE(cn.clockify_project_name, cpd.clockify_project_name, p.project_name) AS clockify_project_name,
    p.summary AS description,
    p.issue_key,
    p.jira_project_key,

    -- Project classification
    p.project_type AS type,
    p.status AS stage,  -- DISCOVER AND ALIGN, BUILD AND IMPLEMENT, etc.
    p.status_category,
    p.issue_type,
    p.category,         -- PS / MC
    p.priority,

    -- Team members
    p.project_manager,
    p.solution_architect AS technical_lead,
    p.engineer AS assistant_lead,
    p.account_executive,
    p.csm,
    p.assignee_name,

    -- Health status fields (Red/Yellow/Green / Not Assigned)
    COALESCE(p.health_overall, 'Not Assigned') AS health,
    COALESCE(p.health_budget,  'Not Assigned') AS health_budget,
    COALESCE(p.health_scope,   'Not Assigned') AS health_scope,
    COALESCE(p.health_schedule,'Not Assigned') AS health_schedule,
    p.schedule_score,  -- On Time/Late
    p.current_health,
    -- Normalize escalation to 'Red'/'Green' for QuickSight conditional formatting
    CASE
        WHEN COALESCE(TRIM(p.escalation), '') IN ('', 'None', 'No', 'N/A') THEN 'Green'
        ELSE 'Red'
    END AS escalation,
    p.impact,
    p.risks_blockers,

    -- Budget vs Actual
    p.budget_hours,
    ah.actual_hours,
    lw.last_week_hours,
    CASE
        WHEN p.budget_hours > 0 AND ah.actual_hours IS NOT NULL
        THEN ROUND((ah.actual_hours / p.budget_hours * 100)::NUMERIC, 1)
        ELSE NULL
    END AS budget_percent_used,

    -- Forecast-based projections
    rf.remaining_forecast_hours,
    CASE
        WHEN ah.actual_hours IS NOT NULL OR rf.remaining_forecast_hours IS NOT NULL
        THEN ROUND((COALESCE(ah.actual_hours, 0) + COALESCE(rf.remaining_forecast_hours, 0))::NUMERIC, 1)
        ELSE NULL
    END AS projected_ending_budget,
    CASE
        WHEN p.budget_hours > 0 AND (ah.actual_hours IS NOT NULL OR rf.remaining_forecast_hours IS NOT NULL)
        THEN ROUND(((COALESCE(ah.actual_hours, 0) + COALESCE(rf.remaining_forecast_hours, 0)) / p.budget_hours * 100)::NUMERIC, 1)
        ELSE NULL
    END AS projected_ending_percent,

    -- Date fields - Planning
    p.planned_start AS start_date,
    p.planned_end AS end_date,
    p.planned_kickoff,
    p.sow_signing_date,
    p.expected_completion,
    p.revised_completion,
    p.resource_assignment_date,
    p.due_date,

    -- Date fields - Actual completion by phase
    p.actual_kickoff,
    p.actual_completion,
    p.internal_prep_completion,
    p.discover_align_completion,
    p.design_review_completion,
    p.build_implement_completion,
    p.launch_enable_completion,

    -- Calculated date metrics
    CASE
        WHEN p.expected_completion IS NOT NULL
        THEN p.expected_completion - CURRENT_DATE
        ELSE NULL
    END AS days_to_completion,
    CASE
        WHEN p.planned_kickoff IS NOT NULL AND p.expected_completion IS NOT NULL
        THEN p.expected_completion - p.planned_kickoff
        ELSE NULL
    END AS total_duration_days,

    -- Narrative fields
    p.project_summary AS summary_text,
    p.what_we_did,
    p.what_we_will_do_next,
    p.mitigation_plan,
    p.slippages AS planned_vs_actual,

    -- Links
    p.sow_link,
    p.jira_board_link,

    -- Dates and metadata
    p.created_date,
    p.updated_date,
    p.week_start,
    TO_CHAR(p.week_start, 'Mon DD') AS week_label,

    -- Sync metadata
    (SELECT last_synced_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Chicago' FROM last_sync)::DATE AS last_updated_date,
    TO_CHAR((SELECT last_synced_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Chicago' FROM last_sync), 'HH:MI AM') AS last_updated_time
FROM ps_project_status p
LEFT JOIN ps_actual_hours ah ON p.jira_issue_id = ah.jira_issue_id
LEFT JOIN ps_last_week_hours lw ON p.jira_issue_id = lw.jira_issue_id
LEFT JOIN ps_remaining_forecast rf ON p.jira_issue_id = rf.jira_issue_id
LEFT JOIN ps_clockify_names cn
    ON LOWER(p.client_name) = cn.ps_client_key
   AND (cn.ps_project_key = '' OR cn.ps_project_key = LOWER(COALESCE(p.project_name, '')))
LEFT JOIN ps_clockify_direct cd ON LOWER(p.client_name) = cd.client_key
LEFT JOIN ps_clockify_project_display cpd
    ON LOWER(p.client_name) = cpd.ps_client_key
   AND (cpd.ps_project_key = '' OR cpd.ps_project_key = LOWER(COALESCE(p.project_name, '')))
WHERE NOT (
    p.status_category = 'Done'
    AND p.actual_completion < DATE_TRUNC('year', CURRENT_DATE)
)
AND NOT COALESCE(p.is_excluded, FALSE)
ORDER BY
    p.updated_date DESC;

-- ============================================================================
-- vw_free_agent_availability: Available capacity for Free Agent resources
-- Shows weekly capacity minus forecasted hours for the next 12 weeks
-- ============================================================================
DROP VIEW IF EXISTS vw_free_agent_availability;
CREATE VIEW vw_free_agent_availability AS
WITH
-- Generate next 12 weeks starting from current week
upcoming_weeks AS (
    SELECT
        (DATE_TRUNC('week', CURRENT_DATE)::DATE + (n * 7))::DATE AS week_start_date,
        TO_CHAR((DATE_TRUNC('week', CURRENT_DATE)::DATE + (n * 7))::DATE, 'Mon DD') AS week_label
    FROM generate_series(0, 11) AS n
),
-- Active Free Agent resources
free_agents AS (
    SELECT
        u.clockify_user_id,
        u.name AS user_name,
        u.location,
        TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.skill_area, '{', ''), '}', ''), '"', ''), '\', '')) AS skill_area,
        u.daily_capacity,
        u.daily_capacity * 5 AS weekly_capacity
    FROM clockify_users u
    WHERE u.status = 'active'
      AND TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')) = 'Free Agent'
),
-- Cross join to get every agent x week combination
agent_weeks AS (
    SELECT
        fa.clockify_user_id,
        fa.user_name,
        fa.location,
        fa.skill_area,
        fa.weekly_capacity,
        w.week_start_date,
        w.week_label
    FROM free_agents fa
    CROSS JOIN upcoming_weeks w
),
-- Forecasted hours per user per week
forecasted AS (
    SELECT
        LOWER(f.user_name) AS user_name_lower,
        f.week_start_date,
        SUM(f.forecasted_hours) AS forecasted_hours
    FROM ps_resource_forecasts f
    WHERE f.week_start_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE
      AND f.week_start_date < DATE_TRUNC('week', CURRENT_DATE)::DATE + INTERVAL '12 weeks'
    GROUP BY LOWER(f.user_name), f.week_start_date
)
SELECT
    aw.user_name,
    aw.location,
    aw.skill_area,
    aw.weekly_capacity,
    aw.week_start_date,
    aw.week_label,
    COALESCE(fc.forecasted_hours, 0) AS forecasted_hours,
    ROUND((aw.weekly_capacity - COALESCE(fc.forecasted_hours, 0))::NUMERIC, 1) AS available_hours
FROM agent_weeks aw
LEFT JOIN forecasted fc
    ON LOWER(aw.user_name) = fc.user_name_lower
    AND aw.week_start_date = fc.week_start_date
ORDER BY aw.user_name, aw.week_start_date;

-- ============================================================================
-- vw_non_billable_project_analysis: Non-billable project time by resource/week
-- Shows who is logging time to non-billable projects each week
-- ============================================================================
DROP VIEW IF EXISTS vw_non_billable_project_analysis;
CREATE VIEW vw_non_billable_project_analysis AS
WITH last_sync AS (
    SELECT MAX(completed_at) AS last_synced_at
    FROM import_logs
    WHERE status IN ('success', 'partial')
      AND import_category = 'clockify'
)
SELECT
    DATE_TRUNC('week', te.entry_date)::DATE AS week_start_date,
    te.client_name,
    te.project_name,
    te.user_name,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(te.practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')) AS practice_alignment,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(te.pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')) AS pod_assignment,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(te.skill_area, '{', ''), '}', ''), '"', ''), '\', '')) AS skill_area,
    te.location,
    te.employment_designation,
    SUM(te.duration_hours) AS total_hours,
    COUNT(*) AS entry_count,
    (SELECT last_synced_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Chicago' FROM last_sync)::DATE AS last_updated_date,
    TO_CHAR((SELECT last_synced_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Chicago' FROM last_sync), 'HH:MI AM') AS last_updated_time
FROM clockify_detailed_time_entries te
WHERE te.billable = FALSE
GROUP BY
    DATE_TRUNC('week', te.entry_date)::DATE,
    te.client_name,
    te.project_name,
    te.user_name,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(te.practice_alignment, '{', ''), '}', ''), '"', ''), '\', '')),
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(te.pod_assignment, '{', ''), '}', ''), '"', ''), '\', '')),
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(te.skill_area, '{', ''), '}', ''), '"', ''), '\', '')),
    te.location,
    te.employment_designation
ORDER BY
    week_start_date DESC, client_name, project_name, user_name;

-- ============================================================================
-- Ensure forecast history table exists (needed by vw_forecast_version_comparison)
-- ============================================================================
CREATE TABLE IF NOT EXISTS ps_resource_forecast_history (
    history_id SERIAL PRIMARY KEY,
    forecast_id INTEGER,
    week_start_date DATE NOT NULL,
    week_end_date DATE NOT NULL,
    clockify_user_id VARCHAR(50),
    user_name VARCHAR(255) NOT NULL,
    location VARCHAR(50),
    project_name VARCHAR(255),
    clockify_project_id VARCHAR(50),
    client_name VARCHAR(255) NOT NULL,
    project_type VARCHAR(100),
    pm_name VARCHAR(255),
    stage VARCHAR(100),
    practice_area VARCHAR(100),
    forecasted_hours FLOAT NOT NULL DEFAULT 0,
    actual_hours FLOAT DEFAULT 0,
    comments TEXT,
    created_by VARCHAR(255),
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    snapshot_id VARCHAR(50) NOT NULL,
    archived_at TIMESTAMP NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_forecast_history_snapshot
    ON ps_resource_forecast_history(snapshot_id);
CREATE INDEX IF NOT EXISTS idx_forecast_history_week
    ON ps_resource_forecast_history(week_start_date);
CREATE INDEX IF NOT EXISTS idx_forecast_history_archived_at
    ON ps_resource_forecast_history(archived_at);

-- ============================================================================
-- vw_forecast_version_comparison: Current vs previous forecast
-- Shows what changed between the current forecast and the most recent snapshot
-- ============================================================================
DROP VIEW IF EXISTS vw_forecast_version_comparison;
CREATE VIEW vw_forecast_version_comparison AS
WITH latest_snapshot AS (
    SELECT DISTINCT ON (week_start_date, user_name, client_name, project_name)
        week_start_date,
        user_name,
        client_name,
        project_name,
        forecasted_hours AS previous_forecasted_hours,
        snapshot_id,
        archived_at
    FROM ps_resource_forecast_history
    ORDER BY week_start_date, user_name, client_name, project_name, archived_at DESC
)
SELECT
    COALESCE(c.week_start_date, p.week_start_date) AS week_start_date,
    COALESCE(c.user_name, p.user_name) AS user_name,
    COALESCE(c.client_name, p.client_name) AS client_name,
    COALESCE(c.project_name, p.project_name) AS project_name,
    c.pm_name,
    c.project_type,
    c.stage,
    COALESCE(c.forecasted_hours, 0) AS current_hours,
    COALESCE(p.previous_forecasted_hours, 0) AS previous_hours,
    COALESCE(c.forecasted_hours, 0) - COALESCE(p.previous_forecasted_hours, 0) AS change_hours,
    CASE
        WHEN COALESCE(p.previous_forecasted_hours, 0) = 0
             AND COALESCE(c.forecasted_hours, 0) > 0 THEN 'New'
        WHEN COALESCE(c.forecasted_hours, 0) = 0
             AND COALESCE(p.previous_forecasted_hours, 0) > 0 THEN 'Removed'
        WHEN COALESCE(c.forecasted_hours, 0) > COALESCE(p.previous_forecasted_hours, 0) THEN 'Increased'
        WHEN COALESCE(c.forecasted_hours, 0) < COALESCE(p.previous_forecasted_hours, 0) THEN 'Decreased'
        ELSE 'Unchanged'
    END AS change_type,
    p.archived_at AS previous_snapshot_date,
    p.snapshot_id AS previous_snapshot_id
FROM ps_resource_forecasts c
FULL OUTER JOIN latest_snapshot p
    ON c.week_start_date = p.week_start_date
    AND LOWER(c.user_name) = LOWER(p.user_name)
    AND LOWER(COALESCE(c.client_name, '')) = LOWER(COALESCE(p.client_name, ''))
    AND LOWER(COALESCE(c.project_name, '')) = LOWER(COALESCE(p.project_name, ''))
ORDER BY week_start_date, user_name, client_name;

-- ============================================================================
-- vw_ps_profitability_2026: Project-level profitability rollup for current-year PS projects
-- Grain: one row per (project, location, worker_type) combination.
-- location and worker_type are dimension fields for QuickSight filtering/grouping.
-- Project-level budget/forecast totals are repeated on every row for reference.
-- ============================================================================
DROP VIEW IF EXISTS vw_ps_profitability_chart;
DROP VIEW IF EXISTS vw_ps_profitability_2026 CASCADE;
CREATE VIEW vw_ps_profitability_2026 AS
WITH

-- Latest PS projects snapshot
ps_projects AS (
    SELECT
        jira_issue_id, client_name, project_name, project_type, status,
        project_manager, status_category, health_overall, health_budget,
        COALESCE(budget_hours, 0) AS budget_hours,
        sow_link, jira_board_link, expected_completion, revised_completion
    FROM ps_project_status
    WHERE category = 'PS'
      AND NOT (status_category = 'Done' AND actual_completion < DATE_TRUNC('year', CURRENT_DATE))
),

-- Raw time entries resolved to PS projects via two-tier mapping hierarchy
project_te_raw AS (
    -- Tier 1: explicit ps_project_mapping
    SELECT
        p.jira_issue_id,
        te.location,
        CASE
            WHEN te.employment_designation ILIKE '%contractor%' THEN 'Contractor'
            WHEN te.employment_designation ILIKE '%fte%'        THEN 'FTE'
            ELSE COALESCE(te.employment_designation, 'Unknown')
        END AS worker_type,
        te.duration_hours
    FROM ps_projects p
    JOIN ps_project_mapping m
        ON m.is_active = TRUE
       AND LOWER(m.ps_client_name) = LOWER(p.client_name)
       AND (m.ps_project_name IS NULL OR LOWER(m.ps_project_name) = LOWER(p.project_name))
    JOIN clockify_detailed_time_entries te
        ON (LOWER(te.client_name) = LOWER(m.clockify_client_name)
            -- Fallback: when Clockify entry has no client, match on project name alone
            OR (te.client_name IS NULL AND m.clockify_project_name IS NOT NULL
                AND LOWER(te.project_name) = LOWER(m.clockify_project_name)))
       AND (m.clockify_project_name IS NULL OR LOWER(te.project_name) = LOWER(m.clockify_project_name))
       AND te.entry_date >= DATE_TRUNC('year', CURRENT_DATE)::DATE

    UNION ALL

    -- Tier 2: direct name match (only when no explicit mapping covers this PS project)
    SELECT
        p.jira_issue_id,
        te.location,
        CASE
            WHEN te.employment_designation ILIKE '%contractor%' THEN 'Contractor'
            WHEN te.employment_designation ILIKE '%fte%'        THEN 'FTE'
            ELSE COALESCE(te.employment_designation, 'Unknown')
        END AS worker_type,
        te.duration_hours
    FROM ps_projects p
    JOIN clockify_detailed_time_entries te
        ON LOWER(te.client_name) = LOWER(p.client_name)
       AND LOWER(te.project_name) = LOWER(p.project_name)
       AND te.entry_date >= DATE_TRUNC('year', CURRENT_DATE)::DATE
    WHERE NOT EXISTS (
        SELECT 1 FROM ps_project_mapping m
        WHERE m.is_active = TRUE
          AND LOWER(m.ps_client_name) = LOWER(p.client_name)
          AND (m.ps_project_name IS NULL OR LOWER(m.ps_project_name) = LOWER(p.project_name))
    )
),

-- Actuals grouped by project + location + worker_type
actuals_by_dim AS (
    SELECT jira_issue_id, location, worker_type, SUM(duration_hours) AS actual_hours
    FROM project_te_raw
    GROUP BY jira_issue_id, location, worker_type
),

-- Project-level actual totals (for budget % and summary metrics)
actuals_total AS (
    SELECT
        jira_issue_id,
        SUM(actual_hours)                                                         AS total_actual_hours,
        SUM(CASE WHEN location = 'Onshore'       THEN actual_hours ELSE 0 END)   AS onshore_actual_hours,
        SUM(CASE WHEN location = 'Offshore'      THEN actual_hours ELSE 0 END)   AS offshore_actual_hours,
        SUM(CASE WHEN worker_type = 'Contractor'  THEN actual_hours ELSE 0 END)  AS contractor_actual_hours,
        SUM(CASE WHEN worker_type = 'FTE'         THEN actual_hours ELSE 0 END)  AS fte_actual_hours
    FROM actuals_by_dim
    GROUP BY jira_issue_id
),

-- Raw forecast rows resolved to PS projects via two-tier mapping (future weeks only)
project_forecast_raw AS (
    -- Tier 1: explicit mapping
    SELECT
        p.jira_issue_id,
        f.location,
        CASE
            WHEN f.employment_designation ILIKE '%contractor%' THEN 'Contractor'
            WHEN f.employment_designation ILIKE '%fte%'        THEN 'FTE'
            ELSE COALESCE(f.employment_designation, 'Unknown')
        END AS worker_type,
        f.forecasted_hours
    FROM ps_projects p
    JOIN ps_project_mapping m
        ON m.is_active = TRUE
       AND LOWER(m.ps_client_name) = LOWER(p.client_name)
       AND (m.ps_project_name IS NULL OR LOWER(m.ps_project_name) = LOWER(p.project_name))
    JOIN ps_resource_forecasts f
        ON (LOWER(f.client_name) = LOWER(m.clockify_client_name)
            -- Fallback: when forecast has no client, match on project name alone
            OR (f.client_name IS NULL AND m.clockify_project_name IS NOT NULL
                AND LOWER(f.project_name) = LOWER(m.clockify_project_name)))
       AND (m.clockify_project_name IS NULL OR LOWER(f.project_name) = LOWER(m.clockify_project_name))
       AND f.week_start_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE

    UNION ALL

    -- Tier 2: direct name match
    SELECT
        p.jira_issue_id,
        f.location,
        CASE
            WHEN f.employment_designation ILIKE '%contractor%' THEN 'Contractor'
            WHEN f.employment_designation ILIKE '%fte%'        THEN 'FTE'
            ELSE COALESCE(f.employment_designation, 'Unknown')
        END AS worker_type,
        f.forecasted_hours
    FROM ps_projects p
    JOIN ps_resource_forecasts f
        ON LOWER(f.client_name) = LOWER(p.client_name)
       AND (f.project_name IS NULL OR LOWER(f.project_name) = LOWER(p.project_name))
       AND f.week_start_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE
    WHERE NOT EXISTS (
        SELECT 1 FROM ps_project_mapping m
        WHERE m.is_active = TRUE
          AND LOWER(m.ps_client_name) = LOWER(p.client_name)
          AND (m.ps_project_name IS NULL OR LOWER(m.ps_project_name) = LOWER(p.project_name))
    )
),

-- Forecasts grouped by project + location + worker_type
forecasts_by_dim AS (
    SELECT jira_issue_id, location, worker_type, SUM(forecasted_hours) AS forecast_hours
    FROM project_forecast_raw
    GROUP BY jira_issue_id, location, worker_type
),

-- Project-level forecast totals
forecasts_total AS (
    SELECT
        jira_issue_id,
        SUM(forecast_hours)                                                         AS total_forecast_hours,
        SUM(CASE WHEN location = 'Onshore'       THEN forecast_hours ELSE 0 END)   AS onshore_forecast_hours,
        SUM(CASE WHEN location = 'Offshore'      THEN forecast_hours ELSE 0 END)   AS offshore_forecast_hours,
        SUM(CASE WHEN worker_type = 'Contractor'  THEN forecast_hours ELSE 0 END)  AS contractor_forecast_hours,
        SUM(CASE WHEN worker_type = 'FTE'         THEN forecast_hours ELSE 0 END)  AS fte_forecast_hours
    FROM forecasts_by_dim
    GROUP BY jira_issue_id
),

-- Union of all (project, location, worker_type) dimension combinations from actuals + forecasts
all_dims AS (
    SELECT jira_issue_id, location, worker_type FROM actuals_by_dim
    UNION
    SELECT jira_issue_id, location, worker_type FROM forecasts_by_dim
)

SELECT
    p.client_name,
    p.project_name,
    p.project_type,
    p.status                                                                        AS stage,
    p.project_manager,
    p.status_category,
    p.health_overall,
    p.health_budget,
    p.budget_hours,

    -- Dimension fields (location + worker_type for QuickSight filtering/grouping)
    d.location,
    d.worker_type,

    -- Hours for this specific location + worker_type combination
    COALESCE(ad.actual_hours, 0)                                                    AS actual_hours,
    COALESCE(fd.forecast_hours, 0)                                                  AS forecast_hours,

    -- Project-level actual totals (repeated per dimension row)
    COALESCE(at.total_actual_hours, 0)                                              AS total_actual_hours,
    COALESCE(at.onshore_actual_hours, 0)                                            AS onshore_actual_hours,
    COALESCE(at.offshore_actual_hours, 0)                                           AS offshore_actual_hours,
    COALESCE(at.contractor_actual_hours, 0)                                         AS contractor_actual_hours,
    COALESCE(at.fte_actual_hours, 0)                                                AS fte_actual_hours,

    -- Project-level forecast totals (repeated per dimension row)
    COALESCE(ft.total_forecast_hours, 0)                                            AS total_forecast_hours,
    COALESCE(ft.onshore_forecast_hours, 0)                                          AS onshore_forecast_hours,
    COALESCE(ft.offshore_forecast_hours, 0)                                         AS offshore_forecast_hours,
    COALESCE(ft.contractor_forecast_hours, 0)                                       AS contractor_forecast_hours,
    COALESCE(ft.fte_forecast_hours, 0)                                              AS fte_forecast_hours,

    -- Derived project-level metrics (repeated per dimension row)
    COALESCE(at.total_actual_hours, 0) + COALESCE(ft.total_forecast_hours, 0)      AS hours_at_completion,

    ROUND(
        (CASE WHEN p.budget_hours > 0
              THEN COALESCE(at.total_actual_hours, 0) / p.budget_hours * 100
              ELSE 0
         END)::NUMERIC, 1)                                                          AS budget_pct_consumed,

    ROUND(
        ((COALESCE(at.total_actual_hours, 0) + COALESCE(ft.total_forecast_hours, 0))
         - p.budget_hours)::NUMERIC, 1)                                             AS projected_overrun_hours,

    -- Cost mix percentages (actuals only, project-level)
    ROUND(
        (CASE WHEN COALESCE(at.total_actual_hours, 0) > 0
              THEN COALESCE(at.onshore_actual_hours, 0) / at.total_actual_hours * 100
              ELSE 0
         END)::NUMERIC, 1)                                                          AS onshore_pct,
    ROUND(
        (CASE WHEN COALESCE(at.total_actual_hours, 0) > 0
              THEN COALESCE(at.contractor_actual_hours, 0) / at.total_actual_hours * 100
              ELSE 0
         END)::NUMERIC, 1)                                                          AS contractor_pct,

    p.sow_link,
    p.jira_board_link,
    p.expected_completion,
    p.revised_completion

FROM ps_projects p
-- One row per dimension combo (NULL row when project has no actuals/forecasts yet)
LEFT JOIN all_dims d ON d.jira_issue_id = p.jira_issue_id
-- Dimension-specific hours
LEFT JOIN actuals_by_dim ad
    ON ad.jira_issue_id = d.jira_issue_id
   AND (ad.location IS NOT DISTINCT FROM d.location)
   AND ad.worker_type = d.worker_type
LEFT JOIN forecasts_by_dim fd
    ON fd.jira_issue_id = d.jira_issue_id
   AND (fd.location IS NOT DISTINCT FROM d.location)
   AND fd.worker_type = d.worker_type
-- Project-level totals (keyed on p.jira_issue_id, independent of d)
LEFT JOIN actuals_total at ON at.jira_issue_id = p.jira_issue_id
LEFT JOIN forecasts_total ft ON ft.jira_issue_id = p.jira_issue_id
ORDER BY p.client_name, p.project_name, d.location, d.worker_type;


-- ============================================================================
-- vw_ps_profitability_weekly_2026: Weekly trend view for the profitability tab
-- Shows actual hours by week broken out by location and employment type,
-- enabling trend charts in QuickSight.
-- Joins via ps_project_mapping (same hierarchy as vw_ps_profitability_2026)
-- rather than filtering on practice_alignment to ensure consistent scoping.
-- ============================================================================
DROP VIEW IF EXISTS vw_ps_profitability_weekly_2026;
CREATE VIEW vw_ps_profitability_weekly_2026 AS
WITH
-- Distinct PS projects from latest snapshot
ps_projects AS (
    SELECT DISTINCT client_name, project_name
    FROM ps_project_status
    WHERE category = 'PS'
      AND NOT (status_category = 'Done' AND actual_completion < DATE_TRUNC('year', CURRENT_DATE))
),
-- Clockify client/project keys that map to a PS project
-- Tier 1: explicit ps_project_mapping entries
-- Tier 2: direct name match where no explicit mapping exists
mapped_keys AS (
    SELECT
        LOWER(m.clockify_client_name)  AS ck_client,
        LOWER(m.clockify_project_name) AS ck_project   -- NULL means "any project for this client"
    FROM ps_project_mapping m
    JOIN ps_projects p
        ON LOWER(m.ps_client_name) = LOWER(p.client_name)
       AND (m.ps_project_name IS NULL OR LOWER(m.ps_project_name) = LOWER(p.project_name))
    WHERE m.is_active = TRUE

    UNION ALL

    -- Direct name match fallback (only when no explicit mapping covers this PS project)
    SELECT
        LOWER(p.client_name)  AS ck_client,
        LOWER(p.project_name) AS ck_project
    FROM ps_projects p
    WHERE NOT EXISTS (
        SELECT 1 FROM ps_project_mapping m
        WHERE m.is_active = TRUE
          AND LOWER(m.ps_client_name) = LOWER(p.client_name)
          AND (m.ps_project_name IS NULL OR LOWER(m.ps_project_name) = LOWER(p.project_name))
    )
)
SELECT
    DATE_TRUNC('week', te.entry_date)::DATE        AS week_start,
    te.client_name,
    te.project_name,
    te.location,
    CASE
        WHEN te.employment_designation ILIKE '%contractor%' THEN 'Contractor'
        WHEN te.employment_designation ILIKE '%fte%'        THEN 'FTE'
        ELSE COALESCE(te.employment_designation, 'Unknown')
    END                                            AS worker_type,
    SUM(te.duration_hours)                         AS actual_hours,
    COUNT(DISTINCT te.clockify_user_id)            AS resource_count
FROM clockify_detailed_time_entries te
WHERE te.entry_date >= DATE_TRUNC('year', CURRENT_DATE)::DATE
  AND EXISTS (
      SELECT 1 FROM mapped_keys mk
      WHERE mk.ck_client = LOWER(te.client_name)
        AND (mk.ck_project IS NULL OR mk.ck_project = LOWER(te.project_name))
  )
GROUP BY
    DATE_TRUNC('week', te.entry_date)::DATE,
    te.client_name,
    te.project_name,
    te.location,
    CASE
        WHEN te.employment_designation ILIKE '%contractor%' THEN 'Contractor'
        WHEN te.employment_designation ILIKE '%fte%'        THEN 'FTE'
        ELSE COALESCE(te.employment_designation, 'Unknown')
    END
ORDER BY week_start, te.client_name, te.project_name;


-- ============================================================================
-- vw_ps_profitability_chart: Unpivoted view for QuickSight stacked bar charts
-- Grain: one row per (project, location, worker_type, bar_type)
-- bar_type: 'Actual' (YTD actuals) | 'Forecast' (remaining future weeks)
-- segment: 'Onshore FTE', 'Offshore Contractor', etc. (location + worker_type)
-- QuickSight setup: X-axis=project_name, Cluster=bar_type, Stack=segment, Value=hours
-- ============================================================================
DROP VIEW IF EXISTS vw_ps_profitability_chart;
CREATE VIEW vw_ps_profitability_chart AS
WITH
proj AS (
    -- One row per project with project-level metadata
    SELECT DISTINCT ON (client_name, project_name)
        client_name, project_name, project_type, stage, project_manager,
        status_category, health_overall, health_budget, budget_hours,
        total_actual_hours, total_forecast_hours, hours_at_completion,
        budget_pct_consumed, projected_overrun_hours,
        sow_link, jira_board_link, expected_completion, revised_completion
    FROM vw_ps_profitability_2026
    ORDER BY client_name, project_name
),
dims AS (
    -- Dimension rows (excludes NULL-dim sentinel row for projects with no data)
    -- segment: uses location prefix only when location is known (avoids 'Unknown FTE')
    SELECT
        client_name, project_name, location, worker_type,
        CASE
            WHEN location IS NOT NULL AND location != 'Unknown' THEN location || ' ' || COALESCE(worker_type, 'Unknown')
            ELSE COALESCE(worker_type, 'Unknown')
        END AS segment,
        actual_hours, forecast_hours
    FROM vw_ps_profitability_2026
    WHERE location IS NOT NULL OR worker_type IS NOT NULL
)
-- Actual hours rows
SELECT
    p.client_name, p.project_name,
    p.client_name || CASE WHEN p.project_name IS NOT NULL THEN ' - ' || p.project_name ELSE '' END AS project_label,
    p.project_type, p.stage, p.project_manager,
    p.status_category, p.health_overall, p.health_budget, p.budget_hours,
    p.total_actual_hours, p.total_forecast_hours, p.hours_at_completion,
    p.budget_pct_consumed, p.projected_overrun_hours,
    p.sow_link, p.jira_board_link, p.expected_completion, p.revised_completion,
    d.location, d.worker_type, d.segment,
    'Actual'::TEXT  AS bar_type,
    'Actual · ' || d.segment AS stack_label,
    d.actual_hours  AS hours,
    EXTRACT(EPOCH FROM p.expected_completion)::BIGINT AS completion_epoch
FROM proj p
JOIN dims d USING (client_name, project_name)
WHERE d.actual_hours > 0

UNION ALL

-- Forecast hours rows
SELECT
    p.client_name, p.project_name,
    p.client_name || CASE WHEN p.project_name IS NOT NULL THEN ' - ' || p.project_name ELSE '' END AS project_label,
    p.project_type, p.stage, p.project_manager,
    p.status_category, p.health_overall, p.health_budget, p.budget_hours,
    p.total_actual_hours, p.total_forecast_hours, p.hours_at_completion,
    p.budget_pct_consumed, p.projected_overrun_hours,
    p.sow_link, p.jira_board_link, p.expected_completion, p.revised_completion,
    d.location, d.worker_type, d.segment,
    'Forecast'::TEXT AS bar_type,
    'Forecast · ' || d.segment AS stack_label,
    d.forecast_hours AS hours,
    EXTRACT(EPOCH FROM p.expected_completion)::BIGINT AS completion_epoch
FROM proj p
JOIN dims d USING (client_name, project_name)
WHERE d.forecast_hours > 0

UNION ALL

-- Placeholder rows for projects with no actuals and no forecasts
-- Ensures all 18 projects appear in the chart with their SOW budget line
SELECT
    p.client_name, p.project_name,
    p.client_name || CASE WHEN p.project_name IS NOT NULL THEN ' - ' || p.project_name ELSE '' END AS project_label,
    p.project_type, p.stage, p.project_manager,
    p.status_category, p.health_overall, p.health_budget, p.budget_hours,
    p.total_actual_hours, p.total_forecast_hours, p.hours_at_completion,
    p.budget_pct_consumed, p.projected_overrun_hours,
    p.sow_link, p.jira_board_link, p.expected_completion, p.revised_completion,
    NULL AS location, NULL AS worker_type, NULL AS segment,
    'No Data'::TEXT AS bar_type, 'No Data'::TEXT AS stack_label,
    0 AS hours,
    EXTRACT(EPOCH FROM p.expected_completion)::BIGINT AS completion_epoch
FROM proj p
WHERE NOT EXISTS (
    SELECT 1 FROM dims d
    WHERE d.client_name = p.client_name
      AND COALESCE(d.project_name, '') = COALESCE(p.project_name, '')
      AND (d.actual_hours > 0 OR d.forecast_hours > 0)
)

ORDER BY client_name, project_name, bar_type DESC, segment;


-- ============================================================================
-- vw_data_freshness: Last successful import timestamp per category
-- Used by QuickSight dashboards to display "Data as of" date
-- ============================================================================
CREATE OR REPLACE VIEW vw_data_freshness AS
SELECT
    import_category,
    MAX(completed_at) AS last_import_at,
    TO_CHAR(MAX(completed_at) AT TIME ZONE 'UTC' AT TIME ZONE 'America/Chicago', 'Mon DD, YYYY HH12:MI AM') AS last_import_display
FROM import_logs
WHERE status IN ('success', 'partial')
GROUP BY import_category;


-- ============================================================================
-- vw_mc_v2_audit_grid: MC V2 Audit pivoted — one row per customer per week
-- Phases (by phase_order 1-4) spread across columns.
-- Pod stored at audit time in mc_v2_audit_by_customer.pod.
-- ============================================================================
DROP VIEW IF EXISTS vw_mc_v2_audit_grid;
CREATE OR REPLACE VIEW vw_mc_v2_audit_grid AS
WITH latest AS (
    -- One row per customer: the most recent audit run
    SELECT DISTINCT ON (customer_name)
        *
    FROM mc_v2_audit_by_customer
    ORDER BY customer_name, week_start DESC
)
SELECT
    c.week_start,
    COALESCE(c.pod, 'Unassigned')                                AS pod,
    c.customer_name,
    c.jira_project_key,
    c.overall_completion_pct,

    -- Phase completion percentages (used as QuickSight table column headers)
    MAX(CASE WHEN p.phase_order = 1 THEN p.completion_pct END) AS onboarding_pct,
    MAX(CASE WHEN p.phase_order = 2 THEN p.completion_pct END) AS stabilize_pct,
    MAX(CASE WHEN p.phase_order = 3 THEN p.completion_pct END) AS operate_pct,
    MAX(CASE WHEN p.phase_order = 4 THEN p.completion_pct END) AS modernize_pct,

    -- Narrative — last column
    c.executive_summary

FROM latest c
LEFT JOIN mc_v2_audit_by_phase p
       ON p.customer_name = c.customer_name
      AND p.week_start    = c.week_start
GROUP BY
    c.week_start,
    c.pod,
    c.customer_name,
    c.jira_project_key,
    c.overall_completion_pct,
    c.executive_summary
ORDER BY pod, c.customer_name;


-- ============================================================================
-- vw_project_hours_by_assignment: Weekly hours by project/client assignment.
-- Groups Clockify time entries into MC customers, PS clients, and Other.
-- Uses ps_project_mapping (Tier 1) then direct client name match (Tier 2).
--
-- hour_type breakdown per row:
--   billable_hours          = billable = TRUE
--   non_billable_hours      = billable = FALSE on a recognised MC/PS project
--   non_billable_productive = billable = FALSE on any project (same as above,
--                             exposed as a separate column for QS calculated fields)
--   other_hours             = hours on unclassified clients (overhead/admin)
--
-- Classification: project-based via ps_project_mapping.category (FR-CCR-008 compliant)
-- ============================================================================
DROP VIEW IF EXISTS vw_project_hours_by_assignment CASCADE;
CREATE VIEW vw_project_hours_by_assignment AS
WITH

-- ----------------------------------------------------------------
-- Clean Clockify project attributes (strip JSON brace formatting)
-- ----------------------------------------------------------------
cp_clean AS (
    SELECT
        clockify_project_id,
        name                                                              AS project_name,
        client_name,
        billable,
        project_type,
        NULLIF(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
            COALESCE(pod_assignment,''),'{',''),'}',''),'"',''),'\','')), '') AS pod_assignment
    FROM clockify_projects
),

-- ----------------------------------------------------------------
-- Classify each time entry using Clockify fields as primary source.
-- ps_project_mapping is used ONLY to resolve canonical customer name
-- and link to Jira category (PS/MC) — NOT for billable classification.
-- ----------------------------------------------------------------
classified AS (
    SELECT
        DATE_TRUNC('week', te.entry_date)::DATE                           AS week_start,
        te.client_name                                                    AS clockify_client,
        te.project_name,
        te.clockify_user_id,
        te.duration_hours,

        -- Billable: from Clockify project flag (authoritative)
        COALESCE(cp.billable, te.billable, FALSE)                         AS billable,

        -- project_type: from Clockify project (authoritative)
        cp.project_type,

        -- pod: from Clockify project (authoritative)
        cp.pod_assignment                                                  AS pod,

        -- category (PS/MC/FinOps): derived from Clockify project_type first,
        -- fall back to ps_project_mapping for PS/MC distinction when type is generic
        CASE
            WHEN cp.project_type = 'Professional Services'                THEN 'PS'
            WHEN cp.project_type IN ('Managed Cloud',
                                     'Managed Cloud and Managed IT',
                                     'Managed IT')                        THEN 'MC'
            WHEN cp.project_type = 'FinOps'                               THEN 'FinOps'
            WHEN cp.project_type IN ('Presales', 'Overtime',
                                     'Non Bill Productive',
                                     'Non Bill Non Productive',
                                     'Overhead', 'Training and Certs',
                                     'Internal Initiatives',
                                     'Product Development')               THEN 'Internal'
            -- Fall back to mapping table for unclassified projects
            ELSE COALESCE(m.category, 'Other')
        END                                                               AS category,

        -- customer_name: Clockify client_name is authoritative.
        -- Use mapping table canonical name only when it provides a cleaner
        -- PS/MC project name (e.g. normalises "ALBERT WEISS" → "Albert Weiss")
        COALESCE(m.ps_client_name, te.client_name)                        AS customer_name

    FROM clockify_detailed_time_entries te
    LEFT JOIN cp_clean cp ON te.clockify_project_id = cp.clockify_project_id
    -- Mapping join: client-level only, for canonical name + category fallback
    LEFT JOIN ps_project_mapping m
           ON LOWER(te.client_name) = LOWER(m.clockify_client_name)
          AND (m.clockify_project_name IS NULL
               OR LOWER(te.project_name) = LOWER(m.clockify_project_name))
          AND m.is_active = TRUE
    WHERE te.client_name IS NOT NULL
      AND te.duration_hours > 0
)

SELECT
    week_start,
    category,
    customer_name,
    -- Pod: from Clockify project; fall back to 'N/A' only when truly unset
    COALESCE(NULLIF(pod, ''), 'N/A')                                      AS pod,
    clockify_client,
    project_name,
    -- project_type label for display
    COALESCE(project_type, 'Unclassified')                                AS clockify_project_type,
    COUNT(DISTINCT clockify_user_id)                                      AS resource_count,
    ROUND(SUM(duration_hours)::NUMERIC, 2)                                AS total_hours,

    -- Billable: driven by Clockify billable flag on the project
    ROUND(SUM(CASE WHEN billable THEN duration_hours ELSE 0 END)::NUMERIC, 2)
                                                                          AS billable_hours,

    -- Non-billable total
    ROUND(SUM(CASE WHEN NOT billable THEN duration_hours ELSE 0 END)::NUMERIC, 2)
                                                                          AS non_billable_hours,

    -- Non-billable productive: Clockify project_type drives this
    ROUND(SUM(CASE
        WHEN NOT billable AND project_type IN (
            'Non Bill Productive', 'Overtime', 'Presales',
            'Overhead', 'Training and Certs',
            'Internal Initiatives', 'Product Development'
        ) THEN duration_hours
        WHEN NOT billable AND project_type IS NULL THEN duration_hours  -- unclassified non-billable → productive
        ELSE 0
    END)::NUMERIC, 2)                                                     AS non_billable_productive_hours,

    -- Non-billable non-productive: only explicit Clockify type
    ROUND(SUM(CASE
        WHEN NOT billable AND project_type = 'Non Bill Non Productive' THEN duration_hours
        ELSE 0
    END)::NUMERIC, 2)                                                     AS non_billable_non_productive_hours,

    -- Dominant billing type label for this project row
    CASE
        WHEN SUM(CASE WHEN billable THEN duration_hours ELSE 0 END) > 0
         AND SUM(CASE WHEN NOT billable THEN duration_hours ELSE 0 END) = 0
            THEN 'Billable'
        WHEN SUM(CASE WHEN NOT billable AND project_type = 'Non Bill Non Productive'
                      THEN duration_hours ELSE 0 END) > 0
         AND SUM(CASE WHEN billable THEN duration_hours ELSE 0 END) = 0
            THEN 'Non-Billable Non-Productive'
        WHEN SUM(CASE WHEN NOT billable THEN duration_hours ELSE 0 END) > 0
         AND SUM(CASE WHEN billable THEN duration_hours ELSE 0 END) = 0
            THEN 'Non-Billable Productive'
        ELSE 'Mixed'
    END                                                                   AS project_type
FROM classified
GROUP BY
    week_start, category, customer_name, pod, clockify_client, project_name, project_type
ORDER BY
    week_start DESC, category, total_hours DESC;

-- ============================================================================
-- AI Forecast Analysis tables (created here so apply_views ensures they exist)
-- ============================================================================
CREATE TABLE IF NOT EXISTS ai_forecast_analysis (
    id                      SERIAL PRIMARY KEY,
    week_start              DATE NOT NULL,
    weeks_analyzed          INTEGER NOT NULL,
    user_name               VARCHAR(255) NOT NULL,
    location                VARCHAR(100),
    employment_designation  VARCHAR(100),
    total_forecasted_hours  NUMERIC(8,1),
    total_actual_hours      NUMERIC(8,1),
    variance_hours          NUMERIC(8,1),
    pct_achieved            NUMERIC(6,1),
    status                  VARCHAR(50),
    notes                   TEXT,
    analyzed_at             TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ai_forecast_summary (
    id                      SERIAL PRIMARY KEY,
    week_start              DATE NOT NULL,
    weeks_analyzed          INTEGER NOT NULL,
    total_resources         INTEGER,
    on_track_count          INTEGER,
    over_count              INTEGER,
    under_count             INTEGER,
    critical_under_count    INTEGER,
    no_actuals_count        INTEGER,
    unforecasted_count      INTEGER,
    key_observations        TEXT,
    recommendations         TEXT,
    analyzed_at             TIMESTAMP DEFAULT NOW()
);

INSERT INTO ai_analysis_prompts (category, sequence_order, prompt_text, is_active)
SELECT 'FORECAST', 1,
'You are a resource planning analyst for a professional services firm.
Review the forecast vs actual hours data below for the specified period.

For each resource: classify their utilization status and provide a one-sentence observation.

Status classifications:
- On Track: 80-120% of forecast achieved
- Over: >120% of forecast
- Under: 50-80% of forecast
- Critical Under: <50% of forecast (only when total_forecasted_hours > 10)
- No Actuals: forecasted hours exist but zero logged
- Unforecasted: hours logged with no forecast at all

Pay particular attention to:
- Resources with zero actuals despite significant forecasts (time submission or engagement issues)
- Completely unforecasted resources logging full weeks (planning gaps)
- Resources consistently below 50% of forecast (capacity or project issues)

Provide 3-5 key observations and 2-3 actionable recommendations for the delivery management team.
Return ONLY valid JSON matching the schema provided — no prose, no markdown.', TRUE
WHERE NOT EXISTS (SELECT 1 FROM ai_analysis_prompts WHERE category = 'FORECAST');

-- ============================================================
-- AI PM Forecast Accuracy table
-- ============================================================

CREATE TABLE IF NOT EXISTS ai_pm_forecast_accuracy (
    id                      SERIAL PRIMARY KEY,
    week_start              DATE NOT NULL,
    weeks_analyzed          INTEGER NOT NULL,
    pm_name                 VARCHAR(255) NOT NULL,
    project_resource_combos INTEGER,
    resources_forecasted    INTEGER,
    total_forecasted        NUMERIC(8,1),
    total_actual            NUMERIC(8,1),
    overall_pct             NUMERIC(6,1),
    accuracy_score          NUMERIC(6,1),
    narrative               TEXT,
    analyzed_at             TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ai_pm_forecast_accuracy_week
    ON ai_pm_forecast_accuracy(week_start);

-- ============================================================
-- Escalations table + views
-- ============================================================

CREATE TABLE IF NOT EXISTS escalations (
    id                  SERIAL PRIMARY KEY,
    jira_issue_id       VARCHAR(50) UNIQUE NOT NULL,
    issue_key           VARCHAR(50) NOT NULL,
    customer_name       VARCHAR(255),
    epic_key            VARCHAR(50),
    epic_summary        VARCHAR(500),
    summary             VARCHAR(500),
    status              VARCHAR(100),
    status_category     VARCHAR(50),
    priority            VARCHAR(50),
    assignee_name       VARCHAR(255),
    reporter_name       VARCHAR(255),
    created_date        TIMESTAMP,
    updated_date        TIMESTAMP,
    resolution_date     TIMESTAMP,
    days_open           INTEGER,
    days_to_resolve     INTEGER,
    description         TEXT,
    previous_status     VARCHAR(100),
    status_changed_at   TIMESTAMP,
    synced_at           TIMESTAMP DEFAULT NOW()
);

-- Add new columns if upgrading from an older schema
ALTER TABLE escalations ADD COLUMN IF NOT EXISTS description       TEXT;
ALTER TABLE escalations ADD COLUMN IF NOT EXISTS previous_status   VARCHAR(100);
ALTER TABLE escalations ADD COLUMN IF NOT EXISTS status_changed_at TIMESTAMP;

CREATE INDEX IF NOT EXISTS idx_escalations_customer ON escalations(customer_name);
CREATE INDEX IF NOT EXISTS idx_escalations_status   ON escalations(status_category);
CREATE INDEX IF NOT EXISTS idx_escalations_created  ON escalations(created_date);

-- Flat detail view for ticket-level analysis
DROP VIEW IF EXISTS vw_escalations CASCADE;
CREATE VIEW vw_escalations AS
SELECT
    issue_key,
    customer_name,
    epic_key,
    summary,
    description,
    status,
    status_category,
    priority,
    -- Priority sort order for consistent display (Highest first)
    CASE priority
        WHEN 'Highest' THEN 1
        WHEN 'High'    THEN 2
        WHEN 'Medium'  THEN 3
        WHEN 'Low'     THEN 4
        WHEN 'Lowest'  THEN 5
        ELSE 6
    END                                         AS priority_order,
    assignee_name,
    reporter_name,
    created_date::date                          AS created_date,
    updated_date::date                          AS updated_date,
    resolution_date::date                       AS resolution_date,
    status_changed_at::date                     AS status_changed_at,
    previous_status,
    days_open,
    days_to_resolve,
    EXTRACT(YEAR FROM created_date)::int        AS created_year,
    EXTRACT(MONTH FROM created_date)::int       AS created_month,
    TO_CHAR(created_date, 'YYYY-MM')            AS created_month_label,
    CASE
        WHEN status_category = 'Done'        THEN 'Done'
        WHEN status = 'Watching'             THEN 'Watching'
        WHEN status_category = 'In Progress' THEN 'In Progress'
        ELSE 'New'
    END                                         AS escalation_state,
    -- True if created in the last 7 days
    (created_date >= CURRENT_DATE - INTERVAL '7 days') AS is_new,
    -- True if status changed or issue was updated in the last 7 days
    (
        updated_date >= CURRENT_DATE - INTERVAL '7 days'
        OR status_changed_at >= CURRENT_DATE - INTERVAL '7 days'
    )                                           AS changed_last_week
FROM escalations
WHERE customer_name IS NOT NULL;

-- Aggregated per-customer summary for executive KPI view
CREATE OR REPLACE VIEW vw_escalations_by_customer AS
SELECT
    customer_name,
    COUNT(*)                                                                                 AS total_escalations,
    COUNT(*) FILTER (WHERE status_category != 'Done')                                        AS open_escalations,
    COUNT(*) FILTER (WHERE status_category = 'Done')                                         AS resolved_escalations,
    COUNT(*) FILTER (WHERE priority IN ('High', 'Highest'))                                  AS high_priority_count,
    ROUND(AVG(days_to_resolve) FILTER (WHERE days_to_resolve IS NOT NULL), 1)                AS avg_days_to_resolve,
    ROUND(AVG(days_open)       FILTER (WHERE days_open IS NOT NULL), 1)                      AS avg_days_open,
    MAX(created_date)::date                                                                   AS most_recent_escalation,
    MIN(created_date)::date                                                                   AS first_escalation
FROM escalations
WHERE customer_name IS NOT NULL
GROUP BY customer_name;

-- Week-over-week stage count trend for PS projects (standard pipeline stages only)
DROP VIEW IF EXISTS vw_ps_stage_trend;
CREATE VIEW vw_ps_stage_trend AS
WITH
ps_stages AS (
    SELECT unnest(ARRAY[
        'INTERNAL PREP: SOW SIGNED',
        'INTERNAL PREP: TEAM ASSIGNED',
        'INTERNAL PREP: INTERNAL KICKOFF',
        'CUSTOMER KICKOFF',
        'DISCOVER AND ALIGN',
        'DESIGN AND REVIEW',
        'BUILD AND IMPLEMENT',
        'LAUNCH AND ENABLE'
    ]) AS stage
),
latest AS (
    SELECT MAX(week_start) AS week_start FROM ps_stage_weekly_snapshot
),
prev AS (
    SELECT MAX(week_start) AS week_start
    FROM ps_stage_weekly_snapshot
    WHERE week_start < (SELECT week_start FROM latest)
),
curr_data AS (
    SELECT s.stage, s.project_count, s.sort_order
    FROM ps_stage_weekly_snapshot s
    JOIN latest l ON s.week_start = l.week_start
    WHERE s.category = 'PS'
      AND s.stage IN (SELECT stage FROM ps_stages)
),
prev_data AS (
    SELECT s.stage, s.project_count, s.sort_order
    FROM ps_stage_weekly_snapshot s
    JOIN prev p ON s.week_start = p.week_start
    WHERE s.category = 'PS'
      AND s.stage IN (SELECT stage FROM ps_stages)
)
SELECT
    COALESCE(c.sort_order, pd.sort_order)                            AS sort_order,
    COALESCE(c.stage, pd.stage)                                      AS stage,
    COALESCE(c.project_count, 0)                                     AS this_week_count,
    COALESCE(pd.project_count, 0)                                    AS prev_week_count,
    COALESCE(c.project_count, 0) - COALESCE(pd.project_count, 0)    AS change,
    CASE
        WHEN COALESCE(c.project_count, 0) > COALESCE(pd.project_count, 0) THEN 'up'
        WHEN COALESCE(c.project_count, 0) < COALESCE(pd.project_count, 0) THEN 'down'
        ELSE 'same'
    END                                                              AS trend,
    (SELECT week_start FROM latest)                                  AS current_week,
    (SELECT week_start FROM prev)                                    AS previous_week
FROM curr_data c
FULL OUTER JOIN prev_data pd ON c.stage = pd.stage;

-- ============================================================
-- Productive Utilization by Employee (weekly grain)
-- Scope: active users with daily_capacity > 0, not in Exempt pod
-- Categories:
--   Billable              = te.billable = TRUE
--   Non-Bill Productive   = cp.project_type='Non Bill Productive'
--                           OR (non-billable on a ps_project_mapping-recognised client)
--   Non-Bill Non-Productive = cp.project_type='Non Bill Non Productive'
--                           OR non-billable on unrecognised client
--   Non-Logged            = available_hours - total_logged  (treated as non-productive)
-- ============================================================
CREATE OR REPLACE VIEW vw_productive_utilization AS
WITH mapped_clients AS (
    SELECT DISTINCT LOWER(clockify_client_name) AS client_lower
    FROM ps_project_mapping
    WHERE is_active = TRUE
),
active_users AS (
    SELECT
        u.clockify_user_id,
        u.name                                                                                                          AS employee_name,
        COALESCE(NULLIF(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.pod_assignment,     '{',''),'}',''),'"',''),'\','')), ''), 'Not Assigned') AS pod_assignment,
        COALESCE(NULLIF(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.practice_alignment, '{',''),'}',''),'"',''),'\','')), ''), 'Not Assigned') AS practice_alignment,
        u.cloudelligent_title,
        u.location,
        u.employment_designation,
        u.daily_capacity,
        u.daily_capacity * 5                                                                                           AS weekly_available_hours,
        u.created_at::DATE                                                                                             AS user_created_date
    FROM clockify_users u
    WHERE u.status = 'active'
      AND u.daily_capacity > 0
      AND COALESCE(u.time_submission, '') != 'No'
      AND (u.pod_assignment IS NULL OR u.pod_assignment NOT ILIKE '%exempt%')
      AND NOT COALESCE(u.reporting_excluded, FALSE)
),
week_spine AS (
    SELECT DISTINCT week_start
    FROM clockify_detailed_time_entries
    WHERE week_start IS NOT NULL
      AND week_start < DATE_TRUNC('week', CURRENT_DATE)::DATE
),
user_weeks AS (
    SELECT u.*, w.week_start
    FROM active_users u
    CROSS JOIN week_spine w
    WHERE u.user_created_date <= w.week_start + 6
),
time_classified AS (
    SELECT
        te.clockify_user_id,
        te.week_start,
        -- Priority: 1) billable flag  2) project_type  3) mapping fallback
        SUM(CASE
            WHEN te.billable = TRUE                                                              THEN te.duration_hours
            ELSE 0
        END)                                                                                     AS billable_hours,
        SUM(CASE WHEN te.is_nb_productive     = TRUE THEN te.duration_hours ELSE 0 END)          AS nb_productive_hours,
        SUM(CASE WHEN te.is_nb_non_productive = TRUE THEN te.duration_hours ELSE 0 END)          AS nb_non_productive_hours,
        SUM(te.duration_hours)                                                                   AS total_logged_hours
    FROM clockify_detailed_time_entries te
    LEFT JOIN clockify_projects cp
           ON te.clockify_project_id = cp.clockify_project_id
    LEFT JOIN mapped_clients mc
           ON LOWER(te.client_name) = mc.client_lower
    WHERE te.week_start IS NOT NULL
    GROUP BY te.clockify_user_id, te.week_start
)
SELECT
    uw.employee_name,
    uw.pod_assignment,
    uw.cloudelligent_title,
    uw.practice_alignment,
    uw.location,
    uw.employment_designation,
    uw.week_start,
    uw.weekly_available_hours                                                                    AS available_hours,
    COALESCE(t.billable_hours,          0)                                                      AS billable_hours,
    COALESCE(t.nb_productive_hours,     0)                                                      AS nb_productive_hours,
    COALESCE(t.nb_non_productive_hours, 0)                                                      AS nb_non_productive_hours,
    GREATEST(uw.weekly_available_hours - COALESCE(t.total_logged_hours, 0), 0)                  AS non_logged_hours,
    COALESCE(t.total_logged_hours,      0)                                                      AS total_logged_hours
FROM user_weeks uw
LEFT JOIN time_classified t
       ON t.clockify_user_id = uw.clockify_user_id
      AND t.week_start       = uw.week_start;

-- ============================================================
-- Time Submission Weekly History
-- One row per active non-exempt user per complete week.
-- Includes compliance flag and reason (if recorded).
-- Used for two QuickSight visuals:
--   1. Weekly detail table (filter to 1 week, shows reason)
--   2. Compliance % by month/quarter/year (aggregate all weeks)
-- ============================================================
CREATE OR REPLACE VIEW vw_time_submission_weekly AS
WITH week_spine AS (
    SELECT DISTINCT week_start
    FROM clockify_detailed_time_entries
    WHERE week_start IS NOT NULL
      AND week_start < DATE_TRUNC('week', CURRENT_DATE)::DATE
),
active_users AS (
    SELECT
        u.clockify_user_id,
        u.name,
        TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.pod_assignment,     '{',''),'}',''),'"',''),'\','')) AS pod_assignment,
        TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.practice_alignment, '{',''),'}',''),'"',''),'\','')) AS practice_alignment,
        u.cloudelligent_title,
        u.location,
        u.employment_designation,
        u.daily_capacity,
        u.daily_capacity * 5 AS weekly_expected_hours,
        u.created_at::DATE   AS user_created_date
    FROM clockify_users u
    WHERE u.status = 'active'
      AND u.daily_capacity > 0
      AND (u.pod_assignment IS NULL OR u.pod_assignment NOT ILIKE '%exempt%')
      AND (u.time_submission IS NULL OR UPPER(TRIM(u.time_submission)) != 'NO')
),
user_weeks AS (
    SELECT u.*, w.week_start
    FROM active_users u
    CROSS JOIN week_spine w
    WHERE u.user_created_date <= w.week_start + 6
),
user_hours AS (
    SELECT
        te.clockify_user_id,
        te.week_start,
        SUM(te.duration_hours) AS hours_submitted,
        COUNT(*)               AS entry_count
    FROM clockify_detailed_time_entries te
    WHERE te.week_start IS NOT NULL
    GROUP BY te.clockify_user_id, te.week_start
)
SELECT
    uw.name                                                                               AS employee_name,
    uw.pod_assignment,
    uw.cloudelligent_title,
    uw.practice_alignment,
    uw.location,
    uw.employment_designation,
    uw.week_start,
    uw.weekly_expected_hours,
    COALESCE(h.hours_submitted, 0)                                                        AS hours_submitted,
    COALESCE(h.entry_count, 0)                                                            AS entry_count,
    CASE
        WHEN COALESCE(h.hours_submitted, 0) >= uw.weekly_expected_hours * 0.9            THEN 'Complete'
        WHEN COALESCE(h.hours_submitted, 0) >= uw.weekly_expected_hours * 0.5            THEN 'Less Than 90%'
        WHEN COALESCE(h.hours_submitted, 0) >  0                                         THEN 'Less Than 50%'
        ELSE                                                                                   'No Time Submitted'
    END                                                                                   AS submission_status,
    CASE
        WHEN COALESCE(h.hours_submitted, 0) >= uw.weekly_expected_hours * 0.9            THEN 1
        ELSE 0
    END                                                                                   AS is_compliant
FROM user_weeks uw
LEFT JOIN user_hours h
       ON h.clockify_user_id = uw.clockify_user_id
      AND h.week_start       = uw.week_start;

-- ============================================================
-- Weekly Compliance Report (current reporting week, all users)
-- One row per active non-exempt user for the last complete week.
-- Includes both compliant and non-compliant users so QuickSight
-- can compute compliance rates alongside the missing-time detail.
-- ============================================================
CREATE OR REPLACE VIEW vw_weekly_compliance_report AS
WITH reporting_week AS (
    SELECT (DATE_TRUNC('week', CURRENT_DATE)::DATE - 7)::DATE AS week_start_date
),
last_clockify_import AS (
    SELECT
        (completed_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Chicago')::DATE AS last_updated_date,
        TO_CHAR(completed_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Chicago', 'HH:MI AM') AS last_updated_time
    FROM import_logs
    WHERE import_category = 'time_entries'
      AND status = 'success'
    ORDER BY completed_at DESC
    LIMIT 1
),
user_hours AS (
    SELECT
        te.clockify_user_id,
        SUM(te.duration_hours) AS hours_submitted,
        COUNT(*)               AS entry_count
    FROM clockify_detailed_time_entries te
    WHERE te.week_start = (SELECT week_start_date FROM reporting_week)
    GROUP BY te.clockify_user_id
)
SELECT
    u.name                                                                                     AS employee_name,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.pod_assignment,     '{',''),'}',''),'"',''),'\','')) AS pod_assignment,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.practice_alignment, '{',''),'}',''),'"',''),'\','')) AS practice_alignment,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.skill_area,         '{',''),'}',''),'"',''),'\','')) AS skill_area,
    u.cloudelligent_title,
    u.location,
    u.employment_designation,
    u.daily_capacity * 5                                                                       AS weekly_expected_hours,
    COALESCE(h.hours_submitted, 0)                                                             AS hours_submitted,
    COALESCE(h.entry_count, 0)                                                                 AS entry_count,
    CASE
        WHEN COALESCE(h.hours_submitted, 0) > 0 THEN 'Complete'
        ELSE                                         'No Time Submitted'
    END                                                                                        AS submission_status,
    CASE
        WHEN COALESCE(h.hours_submitted, 0) > 0 THEN 1
        ELSE 0
    END                                                                                        AS is_compliant,
    (SELECT week_start_date  FROM reporting_week)                                              AS week_start_date,
    (SELECT last_updated_date FROM last_clockify_import)                                       AS last_updated_date,
    (SELECT last_updated_time FROM last_clockify_import)                                       AS last_updated_time
FROM clockify_users u
LEFT JOIN user_hours h ON u.clockify_user_id = h.clockify_user_id
WHERE u.status = 'active'
  AND u.daily_capacity > 0
  AND (u.pod_assignment IS NULL OR u.pod_assignment NOT ILIKE '%exempt%')
  AND (u.time_submission IS NULL OR UPPER(TRIM(u.time_submission)) != 'NO')
  AND u.created_at::DATE <= (SELECT week_start_date FROM reporting_week) + INTERVAL '6 days'
ORDER BY is_compliant, pod_assignment, employee_name;

-- ============================================================
-- vw_project_time_detail
-- Detailed time entries for the past 4 complete weeks.
-- Used by the "Project Time Detail" dashboard tab.
-- Filterable by client, project, week, user, task.
-- ============================================================
DROP VIEW IF EXISTS vw_project_time_detail;
CREATE VIEW vw_project_time_detail AS
SELECT
    te.clockify_entry_id,
    te.entry_date,
    DATE_TRUNC('week', te.entry_date)::DATE         AS week_start_date,
    te.client_name,
    te.project_name,
    cp.project_type,
    NULLIF(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
        COALESCE(cp.pod_assignment, ''), '{',''),'}',''),'"',''),'\','')), '') AS pod_assignment,
    te.task_name,
    te.description,
    te.user_name,
    te.billable,
    ROUND(te.duration_hours::NUMERIC, 2)            AS duration_hours
FROM clockify_detailed_time_entries te
LEFT JOIN clockify_projects cp ON te.clockify_project_id = cp.clockify_project_id
WHERE te.entry_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE - INTERVAL '4 weeks'
  AND te.entry_date <  DATE_TRUNC('week', CURRENT_DATE)::DATE
  AND te.duration_hours > 0
ORDER BY te.entry_date DESC, te.client_name, te.project_name, te.user_name;

-- ============================================================
-- vw_project_directory
-- One row per (project, resource role) for use in the Project
-- Directory dashboard tab.  Unpivots PM / SA / Engineer / AE / CSM;
-- engineers stored as comma-separated strings are split into
-- individual rows so each person gets their own line.
-- ============================================================
DROP VIEW IF EXISTS vw_project_directory;
CREATE VIEW vw_project_directory AS
WITH base AS (
    SELECT
        p.issue_key,
        p.client_name,
        p.project_name,
        p.category,
        p.project_type,
        p.status,
        p.status_category,
        p.health_overall                             AS health,
        p.project_manager,
        p.solution_architect,
        p.engineer,
        p.account_executive,
        p.csm,
        p.actual_kickoff                             AS actual_start_date,
        COALESCE(p.expected_completion, p.due_date)  AS expected_end_date,
        p.revised_completion                         AS revised_completion_date,
        p.budget_hours,
        p.jira_board_link,
        p.sow_link
    FROM ps_project_status p
    WHERE NOT COALESCE(p.is_excluded, FALSE)
      AND NOT (p.status_category = 'Done'
               AND COALESCE(p.actual_completion, p.revised_completion, p.expected_completion)
                   < DATE_TRUNC('year', CURRENT_DATE))
),
-- Unpivot single-person roles
single_roles AS (
    SELECT issue_key, client_name, project_name, category, project_type,
           status, status_category, health, actual_start_date, expected_end_date,
           revised_completion_date, budget_hours, jira_board_link, sow_link,
           r.role, r.resource_name
    FROM base
    CROSS JOIN LATERAL (
        VALUES
            ('Project Manager',    project_manager),
            ('Solution Architect', solution_architect),
            ('Account Executive',  account_executive),
            ('CSM',                csm)
    ) AS r(role, resource_name)
    WHERE r.resource_name IS NOT NULL AND TRIM(r.resource_name) != ''
),
-- Split engineer field on comma so each engineer gets its own row
engineer_rows AS (
    SELECT issue_key, client_name, project_name, category, project_type,
           status, status_category, health, actual_start_date, expected_end_date,
           revised_completion_date, budget_hours, jira_board_link, sow_link,
           'Engineer'                AS role,
           TRIM(eng.name)            AS resource_name
    FROM base
    CROSS JOIN LATERAL regexp_split_to_table(
        COALESCE(engineer, ''), ','
    ) AS eng(name)
    WHERE TRIM(COALESCE(eng.name, '')) != ''
)
SELECT * FROM single_roles
UNION ALL
SELECT * FROM engineer_rows
ORDER BY client_name, project_name, role, resource_name;

-- ============================================================
-- vw_customer_status_assignments
-- One row per (project, role, resource) for the active Jira
-- project queue.  Unpivots PM / SA / Engineer / AE / CSM into
-- separate rows so users can filter by person or role.
-- Used by the "Customer Status Assignments" dashboard tab.
-- Refreshed daily via Lambda SPICE refresh.
-- ============================================================
DROP VIEW IF EXISTS vw_customer_status_assignments;
CREATE VIEW vw_customer_status_assignments AS
SELECT
    p.issue_key,
    p.client_name,
    p.project_name,
    p.category,
    p.project_type,
    p.status,
    p.status_category,
    p.priority,
    -- Dates
    COALESCE(p.actual_kickoff, p.planned_kickoff)   AS actual_start_date,
    COALESCE(p.expected_completion, p.due_date)     AS expected_end_date,
    p.revised_completion                            AS revised_completion_date,
    -- Resource assignment
    r.role                                          AS assignment_role,
    r.resource_name
FROM ps_project_status p
CROSS JOIN LATERAL (
    VALUES
        ('Project Manager',    p.project_manager),
        ('Solution Architect', p.solution_architect),
        ('Engineer',           p.engineer),
        ('Account Executive',  p.account_executive),
        ('CSM',                p.csm)
) AS r(role, resource_name)
WHERE r.resource_name IS NOT NULL
  AND TRIM(r.resource_name) != ''
  AND NOT COALESCE(p.is_excluded, FALSE)
  AND NOT (p.status_category = 'Done'
           AND COALESCE(p.actual_completion, p.revised_completion, p.expected_completion) < DATE_TRUNC('year', CURRENT_DATE))
ORDER BY p.client_name, p.project_name, r.role;

-- ============================================================
-- vw_project_detail
-- Thin alias view over vw_ps_project_status that renames
-- columns to match the QuickSight dataset "project-detail-view"
-- used by Sheet 5 (Project Detail) of the COO dashboards.
--
-- Column mapping:
--   sow_hours          ← budget_hours   (Jira SOW / contracted hours)
--   actual_hours_ytd   ← actual_hours   (Clockify YTD actuals)
--   effective_end_date ← COALESCE(revised_completion, expected_completion, end_date)
--   budget_burn_pct    ← budget_percent_used
--   days_to_planned_end← days_to_completion
--   schedule_variance_days ← actual_kickoff - planned_kickoff (positive = late start)
-- ============================================================
DROP VIEW IF EXISTS vw_project_detail;
CREATE VIEW vw_project_detail AS
SELECT
    type,
    client_name,
    project_name,
    project_manager,
    technical_lead,
    stage,
    health                                                      AS current_health,
    health_budget,
    health_schedule,
    planned_kickoff,
    actual_kickoff,
    COALESCE(revised_completion, expected_completion, end_date) AS effective_end_date,
    COALESCE(budget_hours, 0)                                   AS sow_hours,
    COALESCE(actual_hours, 0)                                   AS actual_hours_ytd,
    COALESCE(last_week_hours, 0)                                AS last_week_hours,
    CASE
        WHEN COALESCE(budget_hours, 0) > 0
        THEN ROUND((COALESCE(actual_hours, 0) / budget_hours * 100)::NUMERIC, 1)
        ELSE 0
    END                                                         AS budget_burn_pct,
    days_to_completion                                          AS days_to_planned_end,
    CASE
        WHEN actual_kickoff IS NOT NULL AND planned_kickoff IS NOT NULL
        THEN (actual_kickoff - planned_kickoff)
        ELSE NULL
    END                                                         AS schedule_variance_days
FROM vw_ps_project_status;


-- ============================================================
-- vw_mc_ticket_activity
-- MC customer ticket activity with WoW comparison.
-- Powers the MC service delivery sheet.
-- ============================================================
DROP VIEW IF EXISTS vw_mc_ticket_activity CASCADE;
CREATE VIEW vw_mc_ticket_activity AS
SELECT
    s.week_start,
    s.customer_name,
    s.jira_project_key,
    s.total_issues,
    s.open_issues,
    s.in_progress_issues,
    s.done_issues,
    s.updated_this_week,
    s.health_overall,
    -- WoW delta: tickets updated vs prior week
    s.updated_this_week - COALESCE(prev.updated_this_week, 0) AS updated_wow_delta,
    -- Clockify hours for this customer this week (MC project types only)
    COALESCE(h.total_hours, 0)    AS clockify_hours,
    COALESCE(h.billable_hours, 0) AS billable_hours,
    -- Open escalations
    COALESCE(e.open_escalations, 0) AS open_escalations
FROM mc_ticket_activity_snapshot s
LEFT JOIN mc_ticket_activity_snapshot prev
       ON prev.customer_name = s.customer_name
      AND prev.week_start = s.week_start - INTERVAL '7 days'
LEFT JOIN (
    SELECT
        DATE_TRUNC('week', te.entry_date)::DATE AS week_start,
        te.client_name,
        ROUND(SUM(te.duration_hours)::NUMERIC, 2)                                          AS total_hours,
        ROUND(SUM(CASE WHEN cp.billable THEN te.duration_hours ELSE 0 END)::NUMERIC, 2)    AS billable_hours
    FROM clockify_detailed_time_entries te
    LEFT JOIN clockify_projects cp ON te.clockify_project_id = cp.clockify_project_id
    WHERE cp.project_type IN ('Managed Cloud','Managed Cloud and Managed IT','Managed IT','FinOps')
    GROUP BY 1, 2
) h ON h.week_start = s.week_start AND LOWER(h.client_name) = LOWER(s.customer_name)
LEFT JOIN (
    SELECT LOWER(customer_name) AS customer_lower, COUNT(*) AS open_escalations
    FROM escalations
    WHERE resolution_date IS NULL
      AND COALESCE(status_category,'') NOT IN ('Done','Resolved')
    GROUP BY 1
) e ON e.customer_lower = LOWER(s.customer_name)
ORDER BY s.week_start DESC, s.customer_name;

-- =========================================================
-- Projects At Risk views (latest week, health = Red or Yellow)
-- =========================================================
CREATE OR REPLACE VIEW vw_ps_projects_at_risk AS
SELECT
    client_name,
    project_name,
    project_manager,
    type,
    stage,
    status_category,
    health,
    health_budget,
    health_schedule,
    escalation,
    budget_hours,
    actual_hours,
    budget_percent_used,
    last_week_hours
FROM (
    SELECT DISTINCT ON (client_name, project_name)
        client_name,
        project_name,
        project_manager,
        type,
        stage,
        status_category,
        health,
        health_budget,
        health_schedule,
        escalation,
        budget_hours,
        actual_hours,
        budget_percent_used,
        last_week_hours,
        week_start
    FROM vw_ps_project_status
    WHERE category = 'PS'
      AND status_category != 'Done'
    ORDER BY client_name, project_name, week_start DESC
) latest
WHERE (
    health IN ('Red', 'Yellow')
    OR health_budget IN ('Red', 'Yellow')
    OR health_schedule IN ('Red', 'Yellow')
    OR budget_percent_used > 100
    OR (escalation IS NOT NULL AND UPPER(TRIM(escalation)) NOT IN ('NONE', 'GREEN', ''))
);

-- =========================================================
CREATE OR REPLACE VIEW vw_mc_projects_at_risk AS
SELECT
    week_start,
    customer_name,
    jira_project_key,
    total_issues,
    open_issues,
    in_progress_issues,
    done_issues,
    updated_this_week,
    health_overall,
    updated_wow_delta,
    clockify_hours,
    billable_hours,
    open_escalations
FROM vw_mc_ticket_activity
WHERE week_start = (SELECT MAX(week_start) FROM vw_mc_ticket_activity)
  AND health_overall IN ('Red', 'Yellow');


-- ============================================================
-- vw_project_hours_summary
-- Weekly hours per project with 4w/12w averages, trend,
-- delivery health enrichment, and escalation flag.
-- ============================================================
DROP VIEW IF EXISTS vw_project_hours_summary CASCADE;
CREATE VIEW vw_project_hours_summary AS
WITH

-- ----------------------------------------------------------------
-- Client/project name mapping: clockify → canonical (same logic
-- as vw_project_hours_by_assignment tier1/tier2)
-- ----------------------------------------------------------------
tier1 AS (
    SELECT DISTINCT ON (m.clockify_client_name, COALESCE(m.clockify_project_name, ''))
        m.ps_client_name        AS canonical_client,
        m.clockify_client_name  AS cw_client,
        m.clockify_project_name AS cw_project,
        m.category              AS category
    FROM ps_project_mapping m
    WHERE m.is_active = TRUE
    ORDER BY m.clockify_client_name,
             COALESCE(m.clockify_project_name, ''),
             (m.ps_project_name IS NULL),
             m.id
),
tier2 AS (
    SELECT
        pss.client_name  AS canonical_client,
        pss.client_name  AS cw_client,
        NULL::TEXT       AS cw_project,
        pss.category     AS category
    FROM ps_project_status pss
    WHERE NOT EXISTS (
        SELECT 1 FROM ps_project_mapping m2
        WHERE LOWER(m2.ps_client_name) = LOWER(pss.client_name)
          AND m2.category = pss.category
          AND m2.is_active = TRUE
    )
),
mapping AS (
    SELECT canonical_client, cw_client, cw_project, category FROM tier1
    UNION ALL
    SELECT canonical_client, cw_client, cw_project, category FROM tier2
),

-- ----------------------------------------------------------------
-- Weekly hours per (client, project, week)
-- Only look back 30 weeks — enough for 12-week averages
-- ----------------------------------------------------------------
weekly_hours AS (
    SELECT
        DATE_TRUNC('week', te.entry_date)::DATE       AS week_start_date,
        te.client_name                                AS clockify_client_name,
        te.project_name,
        COALESCE(mp.canonical_client, te.client_name) AS client_name,
        COALESCE(mp.category, 'Other')                AS category,
        NULLIF(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
            COALESCE(cp.pod_assignment, ''),
            '{',''),'}',''),'"',''),'\','')), '')      AS pod_assignment,
        ROUND(SUM(te.duration_hours)::NUMERIC, 2)     AS total_hours,
        ROUND(SUM(CASE WHEN te.billable THEN te.duration_hours ELSE 0 END)::NUMERIC, 2)
                                                      AS billable_hours,
        COUNT(DISTINCT te.clockify_user_id)           AS resource_count,
        COUNT(*)                                      AS entry_count
    FROM clockify_detailed_time_entries te
    LEFT JOIN clockify_projects cp
           ON te.clockify_project_id = cp.clockify_project_id
    LEFT JOIN mapping mp
           ON LOWER(te.client_name) = LOWER(mp.cw_client)
          AND (mp.cw_project IS NULL
               OR LOWER(te.project_name) = LOWER(mp.cw_project))
    WHERE te.duration_hours > 0
      AND te.entry_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE - INTERVAL '30 weeks'
    GROUP BY
        DATE_TRUNC('week', te.entry_date)::DATE,
        te.client_name,
        te.project_name,
        COALESCE(mp.canonical_client, te.client_name),
        COALESCE(mp.category, 'Other'),
        NULLIF(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
            COALESCE(cp.pod_assignment, ''),
            '{',''),'}',''),'"',''),'\','')), '')
),

-- ----------------------------------------------------------------
-- 4-week rolling average (weeks 2–5 before last complete week)
-- ----------------------------------------------------------------
avg_4w AS (
    SELECT
        client_name,
        project_name,
        AVG(total_hours) AS avg_hours_4w
    FROM weekly_hours
    WHERE week_start_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE - INTERVAL '5 weeks'
      AND week_start_date <  DATE_TRUNC('week', CURRENT_DATE)::DATE - INTERVAL '1 week'
    GROUP BY client_name, project_name
),

-- ----------------------------------------------------------------
-- 12-week rolling average (weeks 2–13 before last complete week)
-- ----------------------------------------------------------------
avg_12w AS (
    SELECT
        client_name,
        project_name,
        AVG(total_hours) AS avg_hours_12w
    FROM weekly_hours
    WHERE week_start_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE - INTERVAL '13 weeks'
      AND week_start_date <  DATE_TRUNC('week', CURRENT_DATE)::DATE - INTERVAL '1 week'
    GROUP BY client_name, project_name
),

-- ----------------------------------------------------------------
-- Prior week hours for trend direction (week 2 = 2 weeks ago)
-- ----------------------------------------------------------------
prior_week AS (
    SELECT client_name, project_name, total_hours AS prior_hours
    FROM weekly_hours
    WHERE week_start_date = DATE_TRUNC('week', CURRENT_DATE)::DATE - INTERVAL '2 weeks'
),

-- ----------------------------------------------------------------
-- ps_project_status enrichment — health, dates, PM/SA
-- Join via mapping table first (clockify name → canonical Jira name),
-- then fall back to direct name match.  This fixes the 1% health
-- population rate caused by Clockify/Jira client name mismatches.
-- ----------------------------------------------------------------
ps_via_mapping AS (
    -- Tier 1: explicit ps_project_mapping entry
    SELECT DISTINCT ON (m.clockify_client_name, COALESCE(m.clockify_project_name,''))
        m.clockify_client_name  AS cw_client,
        m.clockify_project_name AS cw_project,
        p.client_name,
        p.project_name,
        p.category,
        p.status                AS jira_status,
        COALESCE(p.current_health, p.health_overall) AS current_health,
        p.health_overall,
        p.health_budget,
        p.health_scope,
        p.health_schedule,
        p.budget_hours,
        p.project_manager,
        p.solution_architect,
        p.planned_start,
        p.planned_end,
        p.actual_kickoff,
        p.actual_completion,
        m.nb_subcategory
    FROM ps_project_mapping m
    JOIN ps_project_status p
      ON LOWER(p.client_name)  = LOWER(m.ps_client_name)
     AND (m.ps_project_name IS NULL
          OR LOWER(p.project_name) = LOWER(m.ps_project_name))
    WHERE m.is_active = TRUE
      AND NOT COALESCE(p.is_excluded, FALSE)
    ORDER BY m.clockify_client_name,
             COALESCE(m.clockify_project_name,''),
             (m.ps_project_name IS NULL),
             m.id
),
ps_direct AS (
    -- Tier 2: direct name match (no mapping entry)
    SELECT DISTINCT ON (client_name, project_name)
        client_name             AS cw_client,
        project_name            AS cw_project,
        client_name,
        project_name,
        category,
        status                  AS jira_status,
        COALESCE(current_health, health_overall) AS current_health,
        health_overall,
        health_budget,
        health_scope,
        health_schedule,
        budget_hours,
        project_manager,
        solution_architect,
        planned_start,
        planned_end,
        actual_kickoff,
        actual_completion,
        NULL::VARCHAR(50)       AS nb_subcategory
    FROM ps_project_status
    WHERE NOT COALESCE(is_excluded, FALSE)
    ORDER BY client_name, project_name, synced_at DESC NULLS LAST
),

-- ----------------------------------------------------------------
-- Clients with open (non-resolved) escalations
-- ----------------------------------------------------------------
escalated_clients AS (
    SELECT DISTINCT LOWER(customer_name) AS customer_name_lower
    FROM escalations
    WHERE resolution_date IS NULL
      AND COALESCE(status_category, '') NOT IN ('Done', 'Resolved')
)

SELECT
    wh.week_start_date,
    wh.client_name,
    wh.clockify_client_name,
    wh.project_name,
    COALESCE(ps.category, wh.category)             AS category,
    CASE COALESCE(ps.category, wh.category)
        WHEN 'PS'     THEN 'Professional Services'
        WHEN 'MC'     THEN 'Managed Cloud'
        WHEN 'FinOps' THEN 'FinOps'
        ELSE COALESCE(ps.category, wh.category, 'Other')
    END                                             AS practice_alignment,
    wh.pod_assignment,
    wh.total_hours,
    wh.billable_hours,
    CASE WHEN wh.total_hours > 0
         THEN ROUND((wh.billable_hours / wh.total_hours * 100)::NUMERIC, 1)
         ELSE 0::NUMERIC
    END                                             AS billable_pct,
    wh.resource_count,
    wh.entry_count,
    ROUND(COALESCE(a4.avg_hours_4w,   0)::NUMERIC, 2) AS avg_hours_4w,
    ROUND(COALESCE(a12.avg_hours_12w, 0)::NUMERIC, 2) AS avg_hours_12w,
    CASE WHEN COALESCE(a4.avg_hours_4w, 0) > 0
         THEN ROUND(((wh.total_hours - a4.avg_hours_4w)
                     / a4.avg_hours_4w * 100)::NUMERIC, 1)
         ELSE 0::NUMERIC
    END                                             AS pct_change_vs_4w,
    CASE
        WHEN wh.total_hours > COALESCE(pw.prior_hours, 0) THEN 'Up'
        WHEN wh.total_hours < COALESCE(pw.prior_hours, 0) THEN 'Down'
        ELSE 'Stable'
    END                                             AS trend,
    CASE
        WHEN COALESCE(a4.avg_hours_4w, 0) = 0             THEN 'New'
        WHEN wh.total_hours > a4.avg_hours_4w * 1.10      THEN 'Above Average'
        WHEN wh.total_hours < a4.avg_hours_4w * 0.90      THEN 'Below Average'
        ELSE 'Average'
    END                                             AS performance_band,
    COALESCE(ps.jira_status, 'No Jira Project')     AS jira_status,
    ps.current_health,
    ps.health_overall,
    ps.health_budget,
    ps.health_scope,
    ps.health_schedule,
    ps.budget_hours,
    ps.project_manager,
    ps.solution_architect,
    ps.planned_start,
    ps.planned_end,
    ps.actual_kickoff,
    ps.actual_completion,
    CASE WHEN ec.customer_name_lower IS NOT NULL THEN 'Yes'
         ELSE 'No'
    END                                             AS escalation,
    ps.nb_subcategory
FROM weekly_hours wh
LEFT JOIN avg_4w  a4  ON wh.client_name = a4.client_name
                      AND wh.project_name = a4.project_name
LEFT JOIN avg_12w a12 ON wh.client_name = a12.client_name
                      AND wh.project_name = a12.project_name
LEFT JOIN prior_week pw ON wh.client_name = pw.client_name
                        AND wh.project_name = pw.project_name
-- Join via mapping first, fall back to direct name match
LEFT JOIN ps_via_mapping ps
       ON LOWER(wh.clockify_client_name) = LOWER(ps.cw_client)
      AND (ps.cw_project IS NULL
           OR LOWER(wh.project_name) = LOWER(ps.cw_project))
-- Only use direct match when no mapping match found
LEFT JOIN ps_direct psd
       ON ps.cw_client IS NULL
      AND LOWER(wh.client_name) = LOWER(psd.cw_client)
      AND LOWER(wh.project_name) = LOWER(psd.cw_project)
LEFT JOIN escalated_clients ec
       ON LOWER(wh.client_name) = ec.customer_name_lower
ORDER BY wh.week_start_date DESC, wh.client_name, wh.project_name;

-- View: vw_project_hours_current_week
-- Current week slice of vw_project_hours_summary (prior completed week).
-- Required by QuickSight SPICE dataset: project-hours-current-week-prod
DROP VIEW IF EXISTS vw_project_hours_current_week;
CREATE VIEW vw_project_hours_current_week AS
SELECT
    week_start_date,
    client_name,
    project_name,
    category,
    practice_alignment,
    total_hours,
    billable_hours,
    billable_pct,
    resource_count,
    avg_hours_4w,
    avg_hours_12w,
    pct_change_vs_4w,
    trend,
    performance_band,
    current_health,
    budget_hours,
    project_manager,
    solution_architect,
    escalation
FROM vw_project_hours_summary
WHERE week_start_date = DATE_TRUNC('week', CURRENT_DATE)::DATE - INTERVAL '1 week';

-- vw_practice_kpi_weekly — Practice-level KPI rollup for KPI Tracking Dashboard
DROP VIEW IF EXISTS vw_practice_kpi_weekly;
CREATE OR REPLACE VIEW vw_practice_kpi_weekly AS
WITH
-- Mapped clients from ps_project_mapping (same CTE as vw_productive_utilization)
mapped_clients AS (
    SELECT DISTINCT LOWER(clockify_client_name) AS client_lower
    FROM ps_project_mapping
    WHERE is_active = TRUE
),
-- Active users with their LoB and practice alignment (stripped of braces)
active_users AS (
    SELECT
        u.clockify_user_id,
        u.name,
        u.daily_capacity,
        u.daily_capacity * 5 AS weekly_capacity,
        COALESCE(NULLIF(cleaned.practice_alignment, ''), 'Not Assigned') AS practice_alignment,
        COALESCE(m.line_of_business, 'Internal') AS line_of_business,
        u.created_at::DATE AS user_created_date
    FROM clockify_users u
    CROSS JOIN LATERAL (
        SELECT TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
            COALESCE(u.practice_alignment, ''),
            '{',''),'}',''),'"',''),chr(39),'')) AS practice_alignment
    ) cleaned
    LEFT JOIN lob_practice_mapping m
        ON m.practice_alignment = COALESCE(NULLIF(cleaned.practice_alignment, ''), 'Not Assigned')
    WHERE u.status = 'active'
      AND u.daily_capacity > 0
      AND NOT COALESCE(u.reporting_excluded, FALSE)
      AND (u.time_submission IS NULL OR UPPER(TRIM(u.time_submission)) != 'NO')
      AND (u.pod_assignment IS NULL OR u.pod_assignment NOT ILIKE '%exempt%')
),
-- Weekly hours per user with CORRECT NB classification (matching vw_productive_utilization)
weekly_hours AS (
    SELECT
        te.clockify_user_id,
        DATE_TRUNC('week', te.entry_date)::DATE        AS week_start,
        SUM(te.duration_hours)                         AS hours_logged,
        SUM(CASE WHEN te.billable THEN te.duration_hours
                 ELSE 0 END)                           AS billable_hours,
        -- NB Productive: custom-field-only (project "Non Bill Productive" checkbox)
        SUM(CASE WHEN te.is_nb_productive = TRUE THEN te.duration_hours ELSE 0 END) AS productive_nb_hours,
        -- NB Non-Productive: custom-field-only (project "Non Bill Non Productive" checkbox)
        SUM(CASE WHEN te.is_nb_non_productive = TRUE THEN te.duration_hours ELSE 0 END) AS nb_non_productive_hours
    FROM clockify_detailed_time_entries te
    LEFT JOIN clockify_projects cp
        ON te.clockify_project_id = cp.clockify_project_id
    LEFT JOIN mapped_clients mc
        ON LOWER(te.client_name) = mc.client_lower
    WHERE te.entry_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE - INTERVAL '52 weeks'
    GROUP BY te.clockify_user_id, DATE_TRUNC('week', te.entry_date)::DATE
)
SELECT
    u.line_of_business,
    u.practice_alignment,
    w.week_start,
    EXTRACT(YEAR FROM w.week_start)::INTEGER AS year_num,
    EXTRACT(QUARTER FROM w.week_start)::INTEGER AS quarter_num,
    CONCAT('Q', EXTRACT(QUARTER FROM w.week_start)::INTEGER, ' ', EXTRACT(YEAR FROM w.week_start)::INTEGER) AS quarter_label,
    COUNT(DISTINCT u.clockify_user_id) AS headcount,
    SUM(u.weekly_capacity) AS total_capacity_hours,
    COALESCE(SUM(h.hours_logged), 0) AS total_hours_logged,
    COALESCE(SUM(h.billable_hours), 0) AS total_billable_hours,
    ROUND(
        (COALESCE(SUM(h.billable_hours), 0) / NULLIF(SUM(u.weekly_capacity), 0) * 100)::NUMERIC, 1
    ) AS billable_util_pct,
    ROUND((
        (COALESCE(SUM(h.billable_hours), 0) + COALESCE(SUM(h.productive_nb_hours), 0))
        / NULLIF(SUM(u.weekly_capacity), 0) * 100
    )::NUMERIC, 1) AS productive_util_pct,
    COALESCE(SUM(h.productive_nb_hours), 0) AS total_productive_nb_hours,
    COALESCE(SUM(h.nb_non_productive_hours), 0) AS total_nb_non_productive_hours,
    ROUND(
        (COALESCE(SUM(h.hours_logged), 0) / NULLIF(SUM(u.weekly_capacity), 0) * 100)::NUMERIC, 1
    ) AS total_util_pct,
    COUNT(DISTINCT CASE WHEN h.hours_logged > 0 THEN u.clockify_user_id END) AS compliant_count,
    ROUND(
        (COUNT(DISTINCT CASE WHEN h.hours_logged > 0 THEN u.clockify_user_id END)::NUMERIC /
         NULLIF(COUNT(DISTINCT u.clockify_user_id), 0) * 100), 1
    ) AS compliance_pct
FROM active_users u
CROSS JOIN (
    SELECT DISTINCT DATE_TRUNC('week', entry_date)::DATE AS week_start
    FROM clockify_detailed_time_entries
    WHERE entry_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE - INTERVAL '52 weeks'
      AND DATE_TRUNC('week', entry_date)::DATE < DATE_TRUNC('week', CURRENT_DATE)::DATE
) w
LEFT JOIN weekly_hours h
    ON u.clockify_user_id = h.clockify_user_id
    AND h.week_start = w.week_start
WHERE u.user_created_date <= w.week_start + 6
GROUP BY
    u.line_of_business,
    u.practice_alignment,
    w.week_start
ORDER BY
    w.week_start DESC,
    u.line_of_business,
    u.practice_alignment;

-- ============================================================
-- vw_kpi_staff_weekly — Per-staff weekly KPI view
-- Used by KPI Tracking Dashboard all 3 sheets.
-- Provides individual-level billable/NB hours, utilization, compliance.
-- NB classification uses mapped_clients fallback (consistent with vw_productive_utilization).
-- ============================================================
DROP VIEW IF EXISTS vw_kpi_staff_weekly;
CREATE OR REPLACE VIEW vw_kpi_staff_weekly AS
WITH
mapped_clients AS (
    SELECT DISTINCT LOWER(clockify_client_name) AS client_lower
    FROM ps_project_mapping
    WHERE is_active = TRUE
),
active_users AS (
    SELECT
        u.clockify_user_id,
        u.name AS user_name,
        u.daily_capacity,
        u.daily_capacity * 5 AS weekly_capacity,
        COALESCE(NULLIF(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.pod_assignment,     '{',''),'}',''),'"',''),chr(39),'')), ''), 'Not Assigned') AS pod_assignment,
        COALESCE(NULLIF(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(u.practice_alignment, '{',''),'}',''),'"',''),chr(39),'')), ''), 'Not Assigned') AS practice_alignment,
        u.cloudelligent_title,
        u.location,
        u.employment_designation,
        COALESCE(m.line_of_business, 'Internal') AS line_of_business,
        u.created_at::DATE AS user_created_date
    FROM clockify_users u
    CROSS JOIN LATERAL (
        SELECT TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
            COALESCE(u.practice_alignment, ''),
            '{',''),'}',''),'"',''),chr(39),'')) AS pa_cleaned
    ) cleaned
    LEFT JOIN lob_practice_mapping m
        ON m.practice_alignment = cleaned.pa_cleaned
    WHERE u.status = 'active'
      AND u.daily_capacity > 0
      AND NOT COALESCE(u.reporting_excluded, FALSE)
      AND (u.time_submission IS NULL OR UPPER(TRIM(u.time_submission)) != 'NO')
      AND (u.pod_assignment IS NULL OR u.pod_assignment NOT ILIKE '%exempt%')
),
week_spine AS (
    SELECT DISTINCT DATE_TRUNC('week', entry_date)::DATE AS week_start
    FROM clockify_detailed_time_entries
    WHERE entry_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE - INTERVAL '52 weeks'
      AND DATE_TRUNC('week', entry_date)::DATE < DATE_TRUNC('week', CURRENT_DATE)::DATE
),
user_weekly_hours AS (
    SELECT
        te.clockify_user_id,
        DATE_TRUNC('week', te.entry_date)::DATE AS week_start,
        SUM(te.duration_hours) AS hours_logged,
        SUM(CASE WHEN te.billable THEN te.duration_hours ELSE 0 END) AS billable_hours,
        SUM(CASE WHEN te.is_nb_productive = TRUE THEN te.duration_hours ELSE 0 END) AS nb_productive_hours,
        SUM(CASE WHEN te.is_nb_non_productive = TRUE THEN te.duration_hours ELSE 0 END) AS nb_non_productive_hours
    FROM clockify_detailed_time_entries te
    LEFT JOIN clockify_projects cp
        ON te.clockify_project_id = cp.clockify_project_id
    LEFT JOIN mapped_clients mc
        ON LOWER(te.client_name) = mc.client_lower
    WHERE te.entry_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE - INTERVAL '52 weeks'
    GROUP BY te.clockify_user_id, DATE_TRUNC('week', te.entry_date)::DATE
)
SELECT
    u.user_name,
    u.pod_assignment,
    u.practice_alignment,
    u.line_of_business,
    u.cloudelligent_title,
    u.location,
    u.employment_designation,
    w.week_start,
    EXTRACT(YEAR FROM w.week_start)::INTEGER AS year_num,
    EXTRACT(QUARTER FROM w.week_start)::INTEGER AS quarter_num,
    CONCAT('Q', EXTRACT(QUARTER FROM w.week_start)::INTEGER, ' ', EXTRACT(YEAR FROM w.week_start)::INTEGER) AS quarter_label,
    u.weekly_capacity AS available_hours,
    COALESCE(h.hours_logged, 0) AS hours_logged,
    COALESCE(h.billable_hours, 0) AS billable_hours,
    COALESCE(h.nb_productive_hours, 0) AS nb_productive_hours,
    COALESCE(h.nb_non_productive_hours, 0) AS nb_non_productive_hours,
    GREATEST(u.weekly_capacity - COALESCE(h.hours_logged, 0), 0) AS non_logged_hours,
    ROUND((COALESCE(h.billable_hours, 0) / NULLIF(u.weekly_capacity, 0) * 100)::NUMERIC, 1) AS billable_util_pct,
    ROUND(((COALESCE(h.billable_hours, 0) + COALESCE(h.nb_productive_hours, 0)) / NULLIF(u.weekly_capacity, 0) * 100)::NUMERIC, 1) AS productive_util_pct,
    CASE WHEN COALESCE(h.hours_logged, 0) > 0 THEN 'Compliant' ELSE 'Non-Compliant' END AS compliance_status,
    CASE WHEN COALESCE(h.hours_logged, 0) > 0 THEN 1 ELSE 0 END AS is_compliant,
    -- On-time delivery columns (NULL placeholders — on-time data is org-level, not per-staff)
    NULL::NUMERIC AS ontime_pct_in_week,
    NULL::INTEGER AS projects_on_time_in_week,
    NULL::TEXT AS ontime_data_quality,
    NULL::INTEGER AS projects_closed_in_week
FROM active_users u
CROSS JOIN week_spine w
LEFT JOIN user_weekly_hours h
    ON u.clockify_user_id = h.clockify_user_id
    AND h.week_start = w.week_start
WHERE u.user_created_date <= w.week_start + 6
ORDER BY w.week_start DESC, u.user_name;

-- ============================================================
-- vw_project_closure_status
-- Project-level on-time delivery status for PS projects.
-- Uses the same logic as kpi_snapshot.py _compute_project_metrics:
--   LATE if revised_completion > expected_completion (slipped)
--   ON TIME if actual_completion <= deadline (confirmed done on time)
--   ON TIME if still in progress and deadline not yet passed
--   NULL if no dates set (excluded from on-time denominator)
-- Works for active AND closed projects. Does not require actual_completion.
-- data_quality: 'Confirmed' when actual_completion set,
--              'Schedule' for in-progress with target date,
--              'No Dates' when no target date available
-- ============================================================
DROP VIEW IF EXISTS vw_project_closure_status;
CREATE VIEW vw_project_closure_status AS
SELECT
    p.client_name,
    p.project_name,
    p.project_manager,
    p.solution_architect,
    p.status_category,
    p.category,
    p.expected_completion,
    p.revised_completion,
    p.actual_completion,
    p.resolution_date,
    p.updated_date::DATE                                        AS last_updated_date,
    -- Target date: revised if set (slipped), else expected
    COALESCE(p.revised_completion, p.expected_completion)       AS target_completion,
    -- on_time flag using same logic as kpi_snapshot.py
    CASE
        -- No dates at all: exclude from denominator
        WHEN COALESCE(p.revised_completion, p.expected_completion) IS NULL
             AND p.actual_completion IS NULL
        THEN NULL
        -- Slipped: revised pushed past original expected
        WHEN p.revised_completion IS NOT NULL
             AND p.expected_completion IS NOT NULL
             AND p.revised_completion > p.expected_completion
        THEN 0
        -- Completed on or before deadline
        WHEN p.actual_completion IS NOT NULL
             AND p.actual_completion <= COALESCE(p.expected_completion, p.revised_completion)
        THEN 1
        -- In progress, deadline not yet passed
        WHEN p.actual_completion IS NULL
             AND COALESCE(p.expected_completion, p.revised_completion) >= CURRENT_DATE
        THEN 1
        -- Overdue or completed late
        ELSE 0
    END                                                         AS is_on_time,
    -- Data quality
    CASE
        WHEN p.actual_completion IS NOT NULL                    THEN 'Confirmed'
        WHEN COALESCE(p.revised_completion,
                      p.expected_completion) IS NOT NULL        THEN 'Schedule'
        ELSE 'No Dates'
    END                                                         AS data_quality,
    -- Clockify mapping keys for joining to time entries
    m.clockify_client_name,
    m.clockify_project_name
FROM ps_project_status p
LEFT JOIN LATERAL (
    SELECT
        clockify_client_name,
        clockify_project_name
    FROM ps_project_mapping
    WHERE is_active = TRUE
      AND LOWER(ps_client_name) = LOWER(p.client_name)
    ORDER BY
        -- prefer project-level match
        (LOWER(COALESCE(ps_project_name,'')) = LOWER(p.project_name)) DESC,
        id DESC
    LIMIT 1
) m ON TRUE
WHERE p.category = 'PS'
  AND NOT COALESCE(p.is_excluded, FALSE)
  AND p.jira_project_key = 'CST'
ORDER BY p.client_name, p.project_name;

-- ============================================================
-- vw_staff_ontime_delivery
-- Individual on-time delivery rate for PS projects.
-- Staff are linked to projects via Clockify time entries.
-- A staff member is counted for a project if they logged
-- at least 1 hour against it during the project lifecycle.
-- Covers active AND closed PS projects (not Done-only).
-- In-progress projects (effective_close_date = CURRENT_DATE)
-- appear in the current week's row.
-- ============================================================
DROP VIEW IF EXISTS vw_staff_ontime_delivery;
CREATE VIEW vw_staff_ontime_delivery AS
WITH
-- All PS projects with a determinable on-time status (active + closed)
all_projects AS (
    SELECT
        client_name,
        project_name,
        project_manager,
        solution_architect,
        status_category,
        COALESCE(actual_completion, CURRENT_DATE) AS effective_close_date,
        target_completion,
        is_on_time,
        data_quality,
        clockify_client_name,
        clockify_project_name
    FROM vw_project_closure_status
    WHERE is_on_time IS NOT NULL  -- exclude projects with no dates
),
-- Staff who logged hours against each project
-- Join via ps_project_mapping: match on client name,
-- and optionally project name if mapping exists
staff_project_hours AS (
    SELECT DISTINCT
        te.clockify_user_id,
        te.user_name,
        te.client_name  AS clockify_client,
        te.project_name AS clockify_project
    FROM clockify_detailed_time_entries te
    WHERE te.duration_hours > 0
),
-- Link staff to projects, deduplicated
-- Use DISTINCT ON to prevent fan-out from client-level mappings
-- where one Clockify billing entry maps to multiple Jira projects
staff_to_project AS (
    SELECT DISTINCT ON (sph.clockify_user_id, ap.client_name, ap.project_name)
        sph.clockify_user_id,
        sph.user_name,
        ap.client_name,
        ap.project_name,
        ap.effective_close_date,
        ap.target_completion,
        ap.is_on_time,
        ap.data_quality,
        ap.project_manager,
        ap.solution_architect,
        ap.status_category
    FROM all_projects ap
    JOIN staff_project_hours sph
        ON  LOWER(sph.clockify_client) = LOWER(COALESCE(ap.clockify_client_name, ap.client_name))
        AND (
            ap.clockify_project_name IS NULL
            OR LOWER(sph.clockify_project) = LOWER(ap.clockify_project_name)
        )
    ORDER BY
        sph.clockify_user_id,
        ap.client_name,
        ap.project_name,
        -- Prefer project-level matches over client-level matches
        (ap.clockify_project_name IS NOT NULL) DESC
)
-- Final output: one row per staff member per project
SELECT
    stp.clockify_user_id,
    stp.user_name,
    -- Enrich with LoB and practice from clockify_users via mapping table
    COALESCE(lob_m.line_of_business, 'Internal')          AS line_of_business,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
        COALESCE(u.practice_alignment, ''),
        '{',''),'}',''),'"',''),chr(39),''))               AS practice_alignment,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
        COALESCE(u.pod_assignment, ''),
        '{',''),'}',''),'"',''),chr(39),''))               AS pod_assignment,
    u.cloudelligent_title,
    stp.client_name,
    stp.project_name,
    stp.status_category,
    stp.effective_close_date,
    stp.target_completion,
    stp.is_on_time,
    stp.data_quality,
    -- Role on the project
    CASE
        WHEN LOWER(stp.project_manager)     = LOWER(u.name) THEN 'PM'
        WHEN LOWER(stp.solution_architect)  = LOWER(u.name) THEN 'SA'
        ELSE 'Contributor'
    END                                                   AS project_role
FROM staff_to_project stp
JOIN clockify_users u
    ON stp.clockify_user_id = u.clockify_user_id
LEFT JOIN lob_practice_mapping lob_m
    ON lob_m.practice_alignment = TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
        COALESCE(u.practice_alignment, ''),
        '{',''),'}',''),'"',''),chr(39),''))
ORDER BY
    stp.user_name,
    stp.effective_close_date DESC;
-- ============================================================
-- vw_staff_kpi_weekly
-- Individual staff KPI rows for KPI dashboard drill-down.
-- Filter hierarchy: line_of_business → practice_alignment → pod_assignment → user_name
-- One row per (user × week). Includes compliance, hours, and on-time delivery per week.
-- On-time delivery columns (projects_closed_in_week, projects_on_time_in_week,
-- ontime_pct_in_week, ontime_data_quality) sourced from vw_staff_ontime_delivery.
-- ============================================================
DROP VIEW IF EXISTS vw_staff_kpi_weekly;
CREATE VIEW vw_staff_kpi_weekly AS
WITH
active_users AS (
    SELECT
        u.clockify_user_id,
        u.name AS user_name,
        u.daily_capacity,
        u.daily_capacity * 5 AS weekly_capacity,
        cleaned.practice_alignment,
        COALESCE(m.line_of_business, 'Internal') AS line_of_business,
        TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
            COALESCE(u.pod_assignment, ''),
            '{',''),'}',''),'"',''),chr(39),'')) AS pod_assignment,
        u.cloudelligent_title,
        u.location,
        u.employment_designation
    FROM clockify_users u
    CROSS JOIN LATERAL (
        SELECT TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
            COALESCE(u.practice_alignment, ''),
            '{',''),'}',''),'"',''),chr(39),'')) AS practice_alignment
    ) cleaned
    LEFT JOIN lob_practice_mapping m
        ON m.practice_alignment = cleaned.practice_alignment
    WHERE u.status = 'active'
      AND u.daily_capacity > 0
      AND NOT COALESCE(u.reporting_excluded, FALSE)
      AND (u.time_submission IS NULL OR UPPER(TRIM(u.time_submission)) != 'NO')
      AND cleaned.practice_alignment != ''
),
weeks AS (
    SELECT DISTINCT DATE_TRUNC('week', entry_date)::DATE AS week_start
    FROM clockify_detailed_time_entries
    WHERE entry_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE - INTERVAL '52 weeks'
),
weekly_hours AS (
    SELECT
        te.clockify_user_id,
        DATE_TRUNC('week', te.entry_date)::DATE          AS week_start,
        SUM(te.duration_hours)                           AS hours_logged,
        SUM(CASE WHEN te.billable THEN te.duration_hours
                 ELSE 0 END)                             AS billable_hours,
        SUM(CASE WHEN NOT te.billable THEN te.duration_hours
                 ELSE 0 END)                             AS non_billable_hours,
        SUM(CASE
                WHEN te.billable = FALSE
                 AND (
                     cp.project_type IN ('Non Bill Productive', 'Overtime', 'Presales')
                     OR COALESCE(cp.is_overtime, FALSE) = TRUE
                     OR COALESCE(cp.is_presales, FALSE) = TRUE
                 )
                THEN te.duration_hours
                ELSE 0
            END)                                         AS productive_nb_hours
    FROM clockify_detailed_time_entries te
    LEFT JOIN clockify_projects cp
        ON te.clockify_project_id = cp.clockify_project_id
    WHERE te.entry_date >= DATE_TRUNC('week', CURRENT_DATE)::DATE - INTERVAL '52 weeks'
    GROUP BY te.clockify_user_id, DATE_TRUNC('week', te.entry_date)::DATE
)
SELECT
    u.line_of_business,
    u.practice_alignment,
    NULLIF(u.pod_assignment, '')                      AS pod_assignment,
    u.user_name,
    u.cloudelligent_title,
    u.location,
    u.employment_designation,
    w.week_start,
    EXTRACT(YEAR    FROM w.week_start)::INTEGER        AS year_num,
    EXTRACT(QUARTER FROM w.week_start)::INTEGER        AS quarter_num,
    EXTRACT(MONTH   FROM w.week_start)::INTEGER        AS month_num,
    TO_CHAR(w.week_start, 'Mon YYYY')                  AS month_label,
    CONCAT('Q', EXTRACT(QUARTER FROM w.week_start)::INTEGER,
           ' ',  EXTRACT(YEAR    FROM w.week_start)::INTEGER) AS quarter_label,
    u.weekly_capacity,
    COALESCE(h.hours_logged,     0)                   AS hours_logged,
    COALESCE(h.billable_hours,   0)                   AS billable_hours,
    COALESCE(h.non_billable_hours, 0)                 AS non_billable_hours,
    ROUND((COALESCE(h.billable_hours, 0)
           / NULLIF(u.weekly_capacity, 0) * 100)::NUMERIC, 1) AS billable_util_pct,
    COALESCE(h.productive_nb_hours, 0)                        AS productive_nb_hours,
    ROUND((
        (COALESCE(h.billable_hours, 0) + COALESCE(h.productive_nb_hours, 0))
        / NULLIF(u.weekly_capacity, 0) * 100
    )::NUMERIC, 1)                                            AS productive_util_pct,
    CASE
        WHEN COALESCE(h.hours_logged, 0) >= u.weekly_capacity * 0.9 THEN 1
        ELSE 0
    END                                               AS is_compliant,
    CASE
        WHEN COALESCE(h.hours_logged, 0) >= u.weekly_capacity * 0.9 THEN 'Compliant'
        WHEN COALESCE(h.hours_logged, 0) > 0                        THEN 'Partial'
        ELSE 'Non-Compliant'
    END                                               AS compliance_status,
    -- On-time delivery columns (NULL when no PS projects closed that week)
    COALESCE(otd.projects_closed,  0)                 AS projects_closed_in_week,
    COALESCE(otd.projects_on_time, 0)                 AS projects_on_time_in_week,
    otd.ontime_pct                                    AS ontime_pct_in_week,
    otd.ontime_data_quality                           AS ontime_data_quality
FROM active_users u
CROSS JOIN weeks w
LEFT JOIN weekly_hours h
    ON  h.clockify_user_id = u.clockify_user_id
    AND h.week_start       = w.week_start
LEFT JOIN (
    SELECT
        clockify_user_id,
        DATE_TRUNC('week', effective_close_date)::DATE  AS close_week,
        COUNT(*)                                         AS projects_closed,
        SUM(is_on_time)                                  AS projects_on_time,
        ROUND(SUM(is_on_time)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS ontime_pct,
        CASE
            WHEN COUNT(*) FILTER (WHERE data_quality = 'Confirmed') = COUNT(*) THEN 'Confirmed'
            WHEN COUNT(*) FILTER (WHERE data_quality = 'Schedule')  = COUNT(*) THEN 'Schedule'
            ELSE 'Mixed'
        END AS ontime_data_quality
    FROM vw_staff_ontime_delivery
    GROUP BY clockify_user_id, DATE_TRUNC('week', effective_close_date)::DATE
) otd
    ON  otd.clockify_user_id = u.clockify_user_id
    AND otd.close_week       = w.week_start
ORDER BY
    u.line_of_business,
    u.practice_alignment,
    u.pod_assignment,
    u.user_name,
    w.week_start DESC;


-- ============================================================
-- Permissions: ensure report_user can read/write all tables
-- (apply_views runs as postgres superuser, so this GRANT executes with full privileges)
-- ============================================================
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO report_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO report_user;

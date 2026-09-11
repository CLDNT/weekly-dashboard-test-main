"""Weekly KPI snapshot writer.

Computes KPI values for the most recently completed week (or a specified
week_start_date) and upserts them into kpi_weekly_snapshots.

Called from lambda_handler.py via mode='snapshot_kpis'.
Can also be run locally:
    python -m src.integrations.kpi_snapshot --week 2026-04-14
"""

from __future__ import annotations

import argparse
import os
from datetime import date, datetime, timedelta
from typing import Optional

from sqlalchemy import create_engine, text


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def take_weekly_snapshot(engine, week_start: Optional[date] = None) -> dict:
    """Compute KPI values for one week and upsert into kpi_weekly_snapshots.

    Args:
        engine: SQLAlchemy engine connected to clockify_reporting DB.
        week_start: Monday of the target week.  Defaults to the most recently
                    completed week (last Monday).

    Returns:
        Dict summarising the row that was written.
    """
    if week_start is None:
        # Last complete Monday  (today - days_since_last_monday - 7)
        today = date.today()
        days_since_monday = today.weekday()  # Mon=0
        week_start = today - timedelta(days=days_since_monday + 7)

    week_end = week_start + timedelta(days=6)
    year_start = date(week_start.year, 1, 1)

    print(f"[kpi_snapshot] Computing KPIs for week {week_start} – {week_end}")

    with engine.connect() as conn:
        util    = _compute_utilization(conn, week_start, week_end)
        ps      = _compute_project_metrics(conn, 'PS',  week_start, week_end, year_start)
        mc      = _compute_project_metrics(conn, 'MC',  week_start, week_end, year_start)
        esc     = _compute_escalation_metrics(conn, week_start)

        row = {
            'week_start_date':      week_start,
            'week_num':             int(week_start.strftime('%V')),
            'snapshot_taken_at':    datetime.utcnow(),

            # Utilization
            'billable_util_pct':    util['billable_util_pct'],
            'productive_util_pct':  util['productive_util_pct'],
            'time_compliance_pct':  util['time_compliance_pct'],
            'presales_hours':       util['presales_hours'],
            'productive_nb_hours':  util['productive_nb_hours'],
            'total_available_hours': util['total_available_hours'],
            'total_billable_hours': util['total_billable_hours'],
            'missing_time_count':   util['missing_time_count'],
            'nb_nonproductive_hours': util['nb_nonproductive_hours'],

            # PS
            'ps_active_projects':    ps['active_projects'],
            'ps_on_time_pct':        ps['on_time_pct'],
            'ps_avg_duration_weeks': ps['avg_duration_weeks'],
            'ps_projects_green':     ps['projects_green'],
            'ps_projects_amber':     ps['projects_amber'],
            'ps_projects_red':       ps['projects_red'],
            'ps_billable_hours':     ps['billable_hours'],
            'ps_budget_hours_total': ps['budget_hours_total'],
            'ps_actual_hours_ytd':   ps['actual_hours_ytd'],

            # MC
            'mc_active_projects':    mc['active_projects'],
            'mc_on_time_pct':        mc['on_time_pct'],
            'mc_avg_duration_weeks': mc['avg_duration_weeks'],
            'mc_projects_green':     mc['projects_green'],
            'mc_projects_amber':     mc['projects_amber'],
            'mc_projects_red':       mc['projects_red'],
            'mc_billable_hours':     mc['billable_hours'],
            'mc_budget_hours_total': mc['budget_hours_total'],
            'mc_actual_hours_ytd':   mc['actual_hours_ytd'],

            # Escalations
            'open_escalations':           esc['open_escalations'],
            'escalations_high_priority':  esc['high_priority'],
            'escalations_med_priority':   esc['med_priority'],
            'avg_escalation_days_open':   esc['avg_days_open'],
            'escalations_resolved_ytd':   esc['resolved_ytd'],

            # Headcount
            'active_resource_count': util['active_resource_count'],
        }

        _upsert(conn, row)
        conn.commit()

    print(f"[kpi_snapshot] Snapshot written for {week_start}")
    return row


# ---------------------------------------------------------------------------
# Utilization helpers
# ---------------------------------------------------------------------------

def _compute_utilization(conn, week_start: date, week_end: date) -> dict:
    """Compute billable/productive utilisation and time compliance."""

    # Available hours = SUM(daily_capacity * 5) for active, non-exempt users.
    # Includes the new-user cutoff (created on/before the week end) so headcount
    # and the util denominator are point-in-time consistent with
    # vw_practice_kpi_weekly / vw_kpi_staff_weekly (reconciliation fix — without
    # it, historical weeks counted today's roster and drifted by joiners).
    avail = conn.execute(text("""
        SELECT
            COALESCE(SUM(daily_capacity * 5), 0)  AS total_available,
            COUNT(*)                               AS active_count
        FROM clockify_users
        WHERE status = 'active'
          AND daily_capacity > 0
          AND (time_submission IS NULL OR UPPER(TRIM(time_submission)) != 'NO')
          AND NOT COALESCE(reporting_excluded, FALSE)
          AND (pod_assignment IS NULL OR pod_assignment NOT ILIKE '%exempt%')
          AND created_at::DATE <= :we
    """), {'we': week_end}).fetchone()

    total_available = float(avail.total_available or 0)
    active_count    = int(avail.active_count or 0)

    # Billable and presales hours for the week
    # JOIN clockify_users to respect the canonical active-user population — must
    # match the `avail` denominator above and vw_kpi_staff_weekly:
    #   status='active', daily_capacity>0, time_submission!='NO',
    #   not reporting_excluded, pod not exempt.
    # (Previously only reporting_excluded + exempt-pod were applied here, which
    #  let billable hours from inactive / zero-capacity / opted-out users inflate
    #  the total above Staff/Practice — reconciliation fix.)
    hours = conn.execute(text("""
        SELECT
            COALESCE(SUM(CASE WHEN te.billable = TRUE THEN te.duration_hours ELSE 0 END), 0)
                AS billable_hours,
            COALESCE(SUM(CASE
                WHEN cp.project_type IN ('Presales') THEN te.duration_hours
                WHEN COALESCE(cp.is_presales, FALSE) THEN te.duration_hours
                ELSE 0 END), 0) AS presales_hours
        FROM clockify_detailed_time_entries te
        JOIN clockify_users u ON te.clockify_user_id = u.clockify_user_id
        LEFT JOIN clockify_projects cp
               ON te.clockify_project_id = cp.clockify_project_id
        WHERE te.entry_date BETWEEN :ws AND :we
          AND te.duration_hours > 0
          AND u.status = 'active'
          AND u.daily_capacity > 0
          AND (u.time_submission IS NULL OR UPPER(TRIM(u.time_submission)) != 'NO')
          AND NOT COALESCE(u.reporting_excluded, FALSE)
          AND (u.pod_assignment IS NULL OR u.pod_assignment NOT ILIKE '%exempt%')
    """), {'ws': week_start, 'we': week_end}).fetchone()

    billable_hours     = float(hours.billable_hours or 0)
    presales_hours     = float(hours.presales_hours or 0)

    # Fix 1: NB Productive — uses mapped_clients fallback (consistent with vw_productive_utilization)
    #   Uses Clockify custom field: is_nb_productive = TRUE
    nb_productive_result = conn.execute(text("""
        SELECT COALESCE(SUM(te.duration_hours), 0) AS productive_nb_hours
        FROM clockify_detailed_time_entries te
        JOIN clockify_users u ON te.clockify_user_id = u.clockify_user_id
        WHERE te.entry_date BETWEEN :ws AND :we
          AND te.duration_hours > 0
          AND te.is_nb_productive = TRUE
          AND u.status = 'active'
          AND u.daily_capacity > 0
          AND (u.time_submission IS NULL OR UPPER(TRIM(u.time_submission)) != 'NO')
          AND NOT COALESCE(u.reporting_excluded, FALSE)
          AND (u.pod_assignment IS NULL OR u.pod_assignment NOT ILIKE '%exempt%')
          AND u.created_at::DATE <= :we
    """), {'ws': week_start, 'we': week_end}).fetchone()
    nb_productive_hrs  = float(nb_productive_result.productive_nb_hours or 0)

    productive_hours   = billable_hours + nb_productive_hrs

    billable_util_pct   = round(billable_hours  / total_available * 100, 2) if total_available else None
    productive_util_pct = round(productive_hours / total_available * 100, 2) if total_available else None

    # Time compliance: % of active users who logged ANY time (hours_logged > 0),
    # org-level (compliant / total). This is the least-restrictive definition,
    # matched by vw_kpi_staff_weekly.is_compliant and
    # vw_practice_kpi_weekly.compliance_pct. Includes the new-user cutoff
    # (created on/before week end) so the population matches those views.
    compliance = conn.execute(text("""
        WITH user_hours AS (
            SELECT
                u.clockify_user_id,
                u.daily_capacity * 5                        AS weekly_expected,
                COALESCE(SUM(te.duration_hours), 0)        AS hours_logged
            FROM clockify_users u
            LEFT JOIN clockify_detailed_time_entries te
                   ON te.clockify_user_id = u.clockify_user_id
                  AND te.entry_date BETWEEN :ws AND :we
            WHERE u.status = 'active'
              AND u.daily_capacity > 0
              AND (u.time_submission IS NULL OR UPPER(TRIM(u.time_submission)) != 'NO')
              AND NOT COALESCE(u.reporting_excluded, FALSE)
              AND (u.pod_assignment IS NULL OR u.pod_assignment NOT ILIKE '%exempt%')
              AND u.created_at::DATE <= :we
            GROUP BY u.clockify_user_id, u.daily_capacity
        )
        SELECT
            COUNT(*)                                       AS total_users,
            SUM(CASE WHEN hours_logged > 0 THEN 1 ELSE 0 END) AS compliant,
            SUM(CASE WHEN hours_logged = 0                      THEN 1 ELSE 0 END) AS no_time_submitted
        FROM user_hours
    """), {'ws': week_start, 'we': week_end}).fetchone()

    total_users        = int(compliance.total_users        or 0)
    compliant          = int(compliance.compliant          or 0)
    missing_time_count = int(compliance.no_time_submitted  or 0)
    time_compliance_pct = round(compliant / total_users * 100, 2) if total_users else None

    # NB Non-Productive: custom-field-only.
    #   Comes ONLY from entries whose project is marked "Non Bill Non Productive"
    #   (Clockify project-level CHECKBOX custom field -> te.is_nb_non_productive).
    #   Capacity-gap / unlogged time is NOT counted (removed per definition).
    nb_nonproductive_result = conn.execute(text("""
        SELECT COALESCE(SUM(te.duration_hours), 0) AS nb_nonproductive_hours
        FROM clockify_detailed_time_entries te
        JOIN clockify_users u ON te.clockify_user_id = u.clockify_user_id
        WHERE te.entry_date BETWEEN :ws AND :we
          AND te.duration_hours > 0
          AND te.is_nb_non_productive = TRUE
          AND u.status = 'active'
          AND u.daily_capacity > 0
          AND (u.time_submission IS NULL OR UPPER(TRIM(u.time_submission)) != 'NO')
          AND NOT COALESCE(u.reporting_excluded, FALSE)
          AND (u.pod_assignment IS NULL OR u.pod_assignment NOT ILIKE '%exempt%')
          AND u.created_at::DATE <= :we
    """), {'ws': week_start, 'we': week_end}).fetchone()
    nb_nonproductive_hrs = float(nb_nonproductive_result.nb_nonproductive_hours or 0)

    return {
        'billable_util_pct':    billable_util_pct,
        'productive_util_pct':  productive_util_pct,
        'time_compliance_pct':  time_compliance_pct,
        'presales_hours':       round(presales_hours, 2),
        'productive_nb_hours':  round(nb_productive_hrs, 2),
        'total_available_hours': round(total_available, 2),
        'total_billable_hours': round(billable_hours, 2),
        'active_resource_count': active_count,
        'missing_time_count':   missing_time_count,
        'nb_nonproductive_hours': round(nb_nonproductive_hrs, 2),
    }


# ---------------------------------------------------------------------------
# Project delivery metrics (PS or MC)
# ---------------------------------------------------------------------------

def _compute_project_metrics(conn, category: str,
                              week_start: date, week_end: date,
                              year_start: date) -> dict:
    """Compute delivery health and billable hours for PS or MC."""

    # Health counts and duration from ps_project_status
    # For PS: filter jira_project_key = 'CST' to match vw_ps_projects_at_risk scope.
    # Red = DISTINCT projects where health (COALESCE(current_health, health_overall))
    #       OR health_budget OR health_schedule is Red/Yellow.
    # Green = DISTINCT projects with no Red/Yellow on any health dimension.
    issue_type_filter = 'Emailed request' if category == 'PS' else 'Managed Services'
    cst_filter = "AND jira_project_key = 'CST'" if category == 'PS' else ''
    health = conn.execute(text(f"""
        SELECT
            COUNT(DISTINCT jira_issue_id)                                     AS active_projects,
            -- Green: no Red/Yellow on any health dimension
            COUNT(DISTINCT CASE
                WHEN COALESCE(current_health, health_overall) NOT IN ('Red', 'Yellow')
                 AND COALESCE(health_budget, 'Green') NOT IN ('Red', 'Yellow')
                 AND COALESCE(health_schedule, 'Green') NOT IN ('Red', 'Yellow')
                THEN jira_issue_id END)                                       AS green,
            COUNT(DISTINCT CASE
                WHEN COALESCE(current_health, health_overall) = 'Amber'
                THEN jira_issue_id END)                                       AS amber,
            -- Red/at-risk: matches vw_ps_projects_at_risk (health = Red or Yellow)
            COUNT(DISTINCT CASE
                WHEN COALESCE(current_health, health_overall) IN ('Red', 'Yellow')
                THEN jira_issue_id END)                                       AS red,
            -- on-time: project is ON TIME if it has not slipped (no revised date later than expected)
            -- and either still in progress before deadline OR completed on/before deadline.
            -- A project is LATE if revised_completion > expected_completion.
            ROUND(
                100.0 * SUM(CASE
                    WHEN COALESCE(revised_completion, expected_completion) IS NULL
                         AND actual_completion IS NULL THEN NULL  -- exclude from denominator
                    WHEN revised_completion IS NOT NULL
                         AND expected_completion IS NOT NULL
                         AND revised_completion > expected_completion THEN 0  -- slipped = late
                    WHEN actual_completion IS NOT NULL
                         AND actual_completion <= COALESCE(expected_completion, revised_completion) THEN 1
                    WHEN actual_completion IS NULL
                         AND COALESCE(expected_completion, revised_completion) >= CURRENT_DATE THEN 1
                    ELSE 0 END)
                / NULLIF(SUM(CASE
                    WHEN COALESCE(revised_completion, expected_completion) IS NOT NULL
                         OR actual_completion IS NOT NULL THEN 1 ELSE 0 END), 0)
            , 2)                                                              AS on_time_pct,
            -- average duration in weeks where kickoff date is known
            ROUND(AVG(
                CASE WHEN actual_kickoff IS NOT NULL
                THEN (GREATEST(
                    COALESCE(actual_completion, '1900-01-01'::DATE),
                    COALESCE(revised_completion, '1900-01-01'::DATE),
                    COALESCE(expected_completion, '1900-01-01'::DATE),
                    CURRENT_DATE
                ) - actual_kickoff) / 7.0
                END
            )::NUMERIC, 2)                                                    AS avg_duration_weeks,
            COALESCE(SUM(budget_hours), 0)                                    AS budget_hours_total
        FROM ps_project_status
        WHERE category = :cat
          AND status_category != 'Done'
          AND issue_type = :issue_type
          AND NOT COALESCE(is_excluded, FALSE)
          {cst_filter}
    """), {'cat': category, 'issue_type': issue_type_filter}).fetchone()

    # Billable hours this week for this category (from Clockify project_type)
    if category == 'PS':
        type_filter = "cp.project_type = 'Professional Services'"
    else:  # MC
        type_filter = "cp.project_type IN ('Managed Cloud', 'Managed Cloud and Managed IT', 'Managed IT')"

    billable_week = conn.execute(text(f"""
        SELECT COALESCE(SUM(te.duration_hours), 0) AS billable_hours
        FROM clockify_detailed_time_entries te
        LEFT JOIN clockify_projects cp ON te.clockify_project_id = cp.clockify_project_id
        WHERE te.entry_date BETWEEN :ws AND :we
          AND te.billable = TRUE
          AND te.duration_hours > 0
          AND {type_filter}
    """), {'ws': week_start, 'we': week_end}).fetchone()

    # Actual hours YTD for this category
    actual_ytd = conn.execute(text(f"""
        SELECT COALESCE(SUM(te.duration_hours), 0) AS actual_hours_ytd
        FROM clockify_detailed_time_entries te
        LEFT JOIN clockify_projects cp ON te.clockify_project_id = cp.clockify_project_id
        WHERE te.entry_date BETWEEN :ys AND :we
          AND te.duration_hours > 0
          AND {type_filter}
    """), {'ys': year_start, 'we': week_end}).fetchone()

    return {
        'active_projects':    int(health.active_projects or 0),
        'on_time_pct':        float(health.on_time_pct or 0),
        'avg_duration_weeks': float(health.avg_duration_weeks or 0),
        'projects_green':     int(health.green or 0),
        'projects_amber':     int(health.amber or 0),
        'projects_red':       int(health.red   or 0),
        'budget_hours_total': float(health.budget_hours_total or 0),
        'billable_hours':     float(billable_week.billable_hours or 0),
        'actual_hours_ytd':   float(actual_ytd.actual_hours_ytd or 0),
    }


# ---------------------------------------------------------------------------
# Escalation metrics
# ---------------------------------------------------------------------------

def _compute_escalation_metrics(conn, week_start: date) -> dict:
    year_start = date(week_start.year, 1, 1)

    # Definition aligned with vw_escalations_by_customer (the Escalations sheet):
    #   open      = status_category != 'Done' AND customer_name IS NOT NULL
    #   resolved  = status_category = 'Done'
    # The customer_name IS NOT NULL filter matches the sheet, which excludes
    # escalations with no customer assigned (e.g. ES-232). Without it the OKR
    # tile counted customer-less escalations the sheet did not.
    row = conn.execute(text("""
        SELECT
            SUM(CASE WHEN COALESCE(status_category,'') <> 'Done'
                     THEN 1 ELSE 0 END)                          AS open_escalations,
            SUM(CASE WHEN priority IN ('Highest','High')
                      AND COALESCE(status_category,'') <> 'Done'
                     THEN 1 ELSE 0 END)                          AS high_priority,
            SUM(CASE WHEN priority = 'Medium'
                      AND COALESCE(status_category,'') <> 'Done'
                     THEN 1 ELSE 0 END)                          AS med_priority,
            ROUND(AVG(CASE
                WHEN COALESCE(status_category,'') <> 'Done'
                THEN CURRENT_DATE - created_date::DATE
                ELSE NULL END)::NUMERIC, 2)                      AS avg_days_open,
            SUM(CASE
                WHEN resolution_date IS NOT NULL
                 AND resolution_date >= :ys
                THEN 1 ELSE 0 END)                               AS resolved_ytd
        FROM escalations
        WHERE customer_name IS NOT NULL
    """), {'ys': year_start}).fetchone()

    return {
        'open_escalations': int(row.open_escalations or 0),
        'high_priority':    int(row.high_priority    or 0),
        'med_priority':     int(row.med_priority     or 0),
        'avg_days_open':    float(row.avg_days_open  or 0),
        'resolved_ytd':     int(row.resolved_ytd     or 0),
    }


# ---------------------------------------------------------------------------
# Upsert helper
# ---------------------------------------------------------------------------

def _upsert(conn, row: dict) -> None:
    conn.execute(text("""
        INSERT INTO kpi_weekly_snapshots (
            week_start_date, week_num, snapshot_taken_at,
            billable_util_pct, productive_util_pct, time_compliance_pct,
            presales_hours, productive_nb_hours, total_available_hours,
            total_billable_hours, missing_time_count, nb_nonproductive_hours,
            ps_active_projects, ps_on_time_pct, ps_avg_duration_weeks,
            ps_projects_green, ps_projects_amber, ps_projects_red,
            ps_billable_hours, ps_budget_hours_total, ps_actual_hours_ytd,
            mc_active_projects, mc_on_time_pct, mc_avg_duration_weeks,
            mc_projects_green, mc_projects_amber, mc_projects_red,
            mc_billable_hours, mc_budget_hours_total, mc_actual_hours_ytd,
            open_escalations, escalations_high_priority, escalations_med_priority,
            avg_escalation_days_open, escalations_resolved_ytd,
            active_resource_count,
            updated_at
        ) VALUES (
            :week_start_date, :week_num, :snapshot_taken_at,
            :billable_util_pct, :productive_util_pct, :time_compliance_pct,
            :presales_hours, :productive_nb_hours, :total_available_hours,
            :total_billable_hours, :missing_time_count, :nb_nonproductive_hours,
            :ps_active_projects, :ps_on_time_pct, :ps_avg_duration_weeks,
            :ps_projects_green, :ps_projects_amber, :ps_projects_red,
            :ps_billable_hours, :ps_budget_hours_total, :ps_actual_hours_ytd,
            :mc_active_projects, :mc_on_time_pct, :mc_avg_duration_weeks,
            :mc_projects_green, :mc_projects_amber, :mc_projects_red,
            :mc_billable_hours, :mc_budget_hours_total, :mc_actual_hours_ytd,
            :open_escalations, :escalations_high_priority, :escalations_med_priority,
            :avg_escalation_days_open, :escalations_resolved_ytd,
            :active_resource_count,
            NOW()
        )
        ON CONFLICT (week_start_date) DO UPDATE SET
            week_num                  = EXCLUDED.week_num,
            snapshot_taken_at         = EXCLUDED.snapshot_taken_at,
            billable_util_pct         = EXCLUDED.billable_util_pct,
            productive_util_pct       = EXCLUDED.productive_util_pct,
            time_compliance_pct       = EXCLUDED.time_compliance_pct,
            presales_hours            = EXCLUDED.presales_hours,
            productive_nb_hours       = EXCLUDED.productive_nb_hours,
            total_available_hours     = EXCLUDED.total_available_hours,
            total_billable_hours      = EXCLUDED.total_billable_hours,
            missing_time_count        = EXCLUDED.missing_time_count,
            nb_nonproductive_hours    = EXCLUDED.nb_nonproductive_hours,
            ps_active_projects        = EXCLUDED.ps_active_projects,
            ps_on_time_pct            = EXCLUDED.ps_on_time_pct,
            ps_avg_duration_weeks     = EXCLUDED.ps_avg_duration_weeks,
            ps_projects_green         = EXCLUDED.ps_projects_green,
            ps_projects_amber         = EXCLUDED.ps_projects_amber,
            ps_projects_red           = EXCLUDED.ps_projects_red,
            ps_billable_hours         = EXCLUDED.ps_billable_hours,
            ps_budget_hours_total     = EXCLUDED.ps_budget_hours_total,
            ps_actual_hours_ytd       = EXCLUDED.ps_actual_hours_ytd,
            mc_active_projects        = EXCLUDED.mc_active_projects,
            mc_on_time_pct            = EXCLUDED.mc_on_time_pct,
            mc_avg_duration_weeks     = EXCLUDED.mc_avg_duration_weeks,
            mc_projects_green         = EXCLUDED.mc_projects_green,
            mc_projects_amber         = EXCLUDED.mc_projects_amber,
            mc_projects_red           = EXCLUDED.mc_projects_red,
            mc_billable_hours         = EXCLUDED.mc_billable_hours,
            mc_budget_hours_total     = EXCLUDED.mc_budget_hours_total,
            mc_actual_hours_ytd       = EXCLUDED.mc_actual_hours_ytd,
            open_escalations          = EXCLUDED.open_escalations,
            escalations_high_priority = EXCLUDED.escalations_high_priority,
            escalations_med_priority  = EXCLUDED.escalations_med_priority,
            avg_escalation_days_open  = EXCLUDED.avg_escalation_days_open,
            escalations_resolved_ytd  = EXCLUDED.escalations_resolved_ytd,
            active_resource_count     = EXCLUDED.active_resource_count,
            updated_at                = NOW()
    """), row)


# ---------------------------------------------------------------------------
# Lambda entry point (called from lambda_handler.py)
# ---------------------------------------------------------------------------

def run(week_start: Optional[date] = None) -> dict:
    """Entry point for lambda_handler.  DATABASE_URL must already be set."""
    from sqlalchemy import create_engine as _create_engine
    engine = _create_engine(os.environ['DATABASE_URL'])
    return take_weekly_snapshot(engine, week_start=week_start)


# ---------------------------------------------------------------------------
# CLI helper for local backfill
# ---------------------------------------------------------------------------

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Write a KPI weekly snapshot')
    parser.add_argument('--week', help='Week start date YYYY-MM-DD (default: last complete week)')
    args = parser.parse_args()

    target = date.fromisoformat(args.week) if args.week else None
    result = run(week_start=target)
    print(result)

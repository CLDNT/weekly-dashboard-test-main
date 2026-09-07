"""Pipeline handler module.

Handles the core weekly/incremental/full import orchestration as well as
the two standalone utility modes:

  - snapshot_kpis       – compute and store weekly KPI snapshot
  - forecast_resources  – run resource forecast

The main entry point `run_pipeline` is called by the thin dispatcher for
mode in (None/'weekly'/'incremental'/'full') and executes the full
multi-stage pipeline exactly as the original lambda_handler did.
"""

import json
import os
from datetime import datetime
from typing import Any, Dict


def snapshot_kpis(event: dict, context: Any, secrets: dict) -> dict:
    """Compute and store weekly KPI snapshot.

    event keys:
      week_start  ISO date str | None
    """
    # Heavy imports inside function — secrets must already be in os.environ
    from src.integrations.kpi_snapshot import run as kpi_run
    from datetime import date as _date

    week_str = event.get('week_start')
    week_start = _date.fromisoformat(week_str) if week_str else None
    result = kpi_run(week_start=week_start)
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': f"KPI snapshot written for {result['week_start_date']}",
            'week_start_date': str(result['week_start_date']),
        })
    }


def forecast_resources(event: dict, context: Any, secrets: dict) -> dict:
    """Run resource forecast."""
    # Heavy imports inside function
    from src.integrations.forecast_resources import run_resource_forecast
    from src.database.config import engine

    with engine.connect() as conn:
        result = run_resource_forecast(conn)
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': f"Resource forecast complete: {result['people']} people, {result['projects']} projects",
            **result
        })
    }


def run_pipeline(event: dict, context: Any, secrets: dict) -> dict:
    """Run the full weekly / incremental / full import pipeline.

    Mirrors the original fall-through path in lambda_handler exactly:
      1.  apply_database_views (non-fatal)
      2.  run_import (Clockify)
      3.  run_jira_import
      4.  kpi_snapshot (non-fatal)
      5.  analyze_project_health (non-fatal)
      6.  run_mc_v2_audit (non-fatal)
      7.  run_escalations_import (non-fatal)
      8.  collect statistics (SessionLocal / ImportLog)
      9.  compliance snapshot query (weekly only, non-fatal)
      10. refresh all QuickSight SPICE datasets
      11. send_run_status_email
      12. return success response

    Returns the same dict shape as the original handler branch.
    """
    # ── Event params ─────────────────────────────────────────────────────────
    mode = event.get('mode', 'incremental')
    weeks_back = event.get('weeks_back', None)
    notify = event.get('notify', False)
    dataset_ids = event.get('quicksight_dataset_ids', [])  # Optional override; empty = refresh all
    notification_topic = os.environ.get('NOTIFICATION_TOPIC_ARN', '')

    # ── Determine import parameters ──────────────────────────────────────────
    incremental = (mode == 'incremental')
    if mode == 'weekly' and weeks_back is None:
        weeks_back = 1
    elif mode == 'full' and weeks_back is None:
        weeks_back = 52

    print(f"Starting import - Mode: {mode}, Incremental: {incremental}, Weeks: {weeks_back}")

    # ── Initialise run summary ───────────────────────────────────────────────
    from datetime import date as _date, timedelta as _timedelta

    run_errors = []
    run_start = datetime.now()
    today_d = run_start.date()
    last_monday = today_d - _timedelta(days=today_d.weekday() + 7)
    run_summary = {
        'mode': mode,
        'status': 'SUCCESS',
        'run_date': run_start,
        'week_start': last_monday if mode == 'weekly' else None,
        'week_end': last_monday + _timedelta(days=6) if mode == 'weekly' else None,
        'users_updated': 0,
        'projects_updated': 0,
        'time_entries_updated': 0,
        'jira_updated': 0,
        'kpi_written': False,
        'kpi_week': '',
        'spice_triggered': 0,
        'compliance_total': 0,
        'compliance_compliant': 0,
        'compliance_noncompliant': 0,
        'errors': run_errors,
    }

    # ── 1. Apply database views before import ────────────────────────────────
    # Heavy import inside this call (apply_database_views does its own lazy import)
    print("Applying database views...")
    try:
        from src.handlers.admin import apply_database_views
        apply_database_views(master_url=secrets.get('master_database_url'))
        print("Database views applied successfully")
    except Exception as e:
        print(f"Warning: View application failed (non-fatal): {str(e)[:100]}")

    # ── 2. Clockify import ───────────────────────────────────────────────────
    # Import here after secrets are set
    from src.integrations.import_clockify_data import run_import

    import_summary = run_import(weeks_back=weeks_back, incremental=incremental)
    print("Import completed")
    # B-3: surface per-user import failures so the run is marked ERRORS + alerted,
    # and so the watermark (which only advances on a fully 'success' log) is honoured.
    if import_summary and import_summary.get('failed_users'):
        fu = import_summary['failed_users']
        run_errors.append(
            f"Clockify import: {len(fu)} user(s) failed — watermark not advanced past the gap; "
            f"users: {', '.join(fu[:20])}" + (" …" if len(fu) > 20 else "")
        )

    # ── 3. Jira import ───────────────────────────────────────────────────────
    print("Starting Jira import...")
    from src.integrations.import_jira_data import run_jira_import
    jira_result = run_jira_import(full_sync=True)
    print(f"Jira import completed: {jira_result}")
    jira_stats = jira_result.get('statistics', {})
    run_summary['jira_updated'] = (
        jira_stats.get('ps_project_status', {}).get('imported', 0)
        + jira_stats.get('ps_project_status', {}).get('updated', 0)
    )

    # ── 4. KPI snapshot ──────────────────────────────────────────────────────
    print("Computing weekly KPI snapshot...")
    try:
        from src.integrations.kpi_snapshot import run as kpi_run
        snap_result = kpi_run()
        print(f"KPI snapshot written for {snap_result['week_start_date']}")
        run_summary['kpi_written'] = True
        run_summary['kpi_week'] = str(snap_result['week_start_date'])
        # Update COO analysis week parameter to new snapshot week
        from src.handlers.quicksight import update_analysis_week_parameter
        update_analysis_week_parameter(str(snap_result['week_start_date']))
    except Exception as snap_exc:
        print(f"KPI snapshot failed (non-fatal): {snap_exc}")
        run_errors.append(f"KPI snapshot: {snap_exc}")

    # ── 5. AI project health analysis ────────────────────────────────────────
    print("Starting AI project health analysis...")
    try:
        from src.integrations.analyze_project_health import run_analysis as run_ph_analysis
        ph_summary = run_ph_analysis(weeks_back=1)
        print(f"AI analysis completed: {ph_summary}")
    except Exception as ph_exc:
        print(f"AI analysis failed (non-fatal): {ph_exc}")
        ph_summary = {'error': str(ph_exc)}
        run_errors.append(f"AI analysis: {ph_exc}")

    # ── 6. MC V2 Audit ───────────────────────────────────────────────────────
    print("Starting MC V2 Audit...")
    try:
        from src.integrations.mc_v2_audit import run_mc_v2_audit
        from datetime import date as _date2, timedelta as _timedelta2
        from src.handlers.quicksight import refresh_quicksight_datasets
        today2 = _date2.today()
        ws = today2 - _timedelta2(days=today2.weekday())  # this Monday
        audit_summary = run_mc_v2_audit(ws)
        refresh_quicksight_datasets(['mc-v2-audit-by-customer', 'mc-v2-audit-by-phase', 'mc-v2-audit-grid'])
        print(f"MC V2 Audit completed: {audit_summary}")
    except Exception as audit_exc:
        print(f"MC V2 Audit failed (non-fatal): {audit_exc}")
        run_errors.append(f"MC V2 Audit: {audit_exc}")

    # ── 7. Escalations import ────────────────────────────────────────────────
    print("Starting escalations import...")
    try:
        from src.integrations.import_escalations import run_escalations_import
        from src.handlers.quicksight import refresh_quicksight_datasets as _qs_refresh
        esc_summary = run_escalations_import()
        _qs_refresh(['escalations-detail', 'escalations-by-customer'])
        print(f"Escalations import completed: {esc_summary}")
    except Exception as esc_exc:
        print(f"Escalations import failed (non-fatal): {esc_exc}")
        run_errors.append(f"Escalations import: {esc_exc}")

    # ── 8. Collect statistics ────────────────────────────────────────────────
    # Import SessionLocal and models here after secrets are set
    from src.database.config import SessionLocal
    db = SessionLocal()
    try:
        from src.database.models import ImportLog
        from sqlalchemy import text as sql_text

        last_import = db.query(ImportLog).filter(
            ImportLog.import_category == 'time_entries'
        ).order_by(ImportLog.completed_at.desc()).first()

        total_users   = db.execute(sql_text("SELECT COUNT(*) FROM clockify_users")).scalar()
        active_users  = db.execute(sql_text("SELECT COUNT(*) FROM clockify_users WHERE status = 'active'")).scalar()
        total_entries = db.execute(sql_text("SELECT COUNT(*) FROM clockify_detailed_time_entries")).scalar()

        stats = {
            'total_users': total_users,
            'active_users': active_users,
            'total_entries': total_entries,
        }

        run_summary['users_updated'] = total_users or 0
        run_summary['projects_updated'] = db.execute(sql_text("SELECT COUNT(*) FROM clockify_projects")).scalar() or 0

        if last_import:
            stats['last_import'] = {
                'type': last_import.import_type,
                'imported': last_import.records_imported,
                'updated': last_import.records_updated,
                'completed_at': last_import.completed_at.isoformat() if last_import.completed_at else None
            }
            run_summary['time_entries_updated'] = (last_import.records_imported or 0) + (last_import.records_updated or 0)

        # ── 9. Compliance snapshot (weekly only) ─────────────────────────────
        if mode == 'weekly':
            try:
                from datetime import date as _date3, timedelta as _timedelta3
                lw_start = (_date3.today() - _timedelta3(days=_date3.today().weekday() + 7)).isoformat()
                comp_rows = db.execute(sql_text("""
                    SELECT
                        COUNT(DISTINCT u.clockify_user_id) AS total,
                        COUNT(DISTINCT te.clockify_user_id) AS submitted
                    FROM clockify_users u
                    LEFT JOIN clockify_detailed_time_entries te
                        ON te.clockify_user_id = u.clockify_user_id
                        AND te.week_start = :lw
                    WHERE u.status = 'active'
                      AND u.daily_capacity > 0
                      AND COALESCE(u.time_submission, '') != 'No'
                      AND (u.pod_assignment IS NULL OR u.pod_assignment NOT ILIKE '%exempt%')
                      AND COALESCE(u.practice_area, 'Internal') != 'Exempt'
                      AND NOT COALESCE(u.reporting_excluded, FALSE)
                """), {'lw': lw_start}).fetchone()
                if comp_rows:
                    run_summary['compliance_total']        = comp_rows[0] or 0
                    run_summary['compliance_compliant']    = comp_rows[1] or 0
                    run_summary['compliance_noncompliant'] = (comp_rows[0] or 0) - (comp_rows[1] or 0)
            except Exception as comp_exc:
                print(f"Compliance snapshot query failed (non-fatal): {comp_exc}")

    finally:
        db.close()

    # ── 10. Refresh all QuickSight SPICE datasets (with verification) ────────
    from src.handlers.quicksight import (
        get_all_dataset_ids,
        refresh_quicksight_datasets as qs_refresh,
        summarize_spice_results,
    )

    environment = os.environ.get('ENVIRONMENT', 'production')
    all_dataset_ids = get_all_dataset_ids(environment)
    # Allow override from event, otherwise use all datasets
    refresh_dataset_ids = dataset_ids if dataset_ids else all_dataset_ids
    print(f"Refreshing {len(refresh_dataset_ids)} QuickSight SPICE datasets (verified)...")
    qs_results = qs_refresh(refresh_dataset_ids)  # polls each ingestion to terminal state
    spice_summary = summarize_spice_results(qs_results)

    # A-1: SPICE failures are no longer silent — surface every FAILED/CANCELLED/
    # TIMEOUT/TRIGGER_FAILED so the run is marked ERRORS and alerted.
    run_summary['spice_triggered'] = len(refresh_dataset_ids)
    run_summary['spice_succeeded'] = spice_summary['succeeded']
    run_summary['spice_failed'] = spice_summary['failed']
    run_summary['spice_results'] = qs_results
    for msg in spice_summary['error_messages']:
        run_errors.append(msg)

    if spice_summary['failed'] > 0:
        alert_body = (
            f"{spice_summary['failed']} QuickSight SPICE dataset(s) failed to refresh "
            f"during the {mode} run.\n\n" + "\n".join(spice_summary['error_messages'])
        )
        print(f"[spice] ALERT — {alert_body}")
        if notification_topic:
            from src.handlers.common import send_sns_notification
            send_sns_notification(
                notification_topic,
                "❌ Weekly Reporting — SPICE refresh FAILED",
                alert_body,
            )

    # ── 11. Post-run status email ─────────────────────────────────────────────
    if run_errors:
        run_summary['status'] = 'ERRORS'
    print(f"Sending run status email (status={run_summary['status']})...")
    from src.handlers.notifications import send_run_status_email
    send_run_status_email(run_summary)

    # Prepare success message
    message = f"""
Weekly Reporting Import Completed Successfully

Environment: {os.environ.get('ENVIRONMENT', 'unknown')}
Mode: {mode}
Timestamp: {datetime.now().isoformat()}

Clockify Statistics:
- Total Users: {stats.get('total_users', 'N/A')}
- Active Users: {stats.get('active_users', 'N/A')}
- Total Time Entries: {stats.get('total_entries', 'N/A')}

Last Clockify Import:
- Type: {stats.get('last_import', {}).get('type', 'N/A')}
- Records Imported: {stats.get('last_import', {}).get('imported', 'N/A')}
- Records Updated: {stats.get('last_import', {}).get('updated', 'N/A')}

Jira Import:
- Projects: {jira_stats.get('projects', {}).get('imported', 0)} imported, {jira_stats.get('projects', {}).get('updated', 0)} updated
- PS Project Status: {jira_stats.get('ps_project_status', {}).get('imported', 0)} imported, {jira_stats.get('ps_project_status', {}).get('updated', 0)} updated

QuickSight Refresh: {'Triggered' if qs_results else 'Not requested'}
    """

    # Send notification if enabled
    if notify and notification_topic:
        from src.handlers.common import send_sns_notification
        send_sns_notification(
            notification_topic,
            "✅ Weekly Reporting Import Success",
            message
        )

    print(message)

    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'Import completed successfully',
            'timestamp': datetime.now().isoformat(),
            'statistics': stats,
            'quicksight_refresh': qs_results
        })
    }

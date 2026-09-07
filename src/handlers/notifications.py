"""Notification handler module.

Modes handled:
  - send_run_status_email  (called internally by pipeline after every run)
  - send_compliance_report (explicit mode — sends non-compliance email on demand)
"""

import os
from datetime import datetime
from typing import Dict, Any

import boto3


# ---------------------------------------------------------------------------
# Internal helper — lives here because it is only used by send_run_status_email
# ---------------------------------------------------------------------------

def _classify_error(raw: str) -> dict:
    """Return a dict with stage, severity, impact, action derived from the raw error string."""
    r = str(raw)
    rl = r.lower()

    # INFO — non-blocking, known gaps
    if 'quicksight:describetheme' in rl or 'accessdenied' in rl and 'describetheme' in rl:
        return dict(stage='QuickSight Theme', severity='INFO',
                    error=r, impact='No dashboard impact — pre-existing IAM gap.',
                    action='No action needed.')
    if 'already in progress' in rl:
        return dict(stage='SPICE Refresh', severity='INFO',
                    error=r, impact='Dataset refresh was already running from a prior trigger.',
                    action='No action needed — dataset is refreshing.')

    # WARNING — partial failure, non-critical stage
    if 'read timeout' in rl and ('bedrock' in rl or 'ai' in rl or 'analysis' in rl):
        return dict(stage='AI Analysis (Bedrock)', severity='WARNING',
                    error=r, impact='AI project health analysis skipped. Core data import unaffected.',
                    action='Will retry next Monday. Re-run manually: {"mode":"analyze_project_health"}')
    if 'task timed out' in rl and ('bedrock' in rl or 'mc_v2' in rl or 'mc v2' in rl or 'audit' in rl):
        return dict(stage='AI Analysis / MC V2 Audit', severity='WARNING',
                    error=r, impact='AI analysis incomplete. Core Clockify and Jira data was imported.',
                    action='Re-run: {"mode":"mc_v2_audit"} or {"mode":"analyze_project_health"}')
    if 'task timed out' in rl:
        return dict(stage='Lambda Timeout', severity='WARNING',
                    error=r, impact='One or more non-critical stages may be incomplete.',
                    action='Check CloudWatch logs for the last stage reached.')
    if 'must be owner of view' in rl or 'must be owner' in rl:
        return dict(stage='Database Views', severity='WARNING',
                    error=r, impact='View recreation skipped. Existing views are still operational.',
                    action='Run manually: {"mode":"apply_views"} with a superuser connection.')
    if 'kpi snapshot' in rl:
        return dict(stage='KPI Snapshot', severity='WARNING',
                    error=r, impact='Weekly KPI tile may show stale or missing values in QuickSight.',
                    action='Re-run: {"mode":"snapshot_kpis"}')
    if 'spice' in rl or 'ingestion' in rl or 'quicksight' in rl:
        return dict(stage='SPICE Refresh', severity='WARNING',
                    error=r, impact='One or more QuickSight datasets may show stale data.',
                    action='Refresh manually from the Streamlit Data Management page.')
    if 'jira' in rl:
        return dict(stage='Jira Import', severity='WARNING',
                    error=r, impact='PS/MC project status data may be stale.',
                    action='Re-run: {"mode":"jira_import"}')
    if 'escalation' in rl:
        return dict(stage='Escalations Import', severity='WARNING',
                    error=r, impact='Escalations dashboard may be stale.',
                    action='Re-run: {"mode":"run_escalations_import"}')

    # CRITICAL — core import stages
    if 'clockify' in rl or 'import' in rl or 'database' in rl or 'connection' in rl:
        return dict(stage='Clockify Import', severity='CRITICAL',
                    error=r, impact='Time entry data may be missing or stale. Dashboards will show incorrect hours.',
                    action='Check CloudWatch logs. Re-run: {"mode":"weekly"}')

    # Default: treat unknown errors as CRITICAL to surface them
    return dict(stage='Unknown', severity='CRITICAL',
                error=r, impact='Unknown impact — review CloudWatch logs.',
                action='Check CloudWatch logs for this Lambda invocation.')


# ---------------------------------------------------------------------------
# Public handler functions
# ---------------------------------------------------------------------------

def send_run_status_email(run_summary: dict):
    """Send a post-run status email summarising the import results.

    Uses SES (sesv2) for rich HTML formatting.  Recipients are read from the
    compliance_report_recipients table (report_run = 'run_status' or 'all').
    Falls back to the NOTIFICATION_RECIPIENTS env var if no DB rows are found.
    Never raises — all failures are logged and swallowed.

    Args:
        run_summary: dict with keys:
            mode            str   'weekly' | 'incremental'
            run_date        datetime
            week_start      date | None   (weekly only)
            week_end        date | None   (weekly only)
            users_updated   int
            projects_updated int
            time_entries_updated int
            jira_updated    int
            kpi_written     bool
            kpi_week        str  (date string, weekly only)
            spice_triggered int
            compliance_total int
            compliance_compliant int
            compliance_noncompliant int
            errors          list[str]
            status          str  'SUCCESS' | 'ERRORS'
    """
    from zoneinfo import ZoneInfo

    mode = run_summary.get('mode', 'unknown')
    status = run_summary.get('status', 'SUCCESS')
    errors = run_summary.get('errors', [])
    run_date = run_summary.get('run_date', datetime.now())

    # ── Format dates ────────────────────────────────────────────────────────
    ct = ZoneInfo('America/Chicago')
    if run_date.tzinfo is None:
        from datetime import timezone as _tz
        run_date_ct = run_date.replace(tzinfo=_tz.utc).astimezone(ct)
    else:
        run_date_ct = run_date.astimezone(ct)

    run_date_str = run_date_ct.strftime('%A, %B %-d, %Y — %-I:%M %p CT')

    week_start = run_summary.get('week_start')
    week_end = run_summary.get('week_end')
    if week_start and week_end:
        week_range = f"{week_start.strftime('%B %-d')} – {week_end.strftime('%B %-d, %Y')}"
    elif week_start:
        week_range = week_start.strftime('%B %-d, %Y')
    else:
        week_range = 'N/A'

    # ── Determine next run date ──────────────────────────────────────────────
    from datetime import timedelta
    today = run_date_ct.date()
    days_until_monday = (7 - today.weekday()) % 7 or 7
    next_monday = today + timedelta(days=days_until_monday)
    next_run_str = next_monday.strftime('%A, %B %-d, %Y') + ' at 9:00 AM CT'

    # ── Status badge (icon finalised after error classification below) ────────
    status_label = 'SUCCESS' if status == 'SUCCESS' else 'ERRORS DETECTED'
    # subject and status_icon are set after error classification below

    # ── Colours ─────────────────────────────────────────────────────────────
    HEADER_BG   = '#1a3a5c'
    STATUS_OK   = '#27ae60'
    STATUS_ERR  = '#c0392b'
    ROW_ALT     = '#f8f9fa'
    BORDER      = '#dee2e6'
    status_color = STATUS_OK if status == 'SUCCESS' else STATUS_ERR

    # ── KPI row ─────────────────────────────────────────────────────────────
    kpi_written = run_summary.get('kpi_written', False)
    kpi_week    = run_summary.get('kpi_week', '')
    kpi_label   = f"✅ Written for {kpi_week}" if kpi_written else '⚠️ Not written'

    # ── Compliance row ───────────────────────────────────────────────────────
    comp_total       = run_summary.get('compliance_total', 0)
    comp_compliant   = run_summary.get('compliance_compliant', 0)
    comp_noncompliant = run_summary.get('compliance_noncompliant', 0)
    comp_pct = f"{(comp_compliant / comp_total * 100):.1f}%" if comp_total else 'N/A'

    # ── SPICE row ────────────────────────────────────────────────────────────
    spice_count = run_summary.get('spice_triggered', 0)
    spice_succeeded = run_summary.get('spice_succeeded')
    spice_failed = run_summary.get('spice_failed')
    if spice_succeeded is not None:
        # Verified path (A-1): report real terminal outcomes, not just triggers.
        if spice_failed:
            spice_label = f"❌ {spice_failed} failed, {spice_succeeded} succeeded of {spice_count}"
        else:
            spice_label = f"✅ {spice_succeeded} of {spice_count} refreshed & verified"
    else:
        spice_label = f"{spice_count} triggered"

    # ── Errors section — classify and enrich each error ─────────────────────
    _SEV_COLOR   = {'CRITICAL': '#c0392b', 'WARNING': '#e67e22', 'INFO': '#2980b9'}
    _SEV_ICON    = {'CRITICAL': '🔴', 'WARNING': '🟡', 'INFO': '🔵'}

    if errors:
        classified = [_classify_error(e) for e in errors]
        n_critical = sum(1 for c in classified if c['severity'] == 'CRITICAL')
        n_warning  = sum(1 for c in classified if c['severity'] == 'WARNING')
        n_info     = sum(1 for c in classified if c['severity'] == 'INFO')

        # Summary line
        if n_critical:
            err_summary = f'🔴 {n_critical} critical error{"s" if n_critical > 1 else ""}, {n_warning} warning{"s" if n_warning != 1 else ""}'
        elif n_warning:
            err_summary = f'🟡 {n_warning} warning{"s" if n_warning > 1 else ""}, 0 critical'
        else:
            err_summary = f'🔵 {len(classified)} info notice{"s" if len(classified) != 1 else ""}, 0 critical'

        error_rows = ''
        for c in classified:
            sev_col  = _SEV_COLOR.get(c['severity'], '#555')
            sev_icon = _SEV_ICON.get(c['severity'], '')
            error_rows += f"""
              <tr>
                <td style="border:1px solid #dee2e6;padding:8px 10px;white-space:nowrap;font-weight:700;color:{sev_col}">{sev_icon} {c['severity']}</td>
                <td style="border:1px solid #dee2e6;padding:8px 10px;color:#555;white-space:nowrap">{c['stage']}</td>
                <td style="border:1px solid #dee2e6;padding:8px 10px;font-family:monospace;font-size:12px;color:#c0392b;word-break:break-all">{c['error']}</td>
                <td style="border:1px solid #dee2e6;padding:8px 10px;color:#555">{c['impact']}</td>
                <td style="border:1px solid #dee2e6;padding:8px 10px;color:#2c3e50;font-style:italic">{c['action']}</td>
              </tr>"""

        errors_html = f"""
          <p style="margin:0 0 8px;font-weight:600">{err_summary}</p>
          <table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px">
            <tr style="background:#f0f0f0">
              <th style="border:1px solid #dee2e6;padding:7px 10px;text-align:left">Severity</th>
              <th style="border:1px solid #dee2e6;padding:7px 10px;text-align:left">Stage</th>
              <th style="border:1px solid #dee2e6;padding:7px 10px;text-align:left">Error</th>
              <th style="border:1px solid #dee2e6;padding:7px 10px;text-align:left">Impact</th>
              <th style="border:1px solid #dee2e6;padding:7px 10px;text-align:left">Action</th>
            </tr>
            {error_rows}
          </table>"""
    else:
        err_summary = '✅ No errors'
        errors_html = '<p style="color:#27ae60;margin:0">✅ No errors</p>'

    # ── Derive subject and status icon now that severity is known ─────────────
    if status == 'SUCCESS':
        status_icon = '✅'
    elif errors and all(_classify_error(e)['severity'] in ('WARNING', 'INFO') for e in errors):
        status_icon = '⚠️'
        status_label = 'WARNINGS ONLY'
    else:
        status_icon = '❌'

    date_str_subj = run_date_ct.strftime('%B %-d, %Y')
    if mode == 'incremental':
        subject = f"Incremental Refresh — {status_icon} {status_label} — {date_str_subj}"
    else:
        subject = f"Weekly Reporting Import — {status_icon} {status_label} — {date_str_subj}"

    # ── Import results section (weekly vs incremental) ───────────────────────
    if mode == 'weekly':
        import_section = f"""
        <table width="100%" cellpadding="10" cellspacing="0" style="border-collapse:collapse;margin-bottom:20px">
          <tr style="background:{HEADER_BG};color:#ffffff">
            <td colspan="2" style="padding:10px 14px;font-weight:bold;font-size:14px;letter-spacing:0.5px">
              IMPORT RESULTS
            </td>
          </tr>
          <tr><td style="border:1px solid {BORDER};padding:8px 12px;color:#555">Reporting Week</td>
              <td style="border:1px solid {BORDER};padding:8px 12px;font-weight:500">{week_range}</td></tr>
          <tr style="background:{ROW_ALT}">
              <td style="border:1px solid {BORDER};padding:8px 12px;color:#555">Clockify Users</td>
              <td style="border:1px solid {BORDER};padding:8px 12px;font-weight:500">{run_summary.get('users_updated', 0):,} updated</td></tr>
          <tr><td style="border:1px solid {BORDER};padding:8px 12px;color:#555">Clockify Projects</td>
              <td style="border:1px solid {BORDER};padding:8px 12px;font-weight:500">{run_summary.get('projects_updated', 0):,} updated</td></tr>
          <tr style="background:{ROW_ALT}">
              <td style="border:1px solid {BORDER};padding:8px 12px;color:#555">Time Entries</td>
              <td style="border:1px solid {BORDER};padding:8px 12px;font-weight:500">{run_summary.get('time_entries_updated', 0):,} updated</td></tr>
          <tr><td style="border:1px solid {BORDER};padding:8px 12px;color:#555">Jira PS Projects</td>
              <td style="border:1px solid {BORDER};padding:8px 12px;font-weight:500">{run_summary.get('jira_updated', 0):,} updated</td></tr>
          <tr style="background:{ROW_ALT}">
              <td style="border:1px solid {BORDER};padding:8px 12px;color:#555">KPI Snapshot</td>
              <td style="border:1px solid {BORDER};padding:8px 12px;font-weight:500">{kpi_label}</td></tr>
        </table>

        <table width="100%" cellpadding="10" cellspacing="0" style="border-collapse:collapse;margin-bottom:20px">
          <tr style="background:{HEADER_BG};color:#ffffff">
            <td colspan="2" style="padding:10px 14px;font-weight:bold;font-size:14px;letter-spacing:0.5px">
              COMPLIANCE SNAPSHOT
            </td>
          </tr>
          <tr><td style="border:1px solid {BORDER};padding:8px 12px;color:#555">Total Active Staff</td>
              <td style="border:1px solid {BORDER};padding:8px 12px;font-weight:500">{comp_total:,}</td></tr>
          <tr style="background:{ROW_ALT}">
              <td style="border:1px solid {BORDER};padding:8px 12px;color:#555">Compliant</td>
              <td style="border:1px solid {BORDER};padding:8px 12px;font-weight:500;color:{STATUS_OK}">{comp_compliant:,} ({comp_pct})</td></tr>
          <tr><td style="border:1px solid {BORDER};padding:8px 12px;color:#555">Non-Compliant</td>
              <td style="border:1px solid {BORDER};padding:8px 12px;font-weight:500;color:{STATUS_ERR if comp_noncompliant else '#555'}">{comp_noncompliant:,}</td></tr>
        </table>
"""
    else:
        # Incremental — compact summary
        import_section = f"""
        <table width="100%" cellpadding="10" cellspacing="0" style="border-collapse:collapse;margin-bottom:20px">
          <tr style="background:{HEADER_BG};color:#ffffff">
            <td colspan="2" style="padding:10px 14px;font-weight:bold;font-size:14px;letter-spacing:0.5px">
              INCREMENTAL REFRESH RESULTS
            </td>
          </tr>
          <tr><td style="border:1px solid {BORDER};padding:8px 12px;color:#555">Time Entries</td>
              <td style="border:1px solid {BORDER};padding:8px 12px;font-weight:500">{run_summary.get('time_entries_updated', 0):,} updated</td></tr>
          <tr style="background:{ROW_ALT}">
              <td style="border:1px solid {BORDER};padding:8px 12px;color:#555">Jira PS Projects</td>
              <td style="border:1px solid {BORDER};padding:8px 12px;font-weight:500">{run_summary.get('jira_updated', 0):,} updated</td></tr>
        </table>
"""

    # ── Full HTML ────────────────────────────────────────────────────────────
    html_body = f"""<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"></head>
<body style="font-family:Arial,sans-serif;background:#f5f5f5;margin:0;padding:20px">
<div style="max-width:640px;margin:0 auto;background:#ffffff;border-radius:6px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.1)">

  <!-- Header -->
  <div style="background:{HEADER_BG};padding:20px 24px">
    <h1 style="margin:0;color:#ffffff;font-size:20px;font-weight:600">
      Weekly Reporting — Import Summary
    </h1>
    <p style="margin:6px 0 0;color:#a8c4e0;font-size:13px">
      Run date: {run_date_str}
    </p>
  </div>

  <!-- Status banner -->
  <div style="background:{status_color};padding:12px 24px">
    <p style="margin:0;color:#ffffff;font-size:16px;font-weight:600">
      {status_icon} {status_label}
    </p>
  </div>

  <!-- Body -->
  <div style="padding:20px 24px">
    {import_section}

    <table width="100%" cellpadding="10" cellspacing="0" style="border-collapse:collapse;margin-bottom:20px">
      <tr style="background:{HEADER_BG};color:#ffffff">
        <td colspan="2" style="padding:10px 14px;font-weight:bold;font-size:14px;letter-spacing:0.5px">
          SPICE REFRESH
        </td>
      </tr>
      <tr><td style="border:1px solid {BORDER};padding:8px 12px;color:#555">Datasets Triggered</td>
          <td style="border:1px solid {BORDER};padding:8px 12px;font-weight:500">{spice_count:,}</td></tr>
      <tr style="background:{ROW_ALT}">
          <td style="border:1px solid {BORDER};padding:8px 12px;color:#555">Status</td>
          <td style="border:1px solid {BORDER};padding:8px 12px;font-weight:500">{spice_label}</td></tr>
    </table>

    <table width="100%" cellpadding="10" cellspacing="0" style="border-collapse:collapse;margin-bottom:20px">
      <tr style="background:{HEADER_BG};color:#ffffff">
        <td style="padding:10px 14px;font-weight:bold;font-size:14px;letter-spacing:0.5px">
          ERRORS / WARNINGS
        </td>
      </tr>
      <tr><td style="border:1px solid {BORDER};padding:10px 14px">{errors_html}</td></tr>
    </table>

    <p style="color:#555;font-size:13px;margin-top:24px;padding-top:12px;border-top:1px solid {BORDER}">
      Next scheduled run: <strong>{next_run_str}</strong>
    </p>
  </div>

  <!-- Footer -->
  <div style="background:#f8f9fa;padding:12px 24px;border-top:1px solid {BORDER}">
    <p style="margin:0;color:#888;font-size:11px">
      Sent automatically by the Cloudelligent Weekly Reporting System
      &nbsp;|&nbsp; AWS Account 961341524729
    </p>
  </div>

</div>
</body>
</html>"""

    # ── Resolve recipients ───────────────────────────────────────────────────
    recipient_emails = []
    try:
        from sqlalchemy import text
        from src.database.config import engine
        with engine.connect() as conn:
            rows = conn.execute(text("""
                SELECT email FROM compliance_report_recipients
                WHERE is_active = TRUE
                  AND report_run IN ('run_status', 'all', 'both')
            """)).fetchall()
            recipient_emails = [r[0] for r in rows]
    except Exception as db_err:
        print(f"[run_status_email] Could not query recipients from DB: {db_err}")

    # Fallback: env var or hardcoded admin address
    if not recipient_emails:
        fallback = os.environ.get('NOTIFICATION_RECIPIENTS', 'chris.xenos@cloudelligent.com')
        recipient_emails = [e.strip() for e in fallback.split(',') if e.strip()]
        print(f"[run_status_email] Using fallback recipients: {recipient_emails}")

    if not recipient_emails:
        print("[run_status_email] No recipients — email skipped")
        return

    # ── Send via SES ─────────────────────────────────────────────────────────
    try:
        ses = boto3.client('sesv2', region_name='us-east-1')
        ses.send_email(
            FromEmailAddress='reports@cloudelligent.com',
            Destination={'ToAddresses': recipient_emails},
            Content={'Simple': {
                'Subject': {'Data': subject},
                'Body': {'Html': {'Data': html_body}}
            }}
        )
        print(f"[run_status_email] Sent '{subject}' to {recipient_emails}")
    except Exception as ses_err:
        print(f"[run_status_email] SES send failed (non-fatal): {ses_err}")


def send_compliance_report(event: dict, context: Any, secrets: dict) -> dict:
    """Send non-compliance timesheet email.

    event keys:
      run  str  'morning' | 'noon' | 'afternoon'
    """
    # Heavy imports inside function — secrets must be set first
    from datetime import date as _date, timedelta
    import datetime as _dt
    from datetime import timezone as _tz
    from sqlalchemy import text
    from src.database.config import engine

    run_type = event.get('run', 'morning')
    if run_type not in ('morning', 'noon', 'afternoon'):
        return {
            'statusCode': 400,
            'body': __import__('json').dumps({'error': f'Invalid run: {run_type}. Must be "morning", "noon", or "afternoon"'})
        }

    # Data freshness guard — refuse to send if data is more than 3 hours stale
    with engine.connect() as _fc:
        _last_sync = _fc.execute(text(
            "SELECT MAX(synced_at) FROM clockify_detailed_time_entries"
        )).scalar()

    if _last_sync is None:
        return {
            'statusCode': 503,
            'body': __import__('json').dumps({'error': 'No Clockify data in database — import has never run'})
        }

    _now = _dt.datetime.now(_tz.utc)
    _sync_utc = _last_sync if _last_sync.tzinfo else _last_sync.replace(tzinfo=_tz.utc)
    _age_hours = (_now - _sync_utc).total_seconds() / 3600

    if _age_hours > 3:
        print(f'[compliance_email] SKIPPING — data is {_age_hours:.1f} hours stale (last sync: {_last_sync})')
        return {
            'statusCode': 200,
            'body': __import__('json').dumps({
                'skipped': True,
                'reason': f'Data is {_age_hours:.1f} hours stale. Last sync: {str(_last_sync)}. Run import first.',
                'last_sync': str(_last_sync)
            })
        }

    with engine.connect() as conn:
        # Query non-compliant users for the most recently completed week
        last_week_start = (_date.today() - timedelta(days=_date.today().weekday() + 7)).isoformat()
        non_compliant = conn.execute(text("""
            SELECT u.name, u.pod_assignment, u.practice_area,
                   COALESCE(SUM(te.duration_hours), 0) AS hours_submitted
            FROM clockify_users u
            LEFT JOIN clockify_detailed_time_entries te
                ON te.clockify_user_id = u.clockify_user_id
                AND te.week_start = :week_start
            WHERE u.status = 'active'
              AND u.daily_capacity > 0
              AND COALESCE(u.time_submission, '') != 'No'
              AND (u.pod_assignment IS NULL OR u.pod_assignment NOT ILIKE '%exempt%')
              AND COALESCE(u.practice_area, 'Internal') != 'Exempt'
              AND NOT COALESCE(u.reporting_excluded, FALSE)
            GROUP BY u.name, u.pod_assignment, u.practice_area
            HAVING COALESCE(SUM(te.duration_hours), 0) = 0
            ORDER BY u.pod_assignment, u.name
        """), {'week_start': last_week_start}).fetchall()

        # Query recipients for this run type
        # 'both' is legacy alias for 'all'; 'all' matches every run
        recipients = conn.execute(text("""
            SELECT email, display_name FROM compliance_report_recipients
            WHERE is_active = TRUE
              AND (report_run IN ('both', 'all') OR report_run = :run)
        """), {'run': run_type}).fetchall()

    if not recipients:
        return {
            'statusCode': 200,
            'body': __import__('json').dumps({'message': 'No active recipients configured'})
        }

    recipient_emails = [r[0] for r in recipients]
    rows_data = [
        {'name': row[0], 'pod': row[1] or '(unassigned)', 'practice': row[2] or '(not set)'}
        for row in non_compliant
    ]

    # Build HTML email
    if rows_data:
        html_rows = ''.join([
            f'<tr><td>{row["name"]}</td><td>{row["pod"]}</td><td>{row["practice"]}</td></tr>'
            for row in rows_data
        ])
        body_text = f'<p>Week of {last_week_start} — {len(rows_data)} staff have not submitted time.</p>'
        table_html = f"""<table border="1" cellpadding="6" style="border-collapse:collapse">
          <tr style="background:#f0f0f0"><th>Name</th><th>POD</th><th>Practice Area</th></tr>
          {html_rows}
        </table>"""
    else:
        body_text = '<p>All staff have submitted their time for the week.</p>'
        table_html = ''

    html_body = f"""<h2>Timesheet Non-Compliance Report</h2>
{body_text}
{table_html}
<p style="color:#888;font-size:12px">Sent by Cloudelligent Weekly Reporting System</p>"""

    # Send via SES
    subject = f'Missing Time Report — Week of {last_week_start}'
    ses = boto3.client('sesv2', region_name='us-east-1')
    try:
        ses.send_email(
            FromEmailAddress='reports@cloudelligent.com',
            Destination={'ToAddresses': recipient_emails},
            Content={'Simple': {
                'Subject': {'Data': subject},
                'Body': {'Html': {'Data': html_body}}
            }}
        )
        return {
            'statusCode': 200,
            'body': __import__('json').dumps({
                'sent_to': len(recipient_emails),
                'non_compliant': len(rows_data)
            })
        }
    except ses.exceptions.ClientError as e:
        print(f"SES error: {str(e)}")
        return {
            'statusCode': 500,
            'body': __import__('json').dumps({
                'error': 'Email service unavailable',
                'detail': str(e)
            })
        }


# Type alias to satisfy the Any reference at module level without importing typing at top
from typing import Any  # noqa: E402 — kept at bottom to avoid circular-import issues

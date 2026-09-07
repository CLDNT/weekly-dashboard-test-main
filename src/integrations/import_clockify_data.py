"""Import data from Clockify into database."""

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

_CST = ZoneInfo("America/Chicago")
from sqlalchemy.orm import Session
from sqlalchemy import func
from src.database.config import SessionLocal
from src.database.models import ClockifyUser, ClockifyProject, ClockifyTimeEntry, ImportLog
from src.integrations.clockify_client import ClockifyClient


def parse_iso8601_duration_hours(duration: str) -> float:
    """Parse ISO-8601 duration string (e.g. 'PT8H', 'PT7H30M') into decimal hours."""
    if not duration:
        return 8.0
    import re
    m = re.match(r'PT(?:(\d+)H)?(?:(\d+)M)?', duration)
    if not m:
        return 8.0
    hours = int(m.group(1) or 0)
    minutes = int(m.group(2) or 0)
    return hours + minutes / 60.0


def get_monday_of_week(date=None):
    """Get Monday of the week for a given date."""
    if date is None:
        date = datetime.now()
    
    # Monday = 0, Sunday = 6
    days_since_monday = date.weekday()
    monday = date - timedelta(days=days_since_monday)
    return monday.replace(hour=0, minute=0, second=0, microsecond=0)


def get_sunday_of_week(date=None):
    """Get Sunday of the week for a given date."""
    monday = get_monday_of_week(date)
    sunday = monday + timedelta(days=6)
    return sunday.replace(hour=23, minute=59, second=59, microsecond=999999)




def get_custom_field_value(custom_fields, field_name):
    """Extract custom field value from Clockify userCustomFieldValues list.

    The member-profile endpoint returns custom fields in this format:
    {
        "userCustomFieldValues": [
            {
                "customFieldId": "...",
                "customField": {
                    "name": "Practice Alignment",
                    ...
                },
                "value": "Professional Services"
            }
        ]
    }
    """
    if not custom_fields or not isinstance(custom_fields, list):
        return None

    for field in custom_fields:
        # Handle member-profile format (nested customField object)
        custom_field_obj = field.get('customField', {})
        name = custom_field_obj.get('name') or field.get('name')
        if name == field_name:
            value = field.get('value')
            # Boolean toggles return Python True/False — return as-is
            if isinstance(value, bool):
                return value
            # Strip Clockify JSON formatting: {Bravo} -> Bravo, {"Free Agent"} -> Free Agent
            if value and isinstance(value, str):
                value = value.replace('{', '').replace('}', '').replace('"', '').replace('\\', '').strip()
            return value or None

    return None


def get_last_import_date(db: Session, category: str) -> datetime:
    """Get the last successful import date for a category."""
    last_log = db.query(ImportLog).filter(
        ImportLog.import_category == category,
        ImportLog.status == 'success'
    ).order_by(ImportLog.completed_at.desc()).first()

    if last_log and last_log.end_date:
        return last_log.end_date
    return None


def create_import_log(db: Session, import_type: str, category: str, start_date: datetime = None, end_date: datetime = None):
    """Create an import log entry."""
    log = ImportLog(
        import_type=import_type,
        import_category=category,
        start_date=start_date,
        end_date=end_date,
        started_at=datetime.now()
    )
    db.add(log)
    db.flush()
    return log


def complete_import_log(db: Session, log: ImportLog, imported: int, updated: int, skipped: int, status: str = 'success', error: str = None):
    """Complete an import log entry."""
    log.records_imported = imported
    log.records_updated = updated
    log.records_skipped = skipped
    log.status = status
    log.error_message = error
    log.completed_at = datetime.now()
    db.commit()


def import_users(db: Session, client: ClockifyClient):
    """Import users from Clockify with ALL custom fields using member-profile endpoint.

    Fetches both workspace-active and workspace-inactive users to maintain
    complete records and properly track user status changes over time.
    """
    print("\n📥 Importing users...")

    log = create_import_log(db, 'incremental', 'users')

    try:
        imported_count = 0
        updated_count = 0
        skipped_count = 0

        # Fetch workspace-active users first, then workspace-inactive users
        # The 'status' parameter filters by WORKSPACE membership status, not account status
        for workspace_status in ["ACTIVE", "INACTIVE"]:
            db_status = "active" if workspace_status == "ACTIVE" else "inactive"
            print(f"  Fetching {workspace_status.lower()} workspace members...")

            users = client.get_users(membership_status=workspace_status)
            print(f"  Found {len(users)} {workspace_status.lower()} users")

            for user_data in users:
                user_id = user_data["id"]

                # Extract name with fallback
                name = user_data.get("name")
                email = user_data.get("email")

                # Handle missing name - use email username as fallback
                if not name or name.strip() == "":
                    if email:
                        # Extract username from email (part before @)
                        name = email.split("@")[0].replace(".", " ").title()
                        print(f"  ⚠️  User {email} has no name, using '{name}' from email")
                    else:
                        # Skip users with no name and no email
                        print(f"  ⚠️  Skipping user with ID {user_id} - no name or email")
                        skipped_count += 1
                        continue

                # Fetch member profile to get custom fields
                try:
                    profile = client.get_user_profile(user_id)
                    custom_fields = profile.get("userCustomFieldValues", [])
                except Exception as e:
                    print(f"  ⚠️  Could not fetch profile for {name}: {e}")
                    custom_fields = []

                # Extract daily capacity from standard workCapacity field (ISO-8601 duration)
                work_capacity_raw = profile.get("workCapacity")
                daily_capacity = parse_iso8601_duration_hours(work_capacity_raw)

                # Extract custom field values from Clockify
                practice_alignment = get_custom_field_value(custom_fields, "Practice Alignment")
                skill_area = get_custom_field_value(custom_fields, "Skill Area")
                pod_assignment = get_custom_field_value(custom_fields, "POD Assignment")
                cloudelligent_title = get_custom_field_value(custom_fields, "Cloudelligent Title")
                location = get_custom_field_value(custom_fields, "Location")
                employment_designation = get_custom_field_value(custom_fields, "Employment Designation")
                time_submission = get_custom_field_value(custom_fields, "Time Submission")
                level = get_custom_field_value(custom_fields, "Level")
                user = ClockifyUser(
                    clockify_user_id=user_id,
                    name=name.strip(),
                    email=email,
                    daily_capacity=daily_capacity,
                    practice_alignment=practice_alignment,
                    skill_area=skill_area,
                    pod_assignment=pod_assignment,
                    cloudelligent_title=cloudelligent_title,
                    location=location or "Unknown",
                    employment_designation=employment_designation or "FTE",
                    time_submission=time_submission,
                    level=level,
                    status=db_status  # Based on workspace membership status
                )

                # Upsert
                existing = db.query(ClockifyUser).filter_by(
                    clockify_user_id=user.clockify_user_id
                ).first()

                if existing:
                    existing.name = user.name
                    existing.email = user.email
                    existing.daily_capacity = user.daily_capacity
                    existing.practice_alignment = user.practice_alignment
                    existing.skill_area = user.skill_area
                    existing.pod_assignment = user.pod_assignment
                    existing.cloudelligent_title = user.cloudelligent_title
                    existing.location = user.location
                    existing.employment_designation = user.employment_designation
                    existing.time_submission = user.time_submission
                    existing.level = user.level
                    existing.status = user.status
                    existing.updated_at = datetime.now()
                    updated_count += 1
                else:
                    db.add(user)
                    imported_count += 1

        db.commit()

        if skipped_count > 0:
            print(f"✓ Imported {imported_count} new users, updated {updated_count} existing, skipped {skipped_count}")
        else:
            print(f"✓ Imported {imported_count} new users, updated {updated_count} existing")

        complete_import_log(db, log, imported_count, updated_count, skipped_count)

    except Exception as e:
        complete_import_log(db, log, 0, 0, 0, 'failed', str(e))
        raise


def import_projects(db: Session, client: ClockifyClient):
    """Import projects from Clockify with client names."""
    print("\n📥 Importing projects...")

    log = create_import_log(db, 'incremental', 'projects')

    try:
        # Fetch clients first to build a lookup map
        clients = client.get_clients()
        client_map = {c["id"]: c["name"] for c in clients}
        print(f"  Found {len(client_map)} clients")

        projects = client.get_projects()
        imported_count = 0
        updated_count = 0

        # Collect all unique custom field names/values seen across all projects for debugging
        all_custom_field_names = {}  # field_name -> set of non-null values
        for proj_data in projects:
            for cf in proj_data.get("customFields", []):
                cf_obj = cf.get("customField", {})
                name = cf_obj.get("name") or cf.get("name") or "unknown"
                value = cf.get("value")
                if value:
                    all_custom_field_names.setdefault(name, set()).add(str(value)[:50])
        if all_custom_field_names:
            print("  Project custom fields found:")
            for fname, vals in sorted(all_custom_field_names.items()):
                sample = ", ".join(sorted(vals)[:5])
                print(f"    '{fname}': {sample}")
        else:
            print("  No project custom fields found in API response")

        for proj_data in projects:
            # Get client name from the client map
            client_id = proj_data.get("clientId")
            client_name = client_map.get(client_id) if client_id else None

            # Read project-level custom fields (Clockify uses "customFields" key for projects)
            proj_custom_fields = proj_data.get("customFields", [])
            pod_assignment = get_custom_field_value(proj_custom_fields, "Pod Assignment")
            project_type = get_custom_field_value(proj_custom_fields, "Project Type")
            professional_services_type = get_custom_field_value(proj_custom_fields, "Professional Services Type")
            professional_services_phase = get_custom_field_value(proj_custom_fields, "Professional Services Phase")
            # Clockify boolean toggles return Python True (not the string "True")
            _ot = get_custom_field_value(proj_custom_fields, "Overtime")
            is_overtime = _ot is True or _ot == "True"
            _ps = get_custom_field_value(proj_custom_fields, "Presales")
            is_presales = _ps is True or _ps == "True"

            project = ClockifyProject(
                clockify_project_id=proj_data["id"],
                name=proj_data["name"],
                client_id=client_id,
                client_name=client_name,
                color=proj_data.get("color"),
                billable=proj_data.get("billable", True),
                archived=proj_data.get("archived", False),
                pod_assignment=pod_assignment,
                project_type=project_type,
                professional_services_type=professional_services_type,
                professional_services_phase=professional_services_phase,
                is_overtime=is_overtime,
                is_presales=is_presales,
            )

            # Upsert
            existing = db.query(ClockifyProject).filter_by(
                clockify_project_id=project.clockify_project_id
            ).first()

            if existing:
                existing.name = project.name
                existing.client_id = project.client_id
                existing.client_name = project.client_name
                existing.archived = project.archived
                existing.pod_assignment = project.pod_assignment
                existing.project_type = project.project_type
                existing.professional_services_type = project.professional_services_type
                existing.professional_services_phase = project.professional_services_phase
                existing.is_overtime = project.is_overtime
                existing.is_presales = project.is_presales
                updated_count += 1
            else:
                db.add(project)
                imported_count += 1

        db.commit()
        print(f"✓ Imported {imported_count} new projects, updated {updated_count} existing")

        complete_import_log(db, log, imported_count, updated_count, 0)

    except Exception as e:
        complete_import_log(db, log, 0, 0, 0, 'failed', str(e))
        raise


def import_time_entries(
    db: Session,
    client: ClockifyClient,
    weeks_back: int = None,
    incremental: bool = True
):
    """Import time entries with support for full and incremental loads.

    Args:
        db: Database session
        client: Clockify API client
        weeks_back: Number of weeks to import (None for incremental based on last import)
        incremental: If True, only import since last successful import
    """
    end_date = datetime.now()

    # Overlap window (B-1): even on incremental runs, always re-pull the last
    # N complete weeks so retroactive Clockify edits and late NB-checkbox toggles
    # to earlier weeks flow through. Upserts on clockify_entry_id make this safe
    # (no duplicates). 4 weeks matches the project's existing "recent window".
    OVERLAP_WEEKS = 4

    # Determine import mode and date range
    if incremental and weeks_back is None:
        # Incremental mode: start from the LESSER of the last watermark and the
        # overlap floor, so edits within the overlap window are always re-pulled.
        last_import = get_last_import_date(db, 'time_entries')
        overlap_floor = end_date - timedelta(weeks=OVERLAP_WEEKS)
        if last_import:
            start_date = min(last_import, overlap_floor)
            import_type = 'incremental'
            print(f"\n📥 Importing time entries (incremental since {start_date.strftime('%Y-%m-%d')}, "
                  f"overlap={OVERLAP_WEEKS}w, watermark was {last_import.strftime('%Y-%m-%d')})...")
        else:
            # No previous import found, do initial 1 year load
            start_date = end_date - timedelta(days=365)
            import_type = 'full'
            print(f"\n📥 Importing time entries (initial full load - 1 year)...")
    elif weeks_back:
        # Specific weeks back requested (for ad-hoc or initial load)
        start_date = end_date - timedelta(weeks=weeks_back)
        import_type = 'full' if weeks_back >= 52 else 'adhoc'
        print(f"\n📥 Importing time entries (last {weeks_back} weeks)...")
    else:
        # Default to 4 weeks if nothing specified
        start_date = end_date - timedelta(weeks=4)
        import_type = 'adhoc'
        print(f"\n📥 Importing time entries (last 4 weeks)...")
    
    log = create_import_log(db, import_type, 'time_entries', start_date, end_date)

    try:
        # Get all active users only (skip inactive ones for time entry import)
        users = db.query(ClockifyUser).filter_by(status='active').all()
        total_imported = 0
        total_updated = 0
        failed_users = []  # B-3: track users whose fetch/import failed

        print(f"  Processing {len(users)} active users...")

        # Cache task names per project to avoid repeated API calls
        # {project_id: {task_id: task_name}}
        task_cache: dict = {}

        for user in users:
            print(f"  Fetching entries for {user.name}...")

            try:
                entries = client.get_time_entries(
                    user_id=user.clockify_user_id,
                    start_date=start_date,
                    end_date=end_date
                )

                for entry_data in entries:
                    # Calculate duration
                    start_time = datetime.fromisoformat(entry_data["timeInterval"]["start"].replace("Z", "+00:00"))
                    end_time_data = entry_data["timeInterval"].get("end")

                    if not end_time_data:
                        # Skip running time entries
                        continue

                    end_time = datetime.fromisoformat(end_time_data.replace("Z", "+00:00"))
                    duration_hours = round((end_time - start_time).total_seconds() / 3600, 2)

                    # Get project info
                    project_id = entry_data.get("projectId")
                    project = db.query(ClockifyProject).filter_by(
                        clockify_project_id=project_id
                    ).first() if project_id else None

                    # Resolve task name from taskId
                    task_id = entry_data.get("taskId")
                    task_name = None
                    if task_id and project_id:
                        if project_id not in task_cache:
                            try:
                                tasks = client._make_request(
                                    "GET",
                                    f"/workspaces/{client.workspace_id}/projects/{project_id}/tasks",
                                    params={"page-size": 200}
                                )
                                task_cache[project_id] = {t["id"]: t["name"] for t in tasks if isinstance(t, dict)}
                            except Exception:
                                task_cache[project_id] = {}
                        task_name = task_cache[project_id].get(task_id)

                    local_time = start_time.astimezone(_CST)
                    entry_date = local_time.date()
                    week_start = get_monday_of_week(local_time).date()

                    # Extract time-entry-level custom fields
                    te_custom_fields = entry_data.get("customFieldValues", [])
                    is_nb_productive = get_custom_field_value(te_custom_fields, "Non Bill Productive")
                    is_nb_non_productive = get_custom_field_value(te_custom_fields, "Non Bill Non Productive")

                    # Denormalize ALL user custom fields into time entry
                    entry = ClockifyTimeEntry(
                        clockify_entry_id=entry_data["id"],
                        clockify_user_id=user.clockify_user_id,
                        user_name=user.name,
                        practice_alignment=user.practice_alignment,
                        skill_area=user.skill_area,
                        pod_assignment=user.pod_assignment,
                        cloudelligent_title=user.cloudelligent_title,
                        location=user.location,
                        employment_designation=user.employment_designation,
                        clockify_project_id=project_id,
                        project_name=project.name if project else "No Project",
                        client_name=project.client_name if project else None,
                        task_name=task_name,
                        description=entry_data.get("description"),
                        billable=entry_data.get("billable", True),
                        duration_hours=duration_hours,
                        start_time=start_time,
                        end_time=end_time,
                        entry_date=entry_date,
                        week_start=week_start,
                        is_nb_productive=bool(is_nb_productive) if is_nb_productive is not None else False,
                        is_nb_non_productive=bool(is_nb_non_productive) if is_nb_non_productive is not None else False,
                    )

                    # Upsert
                    existing = db.query(ClockifyTimeEntry).filter_by(
                        clockify_entry_id=entry.clockify_entry_id
                    ).first()

                    if existing:
                        # Update existing entry with latest data
                        existing.user_name = entry.user_name
                        existing.practice_alignment = entry.practice_alignment
                        existing.skill_area = entry.skill_area
                        existing.pod_assignment = entry.pod_assignment
                        existing.cloudelligent_title = entry.cloudelligent_title
                        existing.location = entry.location
                        existing.employment_designation = entry.employment_designation
                        existing.project_name = entry.project_name
                        existing.client_name = entry.client_name
                        existing.task_name = entry.task_name
                        existing.description = entry.description
                        existing.billable = entry.billable
                        existing.duration_hours = entry.duration_hours
                        existing.week_start = entry.week_start
                        existing.is_nb_productive = entry.is_nb_productive
                        existing.is_nb_non_productive = entry.is_nb_non_productive
                        existing.synced_at = datetime.now()
                        total_updated += 1
                    else:
                        db.add(entry)
                        total_imported += 1

                db.commit()

            except Exception as e:
                # B-3: do NOT silently swallow. Record the failed user so the run
                # can be marked partial and the watermark is NOT advanced past the gap.
                print(f"  ⚠️  Error fetching entries for {user.name}: {str(e)}")
                db.rollback()  # discard this user's partial writes; keep prior users' commits
                failed_users.append(user.name)
                continue

        print(f"✓ Imported {total_imported} new time entries, updated {total_updated} existing")
        if failed_users:
            print(f"⚠️  {len(failed_users)} user(s) FAILED to import: {', '.join(failed_users[:20])}"
                  + (" …" if len(failed_users) > 20 else ""))

        # B-3: if any user failed, mark the run 'partial' (NOT 'success'). Because
        # get_last_import_date() filters status='success', a partial run does NOT
        # become the watermark → the next run re-pulls from the last complete window.
        if failed_users:
            complete_import_log(
                db, log, total_imported, total_updated, 0,
                status='partial',
                error=f"{len(failed_users)} user(s) failed: {', '.join(failed_users)}"[:2000],
            )
        else:
            complete_import_log(db, log, total_imported, total_updated, 0)

        return {
            'imported': total_imported,
            'updated': total_updated,
            'failed_users': failed_users,
            'status': 'partial' if failed_users else 'success',
        }

    except Exception as e:
        complete_import_log(db, log, 0, 0, 0, 'failed', str(e))
        raise


def run_import(weeks_back: int = None, incremental: bool = True):
    """Run data import with configurable options.

    Args:
        weeks_back: Number of weeks to import (None for auto-detect based on incremental)
        incremental: If True, auto-detect and only import new data since last import
    """
    print("=" * 60)
    if incremental and weeks_back is None:
        print("🚀 Starting Incremental Clockify Data Import")
    elif weeks_back and weeks_back >= 52:
        print("🚀 Starting Full Clockify Data Import (1 year)")
    else:
        print(f"🚀 Starting Clockify Data Import ({weeks_back or 'auto'} weeks)")
    print("=" * 60)

    db = SessionLocal()
    client = ClockifyClient()

    te_summary = {'imported': 0, 'updated': 0, 'failed_users': [], 'status': 'success'}
    try:
        import_users(db, client)
        import_projects(db, client)
        te_summary = import_time_entries(db, client, weeks_back=weeks_back, incremental=incremental) or te_summary

        print("\n" + "=" * 60)
        if te_summary.get('failed_users'):
            print(f"⚠️  Data import completed with PARTIAL failures: "
                  f"{len(te_summary['failed_users'])} user(s) failed")
        else:
            print("✅ Data import completed successfully!")
        print("=" * 60)
        return te_summary

    except Exception as e:
        # B-3: a hard failure (users/projects import, or unexpected) must NOT be
        # swallowed as success — roll back and re-raise so the pipeline marks ERROR.
        print(f"\n❌ Import failed: {str(e)}")
        import traceback
        traceback.print_exc()
        db.rollback()
        raise
    finally:
        db.close()


def run_full_import():
    """Run complete initial data import (1 year)."""
    run_import(weeks_back=52, incremental=False)


def run_incremental_import():
    """Run incremental import (only new data since last import)."""
    run_import(weeks_back=None, incremental=True)


if __name__ == "__main__":
    run_full_import()
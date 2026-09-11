#!/usr/bin/env python3
"""
Generate a TEST forecast Excel file in the exact WIDE format that
src/integrations/forecast_parser.py :: parse_forecast_template expects.

Uses REAL users + a REAL client/projects pulled from the dev DB so the
import (import_forecasts_from_template) does NOT reject the rows
(rows for users not found in clockify_users are silently dropped).

Layout produced (matches the parser's auto-detection):
  Row 0: week date headers (real datetimes) aligned over each "Plan" column
  Row 1: week labels (Week1, Week2, ...)
  Row 2: header row -> Client | Project | Comments | Type | PM | Stage | User | (Plan|Actual)*N
  Row 3+: data rows (hours under each Plan column)
"""
from datetime import datetime, timedelta
from openpyxl import Workbook

# Verified real data (from dev DB, account 604775478093)
CLIENT = "A2Z"
# (project_name, user_name, project_type)  users confirmed present in clockify_users
ROWS = [
    ("Managed Cloud", "anwar.hassan",    "Managed Cloud Services"),
    ("FinOps",        "amara.khan",      "AI/ML"),
    ("Managed Cloud", "ahmad.mudassir",  "Migration"),
    ("FinOps",        "Ahmed Alam Khan", "Migration"),
]
PM_NAME = "Test PM"
STAGE = "Build and Implement"
WEEKS_FORWARD = 4
HOURS_PER_WEEK = 20.0


def monday_of_this_week() -> datetime:
    d = datetime.now()
    return (d - timedelta(days=d.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)


def build(path: str):
    start = monday_of_this_week()
    weeks = [start + timedelta(weeks=i) for i in range(WEEKS_FORWARD)]

    wb = Workbook()
    ws = wb.active
    ws.title = "Forecast"

    # Fixed metadata columns (0-indexed): Client=0 Project=1 Comments=2 Type=3 PM=4 Stage=5 User=6
    # Weekly columns start at index 7: each week -> [Plan, Actual]
    META = ["Client", "Project", "Comments", "Type", "PM", "Stage", "User"]
    first_week_col = len(META)  # 7

    # Row 0: week date headers (real datetimes over each Plan column)
    row0 = [None] * first_week_col
    for w in weeks:
        row0.append(w)      # Plan column carries the date
        row0.append(None)   # Actual column
    ws.append(row0)

    # Row 1: week labels
    row1 = [None] * first_week_col
    for i in range(WEEKS_FORWARD):
        row1.append(f"Week{i+1}")
        row1.append(None)
    ws.append(row1)

    # Row 2: header row
    header = list(META)
    for _ in weeks:
        header.append("Plan")
        header.append("Actual")
    ws.append(header)

    # Data rows
    for project, user, ptype in ROWS:
        row = [CLIENT, project, "", ptype, PM_NAME, STAGE, user]
        for _ in weeks:
            row.append(HOURS_PER_WEEK)  # Plan hours
            row.append(0)               # Actual
        ws.append(row)

    wb.save(path)
    print("Wrote " + path)
    print("  Client: " + CLIENT)
    print("  Weeks : " + ", ".join(w.strftime('%Y-%m-%d') for w in weeks))
    print("  Rows  : %d users x %d weeks = %d entries" % (len(ROWS), WEEKS_FORWARD, len(ROWS) * WEEKS_FORWARD))
    print("  Hours : %.0f/week each -> %.0f total" % (HOURS_PER_WEEK, len(ROWS) * WEEKS_FORWARD * HOURS_PER_WEEK))


if __name__ == "__main__":
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else "test_forecast_A2Z.xlsx"
    build(out)

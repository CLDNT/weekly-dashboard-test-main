# Weekly Reporting Platform — Architecture Modernization

**Prepared for:** Chief Operating Officer
**Date:** September 2026
**Status:** Proposed — awaiting approval to proceed

---

## 1. Executive Summary

We are modernizing how Cloudelligent's weekly reporting data moves from source systems (Clockify, Jira) to the executive dashboards in QuickSight. The goal is to replace a single fragile program with a reliable, cost-efficient pipeline that the team can trust every Monday morning.

**What changes:** the automated data plumbing underneath the dashboards.
**What does not change:** the dashboards themselves, the data sources, or anyone's workflow.

---

## 2. Why We Are Doing This

The current system has a single point of failure — one 2,000-line program that handles 30 different jobs. When any part of it breaks, reporting can go dark without warning. Specific problems we've experienced:

- **Stale dashboards with no alert.** Two weeks of blank tiles on the Practice Scorecard and Staff Detail sheets went unnoticed because no notification fires when SPICE refreshes are missed.
- **~35% background error rate.** Core imports succeed, but downstream steps (QuickSight refresh, view updates) fail silently.
- **No reprocessability.** If a number looks wrong on a past week, we have to re-pull from Clockify/Jira — we don't keep the raw data.
- **Single-AZ database.** One availability zone failure means the entire reporting stack is down.

These gaps directly affect the COO OKRs:

| OKR | Impact |
|-----|--------|
| KR5.1 — 95% data hygiene, real-time CEO/COO visibility | Stale dashboards and silent failures break both hygiene and visibility. |
| KR2.1 / KR2.4 — On-time delivery rate, Red < 10% | If the Jira refresh fails silently, project health numbers are stale and untrustworthy. |

---

## 3. The New Architecture (What the Diagram Shows)

The diagram shows the **automated weekly data pipeline** — the path that data travels from source systems to dashboards every Monday.

### How to read it, left to right:

1. **Scheduled triggers** — EventBridge fires automatically: weekly Monday import, daily Jira refresh, monthly full sync. No human presses a button.

2. **Parallel extraction** — Clockify and Jira are pulled at the same time by two small, independent Lambdas. If Jira has an outage, the Clockify import still succeeds — the failure is isolated, not system-wide.

3. **Raw data preserved** — every pull is saved as immutable, versioned JSON in S3. This is our permanent audit trail. Any past week can be reprocessed without re-calling external APIs.

4. **Transform and compute** — one step cleans the raw data, computes KPIs (utilization, compliance, project health scores), and writes curated Parquet files to the data lake.

5. **Query layer** — Glue catalogs the data; Athena provides serverless SQL. No database to manage or keep online.

6. **Dashboard refresh** — QuickSight SPICE datasets are refreshed automatically. If the refresh fails, the pipeline sends a notification — not silence.

7. **Notifications at every terminal state** — success, partial success (data landed but SPICE failed), or failure. We will *know* when something is wrong.

### Step Functions orchestrates the whole sequence

The pipeline is not a loose collection of scripts. AWS Step Functions manages the control flow:

- Parallel extract → check results → transform → refresh → notify.
- Built-in retry with exponential backoff on transient errors.
- If extraction fails, the pipeline stops and notifies — it does not proceed with stale data.

### Migration is phased, not a switch flip

| Phase | What happens | Risk |
|-------|-------------|------|
| Phase 1 | New pipeline runs in parallel with the old system. Both write; we compare numbers. | Zero — old system continues to serve dashboards. |
| Phase 2 | Athena query layer validates against RDS views. | Mismatch caught before cutover. |
| Phase 3 | QuickSight reads from Athena instead of RDS. | Dashboards served by new path; old path still running as fallback. |
| Phase 4 | Old RDS database decommissioned (kept 2 weeks as safety net). | Fully reversible for 2 weeks. |

---

## 4. What the Diagram Covers

| Component | In scope | Source |
|-----------|----------|--------|
| Clockify time entry import | ✅ | Clockify API → S3 raw → curated → Athena → QuickSight |
| Jira project health import | ✅ | Jira API → S3 raw → curated → Athena → QuickSight |
| KPI snapshots (utilization, compliance, on-time delivery) | ✅ | Computed in transform step |
| EventBridge scheduling | ✅ | All triggers shown |
| Failure notifications | ✅ | SNS for all terminal states |
| QuickSight SPICE refresh | ✅ | Final step in pipeline |

---

## 5. What the Diagram Does NOT Cover (and Why)

Three components of the reporting platform are **intentionally excluded** from this diagram. They are real, they are in production, and they will continue to work. They are excluded because each one has **open design questions** that must be resolved before we can draw the target state.

### 5.1 Resource Forecast (Excel Upload)

**What it is:** A human-prepared Excel workbook with per-person, per-week forecasted hours. Uploaded through the Streamlit app, parsed, and written directly to the RDS database. Feeds the capacity planning view on the COO Operational dashboard.

**Why it's not in the diagram — open questions:**

| # | Question | Options | Impact |
|---|----------|---------|--------|
| 1 | Should forecasts move into the S3 data lake? | **A.** Yes — raw xlsx in `raw/forecasts/`, transformed to Parquet in `curated/`. This gives us version history (every upload preserved), enables forecast-vs-actual in Athena, and lets us fully decommission RDS. **B.** No — keep in RDS for interactive editing capability. | If A: RDS can be fully retired (cost saving). If B: RDS stays alive solely for forecast, which undermines the "kill the database" story. |
| 2 | Are forecasts ever edited row-by-row in the Streamlit app, or only bulk-uploaded as completed sheets? | If bulk-only, the lake model works cleanly. If row-level edits exist, a database is the better fit for that workload. | Determines whether RDS is still needed post-migration. |
| 3 | Do we need historical forecast versions? | Today, each upload **deletes** the previous forecast for those weeks — prior versions are lost. If leadership ever asks "what did we forecast for August back in June?", we cannot answer. The lake model preserves every version automatically. | Audit trail and forecast accuracy tracking depend on this. |
| 4 | Should forecast upload trigger a pipeline step (transform + SPICE refresh), or remain a standalone manual action? | Today it's a Streamlit upload → direct DB write → no SPICE refresh. Users must manually trigger a dataset refresh for the forecast to appear in QuickSight. | If integrated, forecast data appears in dashboards within minutes of upload. If standalone, the manual refresh gap continues. |

**Recommendation:** Move to the lake (Option A for question 1), preserve versions, and add a small transform step triggered on upload. This enables forecast-vs-actual analysis, kills the RDS dependency, and gives leadership a historical audit trail. But this requires confirmation on question 2 before committing.

### 5.2 AI Project Health Analysis (Bedrock)

**What it is:** An Amazon Bedrock-powered analysis that reads Jira issue data and Clockify actuals, uses Claude to estimate per-person effort, and compares AI estimates against actual hours logged. Produces per-user and per-project analysis tables for both PS and MC categories. Results feed four QuickSight datasets (`ai-ps-analysis-by-user`, `ai-ps-analysis-by-project`, `ai-mc-analysis-by-user`, `ai-mc-analysis-by-project`).

**Why it's not in the diagram — open questions:**

| # | Question | Options | Impact |
|---|----------|---------|--------|
| 1 | Should AI analysis run as a step inside the weekly pipeline, or remain a separately-triggered mode? | **A.** Inside the pipeline (after transform, before QuickSight refresh). Guarantees fresh analysis every Monday. **B.** Separate trigger (current design). Allows on-demand re-runs but can go stale if no one triggers it. | If A: AI results are always current when the COO opens the dashboard Monday morning. If B: AI results may lag. |
| 2 | Should AI analysis read from the S3 data lake (curated Parquet) or continue reading from RDS? | If the pipeline moves to the lake, the AI step should read from the same curated data — otherwise it becomes the second reason (after forecast) to keep RDS alive. | Determines whether RDS can fully retire. |
| 3 | What is the Bedrock cost per weekly run, and is it within budget? | Current model uses Claude via the Converse API. Each weekly run processes all active PS + MC projects × assigned users. Cost depends on token volume. | Must be estimated before making it a mandatory pipeline step. |
| 4 | How is the accuracy of the AI estimates validated? | Today there is no feedback loop. The AI estimates are displayed alongside actuals but the model's accuracy is not tracked over time. | If the AI estimates are consistently wrong, they erode trust in the dashboard rather than building it. |

**Recommendation:** Move AI analysis into the pipeline as an optional step (runs after transform; skippable on failure without blocking dashboard refresh). Read from curated lake data. Add a simple accuracy tracking table. But we need a Bedrock cost estimate first.

### 5.3 Forecast-vs-Actual AI Analysis

**What it is:** A separate Bedrock analysis that compares PM-submitted forecasted hours against Clockify actuals to identify over/under-estimation patterns. Feeds the forecast accuracy improvement model documented in the forecast model improvement plan.

**Why it's not in the diagram — open questions:**

| # | Question | Options | Impact |
|---|----------|---------|--------|
| 1 | This depends on both the forecast data *and* the AI analysis. Until the forecast storage question (§5.1) and the AI integration question (§5.2) are resolved, the target architecture for this component cannot be drawn. | — | Blocked by §5.1 and §5.2 decisions. |
| 2 | The current forecast model uses a 3-signal weighted blend (historical hours 50%, Jira velocity 30%, PM forecast 20%). The improvement plan proposes PM accuracy tracking, story-point-based velocity, and recency-weighted history. Should the new pipeline implement the improved model, or carry over the current one? | | Determines scope of the transform step. |

---

## 6. Key Benefits of the New Architecture

| Benefit | Current state | Target state |
|---------|--------------|--------------|
| **Reliability** | Single monolith — one bug takes down everything. ~35% background error rate. No failure notification. | Isolated steps — Jira failure doesn't block Clockify. Built-in retry. Automatic SNS alerts on any failure. |
| **Audit trail** | No raw data retained. Cannot reprocess past weeks without re-calling APIs. | Every raw extract preserved permanently in S3. Any week reprocessable from stored data. |
| **Cost** | Always-on RDS database + VPC-attached Lambda. 47 SPICE datasets (many unused). | Serverless everything — pay only when it runs. ~12 consolidated SPICE datasets. RDS retired (pending forecast/AI decisions). |
| **Dashboard freshness** | SPICE datasets can silently go stale for weeks (as happened with Practice Scorecard and Staff Detail). | Pipeline automatically refreshes SPICE and alerts on failure. |
| **Speed to change** | Any change touches a 2,000-line monolith and requires a full 19 MB redeployment. | Each Lambda is small and independently deployable. Adding a new data source is a new step, not surgery on existing code. |
| **Security** | One IAM role with broad permissions for the monolith. VPC data source with SSL disabled. | One role per Lambda, least-privilege. No VPC needed post-cutover. |

---

## 7. Cost Impact

The full cost comparison should be validated with AWS Pricing Calculator before commitment. Directional savings:

- **RDS retirement** — eliminates the always-on database cost (currently db.t3.micro, single-AZ). Only possible if forecast and AI questions (§5.1–§5.2) resolve in favor of the lake.
- **Lambda right-sizing** — four small Lambdas (~2 MB each) replacing one 19 MB monolith.
- **SPICE consolidation** — 47 datasets → ~12. Reduces SPICE storage costs and refresh time.
- **Athena** — pay per query (serverless); no provisioned capacity.

---

## 8. Decisions Needed

| # | Decision | Owner | Urgency | Depends on |
|---|----------|-------|---------|------------|
| 1 | Approve phased migration of the automated ingestion pipeline (the part the diagram covers). | COO | This sprint | — |
| 2 | Confirm: are forecasts bulk-uploaded or row-edited in Streamlit? | COO / Delivery Leads | Before Phase 3 | Determines whether RDS can retire |
| 3 | Confirm: should forecast uploads preserve version history? | COO | Before Phase 3 | Determines lake vs RDS for forecast |
| 4 | Confirm: should AI analysis run automatically as part of the Monday pipeline? | COO | Before Phase 2 | Bedrock cost estimate needed first |
| 5 | Confirm: target Bedrock model and acceptable cost per weekly run for AI analysis. | COO + Finance | Before Phase 2 | — |

---

## 9. Next Steps

1. **Immediate (approved):** Proceed with the automated pipeline migration (Phases 1–4) for Clockify + Jira + KPI data.
2. **Short-term:** Answer the five open questions above. Based on answers, update the diagram to include forecast, capacity planning, and AI analysis.
3. **Medium-term:** Implement the complete pipeline including all components; decommission the monolith and (if approved) the RDS database.

---

*This document accompanies the target architecture diagram in `docs/ingestion-architecture-diagrams.md`, Diagram 1 (Target Architecture — End-to-End).*

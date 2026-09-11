# Weekly Reporting — Ingestion Pipeline Architecture Diagrams

**Date:** 2026-08-28
**Account:** 961341524729 | **Region:** us-east-1
**Sources:** `docs/ingestion-pipeline-spec.md`, `docs/architecture-and-fixes-highlevel.md`

These diagrams show the **proposed ingestion pipeline** (Step Functions + single-responsibility Lambdas + S3 data lake + Glue/Athena) integrated into the **entire system architecture**, plus the migration/transition state and the current-vs-target comparison.

---

## 1. Target Architecture — End-to-End (Integrated View)

The complete proposed system: event triggers → Step Functions orchestration → extraction → data lake → query layer → QuickSight, with security and network boundaries called out.

```mermaid
flowchart TB
    %% ===== External sources =====
    subgraph EXT["External Data Sources"]
        CLOCKIFY["Clockify API<br/>(users, projects,<br/>time entries · hydrated=true)"]
        JIRA["Jira Cloud API<br/>(PS / MC / ESC issues<br/>+ custom fields)"]
    end

    %% ===== Triggers =====
    subgraph TRIG["Event Triggers (EventBridge)"]
        EB1["weekly-ingestion-monday-9am<br/>cron 0 14 ? * MON<br/>mode=incremental"]
        EB2["daily-jira-refresh<br/>cron 0 10 ? * MON-FRI"]
        EB3["monthly-full-sync<br/>cron 0 6 1 * ?<br/>mode=full, 12 wks"]
    end

    %% ===== Secrets =====
    SM["AWS Secrets Manager<br/>production/weekly-reporting/clockify"]

    %% ===== Orchestration =====
    subgraph SFN["Step Functions: WeeklyIngestionPipeline"]
        direction TB
        PAR{{"Parallel: ExtractData"}}
        CLK["clockify-import Lambda<br/>512MB · arm64 · 5min · No VPC<br/>role: clockify-import-role"]
        JR["jira-import Lambda<br/>256MB · arm64 · 3min · No VPC<br/>role: jira-import-role"]
        CHK{"CheckExtractionResults<br/>(Choice)"}
        TRF["transform-and-snapshot Lambda<br/>1024MB · arm64 · 5min · VPC (transition)<br/>pandas + pyarrow · role: transform-role"]
        QS["quicksight-refresh Lambda<br/>128MB · arm64 · 60s · No VPC<br/>role: quicksight-refresh-role"]
        NS["NotifySuccess"]
        NPS["NotifyPartialSuccess"]
        NF["NotifyFailure"]
    end

    SNS["SNS Topic<br/>weekly-reporting-notifications"]

    %% ===== Data lake =====
    subgraph LAKE["S3 Data Lake — s3://cdx-reporting-{env}/"]
        direction TB
        RAW["raw/  (immutable JSON, date-partitioned)<br/>clockify/users·projects·entries<br/>jira/issues<br/>· versioned · IA@30d · Glacier@90d"]
        CUR["curated/  (Parquet, Hive-partitioned)<br/>time_entries · users · projects<br/>jira_projects · kpi_snapshots"]
        AR["athena-results/  (7-day lifecycle)"]
    end

    %% ===== Query layer =====
    subgraph QLYR["Query Layer"]
        GLUE["Glue Data Catalog<br/>database: cdx_reporting<br/>Crawler: cron 30 14 ? * MON"]
        ATHENA["Athena (serverless SQL)<br/>Views: vw_weekly_time_summary,<br/>vw_resource_utilization, vw_project_health"]
    end

    %% ===== Serving =====
    QSIGHT["QuickSight (Athena data source · No VPC)<br/>~12 consolidated SPICE datasets<br/>3 dashboards: Executive, COO Operational, Detailed"]

    %% ===== Transition-only =====
    RDS["RDS PostgreSQL<br/>(transition write-back only,<br/>decommissioned after cutover)"]

    %% ===== Flows =====
    EB1 --> PAR
    EB2 --> JR
    EB3 --> PAR

    CLOCKIFY --> CLK
    JIRA --> JR
    SM -. GetSecretValue .-> CLK
    SM -. GetSecretValue .-> JR
    SM -. GetSecretValue .-> TRF

    PAR --> CLK
    PAR --> JR
    CLK --> CHK
    JR --> CHK
    CHK -->|both OK| TRF
    CHK -->|failed| NF

    CLK -- PutObject --> RAW
    JR -- PutObject --> RAW
    TRF -- GetObject --> RAW
    TRF -- PutObject --> CUR
    TRF -. write-back .-> RDS
    TRF --> QS
    QS -- CreateIngestion --> QSIGHT

    NS --> SNS
    NPS --> SNS
    NF --> SNS
    QS -->|ok| NS
    QS -->|refresh failed| NPS
    TRF -->|error| NF

    CUR --> GLUE
    GLUE --> ATHENA
    ATHENA --> AR
    ATHENA --> QSIGHT

    classDef ext fill:#ffe6cc,stroke:#d79b00,color:#000;
    classDef trig fill:#dae8fc,stroke:#6c8ebf,color:#000;
    classDef lambda fill:#d5e8d4,stroke:#82b366,color:#000;
    classDef store fill:#e1d5e7,stroke:#9673a6,color:#000;
    classDef serve fill:#fff2cc,stroke:#d6b656,color:#000;
    classDef transition fill:#f8cecc,stroke:#b85450,color:#000;

    class CLOCKIFY,JIRA ext;
    class EB1,EB2,EB3 trig;
    class CLK,JR,TRF,QS lambda;
    class RAW,CUR,AR,LAKE store;
    class QSIGHT,ATHENA,GLUE serve;
    class RDS transition;
```

---

## 2. Step Functions State Machine (Control Flow)

The orchestration logic in isolation — parallel extract, choice gate, sequential transform → refresh, and the three notification terminal states.

```mermaid
stateDiagram-v2
    [*] --> ExtractData

    state ExtractData {
        direction LR
        [*] --> ClockifyImport
        [*] --> JiraImport
        ClockifyImport --> [*]
        JiraImport --> [*]
    }

    ExtractData --> CheckExtractionResults

    state CheckExtractionResults <<choice>>
    CheckExtractionResults --> NotifyFailure: any extract FAILED
    CheckExtractionResults --> TransformAndSnapshot: both SUCCESS

    TransformAndSnapshot --> RefreshQuickSight: ok
    TransformAndSnapshot --> NotifyFailure: error (States.ALL)

    RefreshQuickSight --> NotifySuccess: ok
    RefreshQuickSight --> NotifyPartialSuccess: SPICE refresh failed

    NotifySuccess --> [*]
    NotifyPartialSuccess --> [*]
    NotifyFailure --> [*]

    note right of ExtractData
        Retry: ServiceException / TooManyRequests
        2 attempts, 30s, backoff x2
    end note
    note right of TransformAndSnapshot
        Retry: ServiceException
        1 attempt, 60s
    end note
```

---

## 3. Data Flow Through the Lake Layers

Shows how a single weekly run moves data from raw JSON to Parquet to Athena views to SPICE.

```mermaid
flowchart LR
    subgraph SRC["Extract"]
        A1["Clockify JSON<br/>users / projects / entries"]
        A2["Jira JSON<br/>issues + custom fields"]
    end

    subgraph RAW["raw/ (immutable JSON)"]
        R1["raw/clockify/*/YYYY/MM/DD/*.json"]
        R2["raw/jira/issues/YYYY/MM/DD/*.json"]
    end

    subgraph TRF["transform-and-snapshot"]
        T1["transform_users()"]
        T2["transform_entries()<br/>+ week_start partition<br/>+ user enrichment"]
        T3["transform_jira()"]
        T4["compute_kpi_snapshot()<br/>NB via is_nb_productive /<br/>is_nb_non_productive + capacity gap"]
    end

    subgraph CUR["curated/ (Parquet)"]
        C1["users/snapshot_date=…"]
        C2["time_entries/week_start=…"]
        C3["projects/snapshot_date=…"]
        C4["jira_projects/snapshot_date=…"]
        C5["kpi_snapshots/week_start=…"]
    end

    subgraph ATH["Glue + Athena Views"]
        V1["vw_weekly_time_summary"]
        V2["vw_resource_utilization"]
        V3["vw_project_health"]
    end

    QS["QuickSight SPICE<br/>~12 datasets → 3 dashboards"]

    A1 --> R1
    A2 --> R2
    R1 --> T1 & T2
    R2 --> T3
    T2 --> T4
    T1 --> T4
    T3 --> T4
    T1 --> C1
    T2 --> C2
    T1 --> C3
    T3 --> C4
    T4 --> C5
    C1 & C2 & C3 & C4 & C5 --> V1 & V2 & V3
    V1 & V2 & V3 --> QS
```

---

## 4. Current vs Target (Migration Context)

Side-by-side of the monolith being replaced and the target pipeline, and the transition period where both run in parallel.

```mermaid
flowchart TB
    subgraph CURRENT["CURRENT — Monolith (to be decommissioned)"]
        direction TB
        MC1["Clockify API"] --> MONO
        MC2["Jira Cloud"] --> MONO
        MONO["production-clockify-import<br/>2,034 lines · 30 modes · 19 MB · VPC"]
        MONO --> MRDS["RDS PostgreSQL<br/>single-AZ · 50+ SQL views"]
        MRDS -->|VPC data source, SSL off| MQS["QuickSight<br/>47 SPICE datasets"]
    end

    subgraph TARGET["TARGET — Ingestion Pipeline"]
        direction TB
        TC1["Clockify API"] --> TSFN
        TC2["Jira Cloud"] --> TSFN
        TSFN["Step Functions<br/>4 single-purpose Lambdas (~2 MB each)"]
        TSFN --> TS3["S3 Data Lake<br/>raw + curated (Parquet)"]
        TS3 --> TGA["Glue + Athena<br/>(no VPC)"]
        TGA --> TQS["QuickSight<br/>~12 SPICE datasets"]
    end

    CURRENT -. "Phase 1: parallel write & validate parity<br/>Phase 2: Athena layer<br/>Phase 3: QuickSight cutover<br/>Phase 4: decommission (RDS kept 2 wks)" .-> TARGET

    classDef old fill:#f8cecc,stroke:#b85450,color:#000;
    classDef new fill:#d5e8d4,stroke:#82b366,color:#000;
    class MONO,MRDS,MQS old;
    class TSFN,TS3,TGA,TQS new;
```

---

## 5. IAM / Security Boundaries

Least-privilege role-to-resource mapping for the pipeline.

```mermaid
flowchart LR
    subgraph ROLES["IAM Roles (one per Lambda)"]
        RCLK["clockify-import-role"]
        RJR["jira-import-role"]
        RTRF["transform-role"]
        RQS["quicksight-refresh-role"]
        RGLUE["GlueCrawlerRole"]
    end

    SMR["Secrets Manager<br/>production/weekly-reporting/*"]
    S3RAW["S3 raw/*"]
    S3CUR["S3 curated/*"]
    QSDS["QuickSight datasets/*"]
    CW["CloudWatch Logs"]

    RCLK -->|PutObject| S3RAW
    RCLK -->|GetSecretValue| SMR
    RJR -->|PutObject| S3RAW
    RJR -->|GetSecretValue| SMR
    RTRF -->|GetObject| S3RAW
    RTRF -->|PutObject| S3CUR
    RTRF -->|GetSecretValue| SMR
    RQS -->|CreateIngestion / Describe| QSDS
    RGLUE -->|GetObject / ListBucket| S3CUR

    RCLK & RJR & RTRF & RQS --> CW

    classDef role fill:#dae8fc,stroke:#6c8ebf,color:#000;
    classDef res fill:#e1d5e7,stroke:#9673a6,color:#000;
    class RCLK,RJR,RTRF,RQS,RGLUE role;
    class SMR,S3RAW,S3CUR,QSDS,CW res;
```

---

## Notes

- **VPC boundary:** Only `transform-and-snapshot` runs in a VPC, and only during the transition period for RDS KPI write-back. After cutover it becomes VPC-free — no Lambda needs a VPC, and the QuickSight read path has no VPC dependency at all.
- **NB classification** carries over into `transform-and-snapshot`: it reads the two Clockify checkbox custom fields (`is_nb_productive`, `is_nb_non_productive`) flattened from raw JSON, plus the per-user capacity gap for NB Non-Productive. The brace-formatting issue disappears structurally because transforms flatten clean values from raw JSON.
- **Reprocessability:** `raw/` is immutable and versioned, so any historical week can be re-transformed without re-calling Clockify/Jira.
- Diagrams are Mermaid — they render in GitHub, VS Code (with a Mermaid extension), and most Markdown viewers. To export as images, paste into [mermaid.live](https://mermaid.live) or use the Mermaid CLI.

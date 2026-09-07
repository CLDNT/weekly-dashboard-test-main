-- Migration 108: SPICE refresh verification log + freshness view (issue A-1 / A-3)
--
-- Why: refresh_quicksight_datasets() was fire-and-forget; the pipeline reported
-- SUCCESS regardless of whether SPICE ingestions actually completed. This table
-- records the VERIFIED terminal status of every dataset refresh so failures are
-- durable and a dashboard tile can show real SPICE freshness/health.
--
-- Safe to re-run (idempotent): CREATE TABLE IF NOT EXISTS + CREATE OR REPLACE VIEW.

CREATE TABLE IF NOT EXISTS spice_refresh_log (
    id              BIGSERIAL PRIMARY KEY,
    dataset_id      TEXT        NOT NULL,
    ingestion_id    TEXT,
    status          TEXT        NOT NULL,   -- COMPLETED | FAILED | CANCELLED | TIMEOUT | TRIGGER_FAILED | ALREADY_RUNNING | RUNNING
    rows_ingested   BIGINT,
    error_message   TEXT,
    refreshed_at    TIMESTAMP   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_spice_refresh_log_dataset_time
    ON spice_refresh_log (dataset_id, refreshed_at DESC);

-- Latest verified outcome per dataset, with a staleness flag and display string.
-- staleness: OK if a COMPLETED refresh in the last 26h, else STALE/FAILED.
CREATE OR REPLACE VIEW vw_spice_freshness AS
WITH latest AS (
    SELECT DISTINCT ON (dataset_id)
        dataset_id,
        status,
        rows_ingested,
        error_message,
        refreshed_at
    FROM spice_refresh_log
    ORDER BY dataset_id, refreshed_at DESC
)
SELECT
    dataset_id,
    status,
    rows_ingested,
    error_message,
    refreshed_at,
    TO_CHAR(refreshed_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Chicago',
            'Mon DD, YYYY HH12:MI AM') AS refreshed_display,
    CASE
        WHEN status = 'COMPLETED' AND refreshed_at > NOW() - INTERVAL '26 hours' THEN 'OK'
        WHEN status = 'COMPLETED' THEN 'STALE'
        ELSE 'FAILED'
    END AS health
FROM latest;

-- Single-row overall summary for a headline "Data as of / SPICE health" tile.
CREATE OR REPLACE VIEW vw_spice_freshness_summary AS
SELECT
    COUNT(*)                                              AS datasets_tracked,
    COUNT(*) FILTER (WHERE health = 'OK')                 AS datasets_ok,
    COUNT(*) FILTER (WHERE health = 'STALE')              AS datasets_stale,
    COUNT(*) FILTER (WHERE health = 'FAILED')             AS datasets_failed,
    MAX(refreshed_at) FILTER (WHERE status = 'COMPLETED') AS last_successful_refresh,
    TO_CHAR(MAX(refreshed_at) FILTER (WHERE status = 'COMPLETED')
            AT TIME ZONE 'UTC' AT TIME ZONE 'America/Chicago',
            'Mon DD, YYYY HH12:MI AM')                    AS last_successful_display
FROM vw_spice_freshness;

GRANT SELECT ON spice_refresh_log TO PUBLIC;
GRANT SELECT ON vw_spice_freshness TO PUBLIC;
GRANT SELECT ON vw_spice_freshness_summary TO PUBLIC;

-- The pipeline runs as report_user and must be able to WRITE refresh outcomes.
-- (The table is created by the master/superuser via run_migration, so grant
-- INSERT on the table and USAGE/SELECT on its identity sequence explicitly.)
GRANT INSERT, SELECT ON spice_refresh_log TO report_user;
GRANT USAGE, SELECT ON SEQUENCE spice_refresh_log_id_seq TO report_user;

-- Migration 109: freshness views treat SKIPPED_NOT_FOUND as SKIPPED, not FAILED (A-2/A-4)
--
-- Why: after A-2/A-4, datasets that don't exist in the current account are logged
-- as status='SKIPPED_NOT_FOUND' (a dataset legitimately absent in this env). These
-- must NOT inflate the "failed" count on the freshness tile — otherwise operators
-- get alarm fatigue and a real FAILED is masked (the exact A-4 problem). A real
-- FAILED / TIMEOUT / TRIGGER_FAILED still counts as failed.
--
-- Idempotent: CREATE OR REPLACE.

CREATE OR REPLACE VIEW vw_spice_freshness AS
WITH latest AS (
    SELECT DISTINCT ON (dataset_id)
        dataset_id, status, rows_ingested, error_message, refreshed_at
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
        WHEN status = 'SKIPPED_NOT_FOUND' THEN 'SKIPPED'
        ELSE 'FAILED'
    END AS health
FROM latest;

-- Summary view adds a new column (datasets_skipped) → the column set changes,
-- which CREATE OR REPLACE VIEW cannot do (Postgres 42P16). DROP then recreate.
DROP VIEW IF EXISTS vw_spice_freshness_summary;
CREATE VIEW vw_spice_freshness_summary AS
SELECT
    COUNT(*) FILTER (WHERE health <> 'SKIPPED')            AS datasets_tracked,
    COUNT(*) FILTER (WHERE health = 'OK')                  AS datasets_ok,
    COUNT(*) FILTER (WHERE health = 'STALE')               AS datasets_stale,
    COUNT(*) FILTER (WHERE health = 'FAILED')              AS datasets_failed,
    COUNT(*) FILTER (WHERE health = 'SKIPPED')             AS datasets_skipped,
    MAX(refreshed_at) FILTER (WHERE status = 'COMPLETED')  AS last_successful_refresh,
    TO_CHAR(MAX(refreshed_at) FILTER (WHERE status = 'COMPLETED')
            AT TIME ZONE 'UTC' AT TIME ZONE 'America/Chicago',
            'Mon DD, YYYY HH12:MI AM')                     AS last_successful_display
FROM vw_spice_freshness;

GRANT SELECT ON vw_spice_freshness TO PUBLIC;
GRANT SELECT ON vw_spice_freshness_summary TO PUBLIC;

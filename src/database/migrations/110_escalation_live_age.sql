-- Migration 110: escalation age computed LIVE, not at import time (issue C-5)
--
-- Why: vw_escalations selected escalations.days_open / days_to_resolve straight from
-- the base table, where they were frozen at import time. Between weekly imports the
-- escalation age was stale by up to 6 days. Compute live from dates instead.
--
-- days_open: for OPEN escalations = CURRENT_DATE - created_date; for resolved =
--            resolution_date - created_date (age at resolution, stays fixed).
-- days_to_resolve: resolution_date - created_date (NULL while unresolved).
--
-- Column order/names are preserved EXACTLY (only the two expressions change) so
-- CREATE OR REPLACE VIEW does not hit 42P16.

CREATE OR REPLACE VIEW vw_escalations AS
 SELECT escalations.issue_key,
    escalations.customer_name,
    escalations.epic_key,
    escalations.summary,
    escalations.description,
    escalations.status,
    escalations.status_category,
    escalations.priority,
        CASE escalations.priority
            WHEN 'Highest'::text THEN 1
            WHEN 'High'::text THEN 2
            WHEN 'Medium'::text THEN 3
            WHEN 'Low'::text THEN 4
            WHEN 'Lowest'::text THEN 5
            ELSE 6
        END AS priority_order,
    escalations.assignee_name,
    escalations.reporter_name,
    escalations.created_date::date AS created_date,
    escalations.updated_date::date AS updated_date,
    escalations.resolution_date::date AS resolution_date,
    escalations.status_changed_at::date AS status_changed_at,
    escalations.previous_status,
    -- C-5: live age. Resolved -> age at resolution (fixed); open -> age as of today.
    CASE
        WHEN escalations.resolution_date IS NOT NULL
            THEN (escalations.resolution_date::date - escalations.created_date::date)
        ELSE (CURRENT_DATE - escalations.created_date::date)
    END AS days_open,
    -- C-5: only defined once resolved.
    CASE
        WHEN escalations.resolution_date IS NOT NULL
            THEN (escalations.resolution_date::date - escalations.created_date::date)
        ELSE NULL::integer
    END AS days_to_resolve,
    EXTRACT(year FROM escalations.created_date)::integer AS created_year,
    EXTRACT(month FROM escalations.created_date)::integer AS created_month,
    to_char(escalations.created_date, 'YYYY-MM'::text) AS created_month_label,
        CASE
            WHEN escalations.status_category::text = 'Done'::text THEN 'Done'::text
            WHEN escalations.status::text = 'Watching'::text THEN 'Watching'::text
            WHEN escalations.status_category::text = 'In Progress'::text THEN 'In Progress'::text
            ELSE 'New'::text
        END AS escalation_state,
    escalations.created_date >= (CURRENT_DATE - '7 days'::interval) AS is_new,
    escalations.updated_date >= (CURRENT_DATE - '7 days'::interval) OR escalations.status_changed_at >= (CURRENT_DATE - '7 days'::interval) AS changed_last_week
   FROM escalations
  WHERE escalations.customer_name IS NOT NULL;

GRANT SELECT ON vw_escalations TO PUBLIC;

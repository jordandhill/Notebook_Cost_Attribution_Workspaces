-- ============================================================
-- Warehouse Pushdown Costs
-- Credits consumed by SQL/Snowpark queries pushed to warehouses
-- from notebooks running on Container Runtime
--
-- Notebooks in Workspaces do NOT emit query tags automatically. We
-- identify notebook sessions via the SESSIONS view, which auto-populates
-- CLIENT_ENVIRONMENT:APPLICATION = 'Snowflake Web App (snowsight_notebook)'.
-- That captures both Workspaces (PythonSnowpark client) and legacy
-- (Go client) notebooks. SESSION_ID bridges to QUERY_HISTORY, and
-- QUERY_ID bridges to QUERY_ATTRIBUTION_HISTORY for the credits.
-- ============================================================

-- Automatic: warehouse pushdown credits per user (no query tag required)
WITH notebook_sessions AS (
    SELECT DISTINCT session_id, user_name
    FROM snowflake.account_usage.sessions
    WHERE GET_PATH(PARSE_JSON(client_environment), 'APPLICATION')::VARCHAR
          = 'Snowflake Web App (snowsight_notebook)'
      AND created_on >= DATEADD(day, -30, CURRENT_TIMESTAMP())
)
SELECT
    ns.user_name,
    COUNT(DISTINCT qh.query_id) AS attributed_queries,
    SUM(qah.credits_attributed_compute) AS total_warehouse_credits,
    MIN(qh.start_time) AS first_execution,
    MAX(qh.end_time) AS last_execution,
    ARRAY_AGG(DISTINCT qah.warehouse_name) AS warehouses_used
FROM notebook_sessions ns
JOIN snowflake.account_usage.query_history qh
    ON qh.session_id = ns.session_id
    AND qh.start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
JOIN snowflake.account_usage.query_attribution_history qah
    ON qh.query_id = qah.query_id
GROUP BY ALL
ORDER BY total_warehouse_credits DESC;

-- ============================================================
-- Upgrade: per-notebook-name attribution
-- The query above attributes by USER, not by notebook name (the SESSIONS
-- view doesn't track which notebook file is open). For per-notebook
-- breakdown, set a query tag in the first cell of each notebook:
--
--   ALTER SESSION SET QUERY_TAG = '{"notebook": "my_analysis_notebook"}';
--
-- Then query_attribution_history carries the tag directly -- no join needed.
-- ============================================================
SELECT
    PARSE_JSON(query_tag):notebook::VARCHAR AS notebook_name,
    user_name,
    warehouse_name,
    COUNT(*) AS attributed_queries,
    SUM(credits_attributed_compute) AS total_warehouse_credits
FROM snowflake.account_usage.query_attribution_history
WHERE query_tag ILIKE '%"notebook"%'
  AND start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
GROUP BY ALL
ORDER BY total_warehouse_credits DESC;

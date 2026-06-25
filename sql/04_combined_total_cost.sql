-- ============================================================
-- Combined Total Cost Attribution
-- Merges Container Runtime + Warehouse Pushdown for full picture
--
-- Both dimensions key on USER_NAME for Workspaces notebooks:
--   * Container side is per-user (NOTEBOOK_NAME is NULL)
--   * Warehouse side comes from the automatic SESSIONS-based attribution
-- Each CTE aggregates to one row per user before joining, so no fanout.
-- ============================================================

WITH container_costs AS (
    SELECT
        user_name,
        SUM(credits) AS container_credits
    FROM snowflake.account_usage.notebooks_container_runtime_history
    WHERE start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
    GROUP BY ALL
),
notebook_sessions AS (
    SELECT DISTINCT session_id, user_name
    FROM snowflake.account_usage.sessions
    WHERE GET_PATH(PARSE_JSON(client_environment), 'APPLICATION')::VARCHAR
          = 'Snowflake Web App (snowsight_notebook)'
      AND created_on >= DATEADD(day, -30, CURRENT_TIMESTAMP())
),
warehouse_costs AS (
    SELECT
        ns.user_name,
        SUM(qah.credits_attributed_compute) AS warehouse_credits
    FROM notebook_sessions ns
    JOIN snowflake.account_usage.query_history qh
        ON qh.session_id = ns.session_id
        AND qh.start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
    JOIN snowflake.account_usage.query_attribution_history qah
        ON qh.query_id = qah.query_id
    GROUP BY ALL
)
SELECT
    COALESCE(c.user_name, w.user_name) AS user_name,
    COALESCE(c.container_credits, 0) AS container_runtime_credits,
    COALESCE(w.warehouse_credits, 0) AS warehouse_pushdown_credits,
    COALESCE(c.container_credits, 0) + COALESCE(w.warehouse_credits, 0) AS total_credits,
    CASE
        WHEN c.container_credits > 0 AND w.warehouse_credits > 0 THEN 'Hybrid (Container + Warehouse)'
        WHEN c.container_credits > 0 THEN 'Container Runtime Only'
        ELSE 'Warehouse Only'
    END AS runtime_type
FROM container_costs c
FULL OUTER JOIN warehouse_costs w
    ON c.user_name = w.user_name
ORDER BY total_credits DESC;

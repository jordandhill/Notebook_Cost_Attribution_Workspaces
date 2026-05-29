-- ============================================================
-- Combined Total Cost Attribution
-- Merges Container Runtime + Warehouse Pushdown for full picture
-- ============================================================

-- Full cost per notebook (both cost components)
WITH container_costs AS (
    SELECT
        notebook_name,
        user_name,
        SUM(credits) AS container_credits
    FROM snowflake.account_usage.notebooks_container_runtime_history
    WHERE start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
    GROUP BY ALL
),
notebook_query_tags AS (
    SELECT DISTINCT
        PARSE_JSON(query_tag):StreamlitName::VARCHAR AS notebook_name
    FROM snowflake.account_usage.query_history 
    WHERE query_text ILIKE 'execute notebook%'
      AND query_tag IS NOT NULL
      AND start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
),
warehouse_costs AS (
    SELECT 
        qt.notebook_name,
        qh.user_name,
        SUM(qah.credits_attributed_compute) AS warehouse_credits
    FROM snowflake.account_usage.query_history qh
    JOIN notebook_query_tags qt
        ON qh.query_tag ILIKE ('%' || qt.notebook_name || '%')
    LEFT JOIN snowflake.account_usage.query_attribution_history qah 
        ON qh.query_id = qah.query_id
    WHERE qh.start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
    GROUP BY ALL
)
SELECT
    COALESCE(c.notebook_name, w.notebook_name) AS notebook_name,
    COALESCE(c.user_name, w.user_name) AS user_name,
    COALESCE(c.container_credits, 0) AS container_runtime_credits,
    COALESCE(w.warehouse_credits, 0) AS warehouse_pushdown_credits,
    COALESCE(c.container_credits, 0) + COALESCE(w.warehouse_credits, 0) AS total_credits,
    CASE 
        WHEN c.container_credits > 0 AND w.warehouse_credits > 0 THEN 'Hybrid (Container + Warehouse)'
        WHEN c.container_credits > 0 THEN 'Container Runtime Only'
        ELSE 'Warehouse Runtime Only'
    END AS runtime_type
FROM container_costs c
FULL OUTER JOIN warehouse_costs w
    ON c.notebook_name = w.notebook_name AND c.user_name = w.user_name
ORDER BY total_credits DESC;

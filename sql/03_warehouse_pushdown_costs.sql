-- ============================================================
-- Warehouse Pushdown Costs
-- Credits consumed by SQL/Snowpark queries pushed to warehouses
-- from notebooks running on Container Runtime
-- ============================================================

-- Identify all notebook names from query tags
WITH notebook_query_tags AS (
    SELECT DISTINCT
        PARSE_JSON(query_tag):StreamlitName::VARCHAR AS notebook_name
    FROM snowflake.account_usage.query_history 
    WHERE query_text ILIKE 'execute notebook%'
      AND query_tag IS NOT NULL
      AND start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
),
-- Find ALL queries associated with each notebook
all_nb_queries AS (
    SELECT 
        qt.notebook_name,
        qh.query_id,
        qh.user_name,
        qh.warehouse_name,
        qh.start_time,
        qh.end_time,
        qh.execution_time,
        qh.query_type
    FROM snowflake.account_usage.query_history qh
    JOIN notebook_query_tags qt
    WHERE qh.query_tag ILIKE ('%' || qt.notebook_name || '%')
      AND qh.start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
)
-- Aggregate warehouse costs per notebook
SELECT 
    notebook_name,
    COUNT(*) AS total_queries,
    SUM(qah.credits_attributed_compute) AS total_warehouse_credits,
    MIN(nb.start_time) AS first_execution,
    MAX(nb.end_time) AS last_execution,
    ARRAY_AGG(DISTINCT nb.warehouse_name) AS warehouses_used,
    ARRAY_AGG(DISTINCT nb.user_name) AS users
FROM all_nb_queries nb
LEFT JOIN snowflake.account_usage.query_attribution_history qah 
    ON nb.query_id = qah.query_id
GROUP BY notebook_name
ORDER BY total_warehouse_credits DESC;

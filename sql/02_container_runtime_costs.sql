-- ============================================================
-- Container Runtime Costs
-- Credits consumed by the SPCS container running the notebook
-- This is the user-level compute (Python kernel, GPU/CPU)
-- ============================================================

-- Basic: All notebook container runtime costs (last 30 days)
SELECT
    notebook_name,
    user_name,
    compute_pool_name,
    SUM(credits) AS total_container_credits,
    SUM(notebook_execution_time_secs) AS total_execution_seconds
FROM snowflake.account_usage.notebooks_container_runtime_history
WHERE start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
GROUP BY ALL
ORDER BY total_container_credits DESC;

-- Hourly breakdown for a specific notebook
SELECT
    DATE_TRUNC('hour', start_time) AS hour,
    notebook_name,
    user_name,
    credits,
    notebook_execution_time_secs
FROM snowflake.account_usage.notebooks_container_runtime_history
WHERE notebook_name = '<YOUR_NOTEBOOK_NAME>'
  AND start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
ORDER BY hour DESC;

-- Cost by compute pool (identify expensive GPU pools)
SELECT
    compute_pool_name,
    COUNT(DISTINCT notebook_name) AS notebooks,
    COUNT(DISTINCT user_name) AS users,
    SUM(credits) AS total_credits,
    SUM(notebook_execution_time_secs) / 3600 AS total_hours
FROM snowflake.account_usage.notebooks_container_runtime_history
WHERE start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
GROUP BY compute_pool_name
ORDER BY total_credits DESC;

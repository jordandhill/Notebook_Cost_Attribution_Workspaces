# A Practical Guide to Snowflake Notebook Cost Attribution

No matter how mature your data platform is, someone on your team is going to ask the inevitable question: "How much this costing us?".  Best to have a ready-made answer for when that question arises.  Today we are talking Snowflake Notebooks, new and improved that is.

The shift to file-based Workspaces has unlocked a lot of great capabilities — Jupyter compatibility, Git integration, proper file and folder organization, and a much more flexible development environment. Everyone's moving. But here's the thing — the cost model is a bit more nuanced than what you're used to.

**The nuance:** Notebooks on Container Runtime have *two* billing dimensions. There's the container compute that runs your Python kernel — that's at the user level. And then there's the warehouse pushdown for your SQL and Snowpark queries. Without proper attribution, these costs become a black box.

**The solution:** Snowflake gives you everything you need to track both. Let me show you how.

## The Dual-Cost Model

When you run a Notebook in Workspaces on Container Runtime, your costs split across two dimensions:

```
┌─────────────────────────────────────────────────────────┐
│                   Notebook in Workspaces                 │
├────────────────────────┬────────────────────────────────┤
│  Container Runtime     │    Warehouse Pushdown          │
│  (SPCS Compute Pool)   │    (Virtual Warehouse)         │
├────────────────────────┼────────────────────────────────┤
│  • Python code         │    • SQL cells                 │
│  • ML training         │    • Snowpark push-down ops    │
│  • Local pandas/numpy  │    • session.table().filter()  │
│  • GPU workloads       │    • DataFrame.to_pandas()     │
│  • pip packages        │    • Any query execution       │
├────────────────────────┼────────────────────────────────┤
│  Billed per compute    │    Billed per warehouse        │
│  pool node-hour        │    credit-second               │
└────────────────────────┴────────────────────────────────┘
```

**Container Runtime** is billed at the user level. Each user gets their own node on the compute pool, and the credit rate depends on the machine type (CPU vs GPU). This shows up in the `notebooks_container_runtime_history` view.

**Warehouse Pushdown** queries are billed against the warehouse configured for the notebook. Even on Container Runtime, SQL cells and Snowpark push-down operations execute on the warehouse for optimal performance. These show up in `query_attribution_history` with notebook query tags.

Two cost dimensions. Two views. One unified picture. Let's build it.

## Understanding Notebook Query Tags

Every notebook execution creates queries tagged with JSON metadata that looks like this:

```json
{
  "StreamlitEngine": "ExecuteStreamlit",
  "StreamlitName": "MY_DATABASE.MY_SCHEMA.\"My Notebook\""
}
```

The `StreamlitName` field is your ticket — it contains the fully qualified notebook name (database.schema.notebook), which lets you trace all related queries back to their source.

**Protip:** This tagging format is the same whether you're on Legacy Notebooks or Notebooks in Workspaces. Your existing attribution queries will continue to work as you migrate. No problem.

Checkout [Snowflake's documentation on notebook usage monitoring](https://docs.snowflake.com/en/user-guide/ui-snowsight/notebooks-usage) for the full picture of what data you have at your disposal.

## Quick Caveats: What You Won't See

Before we dive in, a few things to know:

**1. Fast Queries Are Not Cost-Attributed.** Queries executing in under ~100ms won't appear in `query_attribution_history`. These consume negligible resources — don't worry about them.

**2. Idle Time Is Not Attributed.** Warehouse idle time between queries and compute pool idle time before auto-shutdown won't show up. Compute pools have a configurable `IDLE_AUTO_SHUTDOWN_TIME_SECONDS` (default: 1 hour, max: 72 hours).

**3. Attribution Latency.** This isn't real-time:
- `query_attribution_history`: up to 8 hours latency
- `notebooks_container_runtime_history`: up to 3 hours latency

**4. Container Runtime is Per-User.** Each compute pool node runs one notebook per user. Five users open the same notebook? That's five nodes. The `notebooks_container_runtime_history` view tracks this at the user level — which makes user-level attribution critical.

## Step 1: Track Container Runtime Costs

Query the `notebooks_container_runtime_history` view for the SPCS component:

```sql
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
```

And if you want to understand your GPU vs CPU cost distribution — especially useful when deciding if that expensive GPU pool is worth it:

```sql
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
```

That's the container side. Now let's get the warehouse side.

## Step 2: Track Warehouse Pushdown Costs

For the SQL and Snowpark queries that execute on the warehouse:

```sql
WITH notebook_query_tags AS (
    SELECT DISTINCT
        PARSE_JSON(query_tag):StreamlitName::VARCHAR AS notebook_name
    FROM snowflake.account_usage.query_history 
    WHERE query_text ILIKE 'execute notebook%'
      AND query_tag IS NOT NULL
      AND start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
),
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
```

**How this works:**
1. The first CTE identifies all notebooks by looking for `EXECUTE NOTEBOOK` queries and extracting `StreamlitName` from the query tag.
2. The second CTE finds all child queries containing that notebook name in their tags.
3. The final query joins with `query_attribution_history` to get the actual credit costs.

## Step 3: Combine Both Dimensions

Here's where it gets good. The real power comes from combining both cost components into a single unified view:

```sql
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
```

That `runtime_type` column at the end? Magic. Now you can immediately see which notebooks are running on Container Runtime (both costs), which are warehouse-only, and — most importantly — where the money's actually going.

## Step 4: Enhance with Object Tagging

For enterprise environments that need chargeback or showback — and let's be real, that's most of you — Snowflake's [object tagging](https://docs.snowflake.com/en/user-guide/object-tagging/introduction) adds another dimension:

```sql
CREATE TAG IF NOT EXISTS cost_center
    ALLOWED_VALUES 'data_science', 'data_engineering', 'analytics', 'ml_ops';

CREATE TAG IF NOT EXISTS team;
CREATE TAG IF NOT EXISTS project;

ALTER NOTEBOOK my_database.my_schema."My Notebook"
    SET TAG cost_center = 'data_science',
            team = 'recommendation_engine',
            project = 'Q2_model_refresh';
```

Tags support [inheritance and automatic propagation](https://docs.snowflake.com/en/user-guide/object-tagging/introduction#using-tags-to-monitor-resource-usage). Apply them at the notebook level and you've got multi-dimensional cost analysis across departments, projects, and business units. Your finance team will thank you.

## Step 5: Deploy the Streamlit Dashboard

SQL queries are powerful, but they require manual execution and lack visual context. For ongoing monitoring — and hey, who doesn't love a little Streamlit in Snowflake — I've built a cost attribution dashboard that provides:

- Unified view of Container Runtime + Warehouse Pushdown costs
- Interactive time-range filtering (7–90 days)
- Drill-down by notebook, user, or compute pool
- Daily trend visualization with cost-type breakdown
- CSV export for further analysis

### Quick Deployment

The dashboard code is available at: [https://github.com/jordandhill/Notebook_Cost_Attribution_Workspaces](https://github.com/jordandhill/Notebook_Cost_Attribution_Workspaces)

Upload the files and deploy on Container Runtime — all within Snowflake, no additional infrastructure required:

```sql
-- Create a stage and upload your files (Snow CLI)
CREATE STAGE IF NOT EXISTS my_db.my_schema.app_stage DIRECTORY = (ENABLE = TRUE);
-- snow stage copy streamlit_app.py  @my_db.my_schema.app_stage --overwrite
-- snow stage copy requirements.txt  @my_db.my_schema.app_stage --overwrite

-- (Optional) dedicated compute pool for the dashboard
CREATE COMPUTE POOL IF NOT EXISTS NOTEBOOK_COST_DASHBOARD_POOL
    MIN_NODES = 1
    MAX_NODES = 1
    INSTANCE_FAMILY = CPU_X64_XS
    AUTO_RESUME = TRUE
    AUTO_SUSPEND_SECS = 3600;

-- Deploy on Container Runtime
CREATE OR REPLACE STREAMLIT my_db.my_schema.notebook_cost_dashboard
    FROM '@my_db.my_schema.app_stage'
    MAIN_FILE = 'streamlit_app.py'
    RUNTIME_NAME = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
    COMPUTE_POOL = NOTEBOOK_COST_DASHBOARD_POOL
    QUERY_WAREHOUSE = COMPUTE_WH
    TITLE = 'Notebook Cost Attribution Dashboard';

-- Activate the app
ALTER STREAMLIT my_db.my_schema.notebook_cost_dashboard ADD LIVE VERSION FROM LAST;
```

That's it! The dashboard runs as a persistent shared server on Container Runtime — viewers share one app instance instead of spinning up per-user warehouse sessions. All within Snowflake.


## Conclusion

Snowflake Notebook cost attribution is crystal clear when you leverage:

1. **`notebooks_container_runtime_history`** for per-user container compute
2. **`query_attribution_history`** with notebook query tags for warehouse pushdown
3. **Object tags** for organizational cost allocation
4. **A Streamlit dashboard** for continuous monitoring

Start with the combined SQL query in Step 3, explore your cost distribution, and when you're ready for continuous monitoring, deploy the dashboard. As the migration from Legacy Notebooks accelerates and teams lean further into Workspaces, having this visibility from day one is critical.

Pat yourself on the back. You've just turned on the lights. Next time someone asks "How much is this costing us?" You are ready  💥

## Resources

- GitHub Repository: [Notebook_Cost_Attribution_Workspaces](https://github.com/jordandhill/Notebook_Cost_Attribution_Workspaces)
- Snowflake Docs: [Notebook Usage and Cost Monitoring](https://docs.snowflake.com/en/user-guide/ui-snowsight/notebooks-usage)
- Snowflake Docs: [Notebooks on Container Runtime](https://docs.snowflake.com/en/developer-guide/snowflake-ml/notebooks-on-spcs)
- Snowflake Docs: [NOTEBOOKS_CONTAINER_RUNTIME_HISTORY View](https://docs.snowflake.com/en/sql-reference/account-usage/notebooks_container_runtime_history)
- Snowflake Docs: [QUERY_ATTRIBUTION_HISTORY View](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)
- Snowflake Docs: [Object Tagging Introduction](https://docs.snowflake.com/en/user-guide/object-tagging/introduction)
- Snowflake Docs: [Migrating Legacy Notebooks to Workspaces](https://docs.snowflake.com/en/user-guide/ui-snowsight/notebooks-in-workspaces/notebooks-in-workspaces-migrate)

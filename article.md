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

**Container Runtime** is billed at the user level. Each user gets their own persistent service (named `<user>_SERVICE_N`) and node on the compute pool, and the credit rate depends on the machine type (CPU vs GPU). This shows up in the `notebooks_container_runtime_history` view. Note that for Workspaces notebooks, the `NOTEBOOK_NAME` column is **NULL** — because Workspaces notebooks are file-based rather than schema-level `NOTEBOOK` objects, container usage is tracked per **user and service**, not per notebook name.

**Warehouse Pushdown** queries are billed against the warehouse configured for the notebook. Even on Container Runtime, SQL cells and Snowpark push-down operations execute on the warehouse for optimal performance. These show up in `query_attribution_history`, which you can tie back to a notebook through the session client metadata (more on that next).

Two cost dimensions. Two views. One unified picture. Let's build it.

## Identifying Notebook Queries

Notebooks in Workspaces do **not** automatically emit query tags. Unlike some other Snowflake execution contexts (Cortex Code, Streamlit apps), queries run from a Workspaces notebook have an empty `QUERY_TAG` field. So how do you find them?

The answer is the `SNOWFLAKE.ACCOUNT_USAGE.SESSIONS` view. Every session automatically records its originating client in the `CLIENT_ENVIRONMENT` column, and notebook kernels populate it with a telltale value:

```json
{
  "APPLICATION": "Snowflake Web App (snowsight_notebook)",
  ...
}
```

This is set automatically — no configuration required. It cleanly distinguishes notebook activity from other Snowsight surfaces:

| `CLIENT_ENVIRONMENT:APPLICATION` | `CLIENT_APPLICATION_ID` | Source |
|---|---|---|
| `snowsight_notebook` | `PythonSnowpark ...` | Workspaces notebook kernel |
| `snowsight_notebook` | `Go ...` | Legacy notebook executor |
| `snowsight_workspace_user_sql` | `Snowsight` | Workspaces SQL worksheet |
| `snowsight_worksheet` | `Snowsight` | Legacy worksheet |
| `cortex_code_desktop` | `JavaScript ...` | Cortex Code |

Filtering on `APPLICATION = 'Snowflake Web App (snowsight_notebook)'` captures **both** Workspaces and legacy notebook sessions (the client differs — `PythonSnowpark` vs `Go` — but the application label is shared). From there, `SESSION_ID` bridges to `QUERY_HISTORY`, and `QUERY_ID` bridges to `QUERY_ATTRIBUTION_HISTORY` for the credits.

**The one limitation:** this attributes by *user and session*, not by notebook *name* — `SESSIONS` doesn't know which notebook file the kernel opened. If a single user runs three notebooks, their sessions collapse together. For per-notebook-name granularity, set a manual query tag in the first cell (covered in Step 2 as an upgrade):

```sql
ALTER SESSION SET QUERY_TAG = '{"notebook": "my_analysis_notebook"}';
```

Checkout [Snowflake's documentation on notebook usage monitoring](https://docs.snowflake.com/en/user-guide/ui-snowsight/notebooks-usage) for the full picture of what data you have at your disposal.

## Quick Caveats: What You Won't See

Before we dive in, a few things to know:

**1. Fast Queries Are Not Cost-Attributed.** Queries executing in under ~100ms won't appear in `query_attribution_history`. These consume negligible resources — don't worry about them.

**2. Idle Time Is Not Attributed.** Warehouse idle time between queries and compute pool idle time before auto-shutdown won't show up. Notebooks have a configurable `IDLE_AUTO_SHUTDOWN_TIME_SECONDS` property (default: 30 minutes for Warehouse Runtime, 60 minutes for Container Runtime; max 72 hours for both).

**3. Attribution Latency.** This isn't real-time, and your numbers are only as fresh as the slowest view in the chain:
- `query_attribution_history`: up to 8 hours latency (the binding constraint)
- `notebooks_container_runtime_history`: up to 3 hours latency
- `sessions`: up to 3 hours latency

**4. Container Runtime is Per-User.** Each user gets a persistent service (`<user>_SERVICE_N`) with its own node on the compute pool. The `notebooks_container_runtime_history` view tracks this at the user level — and since `notebook_name` is NULL for Workspaces notebooks, `user_name` is your attribution key on the container side.

## Step 1: Track Container Runtime Costs

Query the `notebooks_container_runtime_history` view for the SPCS component. For Workspaces notebooks, group by `user_name` and `service_name` — `notebook_name` will be NULL:

```sql
SELECT
    user_name,
    service_name,
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
    COUNT(DISTINCT service_name) AS services,
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

For the SQL and Snowpark queries that execute on the warehouse, chain three views together: `SESSIONS` identifies the notebook sessions automatically, `QUERY_HISTORY` links sessions to their queries, and `QUERY_ATTRIBUTION_HISTORY` provides the attributed credits.

```sql
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
    ARRAY_AGG(DISTINCT qah.warehouse_name) AS warehouses_used
FROM notebook_sessions ns
JOIN snowflake.account_usage.query_history qh
    ON qh.session_id = ns.session_id
    AND qh.start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
JOIN snowflake.account_usage.query_attribution_history qah
    ON qh.query_id = qah.query_id
GROUP BY ALL
ORDER BY total_warehouse_credits DESC;
```

**How this works:**
1. The CTE finds notebook sessions via the auto-populated `CLIENT_ENVIRONMENT:APPLICATION` value — no setup required.
2. `SESSION_ID` joins those sessions to their queries in `query_history`.
3. `QUERY_ID` joins to `query_attribution_history` for the actual attributed credits.

This is fully automatic and captures both Workspaces and legacy notebooks. The inner join to `query_attribution_history` means only real compute queries (>~100ms) count — notebook control-plane and metadata calls contribute nothing, so there's no inflation.

### Upgrade: per-notebook-name attribution

The query above attributes by **user**, not by notebook name (the `SESSIONS` view doesn't track which notebook file is open). If you need to break costs down by individual notebook, set a query tag in the first cell:

```sql
ALTER SESSION SET QUERY_TAG = '{"notebook": "my_analysis_notebook"}';
```

Then `query_attribution_history` carries the tag directly — no session join needed:

```sql
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
```

## Step 3: Combine Both Dimensions

Here's where it gets good. Both dimensions key on `user_name` — the container side is per-user, and the warehouse side comes from the automatic session-based attribution in Step 2:

```sql
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
```

Both CTEs aggregate to one row per user before joining, so there's no fanout. The `runtime_type` column lets you immediately see whether a user's notebook work is container-heavy, warehouse-heavy, or both. For per-notebook-name breakdown, swap the `warehouse_costs` CTE for the tag-based query from Step 2's upgrade.

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

**Heads up:** `ALTER NOTEBOOK ... SET TAG` applies to schema-level `NOTEBOOK` objects (legacy notebooks, or notebooks created as objects). Workspaces notebooks are file-based and live in your personal database, so they aren't addressable this way. For Workspaces, the session query tag from Step 2 is your attribution mechanism — encode cost center, team, or project directly in the JSON tag:

```sql
ALTER SESSION SET QUERY_TAG = '{"notebook": "q2_model_refresh", "cost_center": "data_science", "team": "recommendation_engine"}';
```

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

1. **`notebooks_container_runtime_history`** for per-user container compute (automatic)
2. **`sessions` + `query_history` + `query_attribution_history`** to attribute warehouse pushdown to notebooks automatically — no query tag required
3. **A manual `QUERY_TAG`** when you need per-notebook-name granularity
4. **A Streamlit dashboard** for continuous monitoring

Start with the combined SQL query in Step 3, explore your cost distribution, and when you're ready for continuous monitoring, deploy the dashboard. Having this visibility from day one is critical.

Pat yourself on the back. You've just turned on the lights. Next time someone asks "How much is this costing us?" You are ready  💥

## Resources

- GitHub Repository: [Notebook_Cost_Attribution_Workspaces](https://github.com/jordandhill/Notebook_Cost_Attribution_Workspaces)
- Snowflake Docs: [Notebook Usage and Cost Monitoring](https://docs.snowflake.com/en/user-guide/ui-snowsight/notebooks-usage)
- Snowflake Docs: [Notebooks on Container Runtime](https://docs.snowflake.com/en/developer-guide/snowflake-ml/notebooks-on-spcs)
- Snowflake Docs: [NOTEBOOKS_CONTAINER_RUNTIME_HISTORY View](https://docs.snowflake.com/en/sql-reference/account-usage/notebooks_container_runtime_history)
- Snowflake Docs: [QUERY_ATTRIBUTION_HISTORY View](https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history)
- Snowflake Docs: [Object Tagging Introduction](https://docs.snowflake.com/en/user-guide/object-tagging/introduction)

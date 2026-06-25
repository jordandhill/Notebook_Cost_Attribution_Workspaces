# Snowflake Notebook Cost Attribution (Notebooks in Workspaces)

> For the legacy version (Warehouse Runtime only), see [Notebook_Cost_Attribution](https://github.com/jordandhill/Notebook_Cost_Attribution).

Guide and tooling for tracking Snowflake Notebook costs across the **dual-cost model** introduced with Notebooks in Workspaces.

## The Dual-Cost Model

Snowflake Notebooks in Workspaces introduce two billing dimensions:
1. **Container Runtime** (SPCS compute pool) — per-user Python kernel costs, tracked via `notebooks_container_runtime_history`
2. **Warehouse Pushdown** — SQL/Snowpark queries executed on the warehouse, tracked via `query_attribution_history`

### How notebooks are identified

Workspaces notebooks do **not** emit query tags automatically, and `notebooks_container_runtime_history.notebook_name` is **NULL** for them (they are file-based, not schema-level `NOTEBOOK` objects). Attribution therefore keys on **user**:

- **Container side:** grouped by `user_name` / `service_name` (named `<user>_SERVICE_N`).
- **Warehouse side:** notebook sessions are identified automatically via the `sessions` view — `CLIENT_ENVIRONMENT:APPLICATION = 'Snowflake Web App (snowsight_notebook)'` — then bridged `SESSION_ID` → `query_history` → `query_attribution_history`. No query tag required.
- **Per-notebook-name granularity (optional):** set `ALTER SESSION SET QUERY_TAG = '{"notebook": "my_notebook"}'` in the first cell, and the tag flows through to `query_attribution_history`.

## Project Structure

```
├── article.md                         # Medium article draft
├── streamlit_app.py                   # Streamlit dashboard (Container Runtime compatible)
├── requirements.txt                   # Python dependencies for container runtime
├── cost_demo_notebook.ipynb           # Sample notebook for generating test spend
├── ml_training_notebook.ipynb         # Sample ML notebook for generating test spend
├── sql/
│   ├── 01_setup.sql                   # Tags, compute pool, and Streamlit deployment
│   ├── 02_container_runtime_costs.sql # Container Runtime cost queries
│   ├── 03_warehouse_pushdown_costs.sql # Warehouse pushdown cost queries
│   └── 04_combined_total_cost.sql     # Unified cost attribution query
└── README.md
```

## Deploy the Streamlit Dashboard

The dashboard runs on **Container Runtime** — a persistent shared server on SPCS.

### Step 1: Upload files

```bash
snow stage copy streamlit_app.py  @MY_DB.MY_SCHEMA.APP_STAGE --overwrite
snow stage copy requirements.txt  @MY_DB.MY_SCHEMA.APP_STAGE --overwrite
```

### Step 2: Create a compute pool (or use an existing one)

```sql
CREATE COMPUTE POOL IF NOT EXISTS NOTEBOOK_COST_DASHBOARD_POOL
    MIN_NODES = 1
    MAX_NODES = 1
    INSTANCE_FAMILY = CPU_X64_XS
    AUTO_RESUME = TRUE
    AUTO_SUSPEND_SECS = 3600;
```

### Step 3: Deploy and activate

```sql
CREATE OR REPLACE STREAMLIT MY_DB.MY_SCHEMA.NOTEBOOK_COST_DASHBOARD
    FROM '@MY_DB.MY_SCHEMA.APP_STAGE'
    MAIN_FILE = 'streamlit_app.py'
    RUNTIME_NAME = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
    COMPUTE_POOL = NOTEBOOK_COST_DASHBOARD_POOL
    QUERY_WAREHOUSE = COMPUTE_WH
    TITLE = 'Notebook Cost Attribution Dashboard';

-- Required to activate after CREATE
ALTER STREAMLIT MY_DB.MY_SCHEMA.NOTEBOOK_COST_DASHBOARD ADD LIVE VERSION FROM LAST;
```

See `sql/01_setup.sql` for the full setup script including the optional compute pool and Streamlit deployment.

> Note: `ALTER NOTEBOOK ... SET TAG` object tagging applies to schema-level `NOTEBOOK` objects only. Workspaces notebooks are file-based, so use the session `QUERY_TAG` approach above for per-notebook attribution.

## Requirements

Requires access to:
- `snowflake.account_usage.sessions`
- `snowflake.account_usage.query_history`
- `snowflake.account_usage.query_attribution_history`
- `snowflake.account_usage.notebooks_container_runtime_history`

## Attribution Latency

- `query_attribution_history`: up to 8 hours (the binding constraint)
- `notebooks_container_runtime_history`: up to 3 hours
- `sessions`: up to 3 hours

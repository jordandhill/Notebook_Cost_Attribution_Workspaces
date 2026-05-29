# Snowflake Notebook Cost Attribution

Updated guide and tooling for tracking Snowflake Notebook costs across the **dual-cost model** introduced with Notebooks in Workspaces (the successor to Legacy Notebooks).

## What's New (2026 Edition)

Snowflake Notebooks in Workspaces introduce a dual-cost model:
1. **Container Runtime** (SPCS compute pool) — per-user Python kernel costs
2. **Warehouse Pushdown** — SQL/Snowpark queries executed on the warehouse

This project provides SQL views, a Streamlit dashboard, and a Medium article draft covering both cost dimensions.

## Project Structure

```
├── article.md                        # Updated Medium article draft
├── streamlit_app.py                  # Streamlit in Snowflake dashboard
├── sql/
│   ├── 01_setup.sql                  # Database, schema, and tag creation
│   ├── 02_container_runtime_costs.sql # Container Runtime cost queries
│   ├── 03_warehouse_pushdown_costs.sql # Warehouse pushdown cost queries
│   └── 04_combined_total_cost.sql     # Unified cost attribution query
└── README.md                         # This file
```

## Snowflake Objects Created

- **Database:** `NOTEBOOK_COST_ATTRIBUTION`
- **Schema:** `NOTEBOOK_COST_ATTRIBUTION.ANALYTICS`
- **Tags:** `COST_CENTER`, `TEAM`, `PROJECT`
- **Views:**
  - `V_NOTEBOOK_CONTAINER_RUNTIME_COSTS` — Container Runtime costs
  - `V_NOTEBOOK_WAREHOUSE_PUSHDOWN_COSTS` — Warehouse pushdown costs
  - `V_NOTEBOOK_TOTAL_COSTS` — Unified daily cost view
  - `V_NOTEBOOK_COST_SUMMARY` — Leaderboard by notebook
  - `V_NOTEBOOK_COST_BY_USER` — Attribution by user

## Quick Start

1. Run `sql/01_setup.sql` to create tags
2. The views are already created in the account
3. Deploy the Streamlit app or query the views directly

## Deploy Streamlit Dashboard

```sql
CREATE STAGE IF NOT EXISTS NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.APP_STAGE;
-- Upload streamlit_app.py to the stage
PUT file://streamlit_app.py @NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.APP_STAGE;

CREATE STREAMLIT IF NOT EXISTS NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.NOTEBOOK_COST_DASHBOARD
    ROOT_LOCATION = '@NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.APP_STAGE'
    MAIN_FILE = 'streamlit_app.py'
    QUERY_WAREHOUSE = 'COMPUTE_WH';
```

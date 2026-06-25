-- ============================================================
-- Notebook Cost Attribution: Object Setup
-- Creates tags, stage, and Streamlit app for tracking costs
-- across Container Runtime (SPCS) and Warehouse Pushdown
-- ============================================================

USE ROLE ACCOUNTADMIN;

-- Database & Schema
CREATE DATABASE IF NOT EXISTS NOTEBOOK_COST_ATTRIBUTION;
CREATE SCHEMA IF NOT EXISTS NOTEBOOK_COST_ATTRIBUTION.ANALYTICS;

-- Tags for organizational cost tracking
CREATE TAG IF NOT EXISTS NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.COST_CENTER
    ALLOWED_VALUES 'data_science', 'data_engineering', 'analytics', 'ml_ops', 'finance', 'marketing';

CREATE TAG IF NOT EXISTS NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.TEAM;
CREATE TAG IF NOT EXISTS NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.PROJECT;

-- Example: Apply tags to a notebook
-- NOTE: ALTER NOTEBOOK ... SET TAG applies to schema-level NOTEBOOK objects
-- (legacy notebooks). Workspaces notebooks are file-based -- for those, set a
-- session query tag in the first cell instead:
--   ALTER SESSION SET QUERY_TAG = '{"notebook": "my_notebook", "cost_center": "data_science"}';
-- ALTER NOTEBOOK my_database.my_schema."My Notebook"
--     SET TAG NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.COST_CENTER = 'data_science';

-- ============================================================
-- Deploy the Streamlit Dashboard on Container Runtime
-- ============================================================

-- 1. Create a stage for the app source files
CREATE STAGE IF NOT EXISTS NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.APP_STAGE
    DIRECTORY = (ENABLE = TRUE);

-- 2. Upload files to the stage (run from your local machine using Snow CLI):
--    snow stage copy streamlit_app.py   @NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.APP_STAGE --overwrite
--    snow stage copy requirements.txt   @NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.APP_STAGE --overwrite

-- 3. (Optional) Create a dedicated compute pool for the dashboard.
--    You can skip this and use an existing pool like SYSTEM_COMPUTE_POOL_CPU.
CREATE COMPUTE POOL IF NOT EXISTS NOTEBOOK_COST_DASHBOARD_POOL
    MIN_NODES = 1
    MAX_NODES = 1
    INSTANCE_FAMILY = CPU_X64_XS
    AUTO_RESUME = TRUE
    AUTO_SUSPEND_SECS = 3600
    COMMENT = 'Compute pool for the Notebook Cost Attribution dashboard';

-- 4. Create the Streamlit app on Container Runtime
--    RUNTIME_NAME: use the container runtime for a shared, persistent server
--    COMPUTE_POOL: the pool where the app server runs
--    QUERY_WAREHOUSE: still needed for SQL query execution inside the app
CREATE OR REPLACE STREAMLIT NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.NOTEBOOK_COST_DASHBOARD
    FROM '@NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.APP_STAGE'
    MAIN_FILE = 'streamlit_app.py'
    RUNTIME_NAME = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
    COMPUTE_POOL = NOTEBOOK_COST_DASHBOARD_POOL
    QUERY_WAREHOUSE = COMPUTE_WH
    TITLE = 'Notebook Cost Attribution Dashboard';

-- 5. Activate the app (required after CREATE)
ALTER STREAMLIT NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.NOTEBOOK_COST_DASHBOARD
    ADD LIVE VERSION FROM LAST;

-- 6. Grant access to other roles (optional)
-- GRANT USAGE ON STREAMLIT NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.NOTEBOOK_COST_DASHBOARD
--     TO ROLE <your_role>;

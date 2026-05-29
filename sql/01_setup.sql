-- ============================================================
-- Notebook Cost Attribution: Object Setup
-- Creates tags and views for tracking Snowflake Notebook costs
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
-- ALTER NOTEBOOK my_database.my_schema."My Notebook"
--     SET TAG NOTEBOOK_COST_ATTRIBUTION.ANALYTICS.COST_CENTER = 'data_science';

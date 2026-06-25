import streamlit as st
import pandas as pd
import os

st.set_page_config(page_title="Notebook Cost Attribution", layout="wide")

try:
    # Container runtime: use st.connection for thread-safety (shared multi-user server)
    # Warehouse runtime: get_active_session() works fine
    from snowflake.snowpark.context import get_active_session
    import streamlit as _st_check
    # Prefer st.connection when available (container runtime)
    try:
        _snowflake_conn = _st_check.connection("snowflake")
        session = _snowflake_conn.session()
    except Exception:
        session = get_active_session()
    _use_snowpark = True
except Exception:
    _use_snowpark = False
    import snowflake.connector
    _conn = snowflake.connector.connect(
        connection_name=os.getenv("SNOWFLAKE_CONNECTION_NAME") or "DEMO_JHILL_PAT"
    )

def run_query(sql):
    if _use_snowpark:
        return session.sql(sql).to_pandas()
    else:
        cur = _conn.cursor()
        cur.execute(sql)
        columns = [desc[0] for desc in cur.description]
        data = cur.fetchall()
        cur.close()
        df = pd.DataFrame(data, columns=columns)
        for col in df.select_dtypes(include=["object"]).columns:
            try:
                df[col] = pd.to_numeric(df[col])
            except (ValueError, TypeError):
                pass
        import decimal
        for col in df.columns:
            if df[col].apply(lambda x: isinstance(x, decimal.Decimal)).any():
                df[col] = df[col].astype(float)
        return df

st.title("Snowflake Notebook Cost Attribution")
st.markdown("Track costs across **Container Runtime** (SPCS) and **Warehouse Pushdown** queries for Notebooks in Workspaces.")

col_filter1, col_filter2 = st.columns(2)
with col_filter1:
    lookback_days = st.selectbox("Lookback Period", [7, 14, 30, 60, 90], index=2)
with col_filter2:
    cost_type = st.selectbox("Cost View", ["All Costs", "Container Runtime Only", "Warehouse Pushdown Only"])

st.divider()

@st.cache_data(ttl=600)
def get_container_runtime_costs(days):
    # Workspaces notebooks: NOTEBOOK_NAME is NULL, so attribute per user/service.
    return run_query(f"""
        SELECT
            user_name,
            service_name,
            compute_pool_name,
            DATE_TRUNC('day', start_time) AS usage_date,
            SUM(credits) AS container_runtime_credits,
            SUM(notebook_execution_time_secs) AS execution_seconds,
            COUNT(*) AS execution_count
        FROM snowflake.account_usage.notebooks_container_runtime_history
        WHERE start_time >= DATEADD(day, -{days}, CURRENT_TIMESTAMP())
        GROUP BY ALL
        ORDER BY usage_date DESC
    """)

@st.cache_data(ttl=600)
def get_warehouse_pushdown_costs(days):
    # Identify notebook sessions automatically via the SESSIONS view
    # (CLIENT_ENVIRONMENT:APPLICATION). Bridge SESSION_ID -> QUERY_HISTORY ->
    # QUERY_ATTRIBUTION_HISTORY. NOTEBOOK_NAME is populated only when a query
    # tag like {"notebook": "..."} was set in the notebook's first cell.
    return run_query(f"""
        WITH notebook_sessions AS (
            SELECT DISTINCT session_id, user_name
            FROM snowflake.account_usage.sessions
            WHERE GET_PATH(PARSE_JSON(client_environment), 'APPLICATION')::VARCHAR
                  = 'Snowflake Web App (snowsight_notebook)'
              AND created_on >= DATEADD(day, -{days}, CURRENT_TIMESTAMP())
        )
        SELECT
            ns.user_name,
            qh.warehouse_name,
            PARSE_JSON(qh.query_tag):notebook::VARCHAR AS notebook_name,
            DATE_TRUNC('day', qh.start_time) AS usage_date,
            COUNT(DISTINCT qh.query_id) AS query_count,
            SUM(qah.credits_attributed_compute) AS warehouse_credits
        FROM notebook_sessions ns
        JOIN snowflake.account_usage.query_history qh
            ON qh.session_id = ns.session_id
            AND qh.start_time >= DATEADD(day, -{days}, CURRENT_TIMESTAMP())
        JOIN snowflake.account_usage.query_attribution_history qah
            ON qh.query_id = qah.query_id
        GROUP BY ALL
        ORDER BY usage_date DESC
    """)

container_df = get_container_runtime_costs(lookback_days)
warehouse_df = get_warehouse_pushdown_costs(lookback_days)

total_container_credits = float(container_df["CONTAINER_RUNTIME_CREDITS"].sum()) if not container_df.empty else 0.0
total_warehouse_credits = float(warehouse_df["WAREHOUSE_CREDITS"].sum()) if not warehouse_df.empty else 0.0
total_credits = total_container_credits + total_warehouse_credits

m1, m2, m3, m4 = st.columns(4)
m1.metric("Total Credits", f"{total_credits:,.4f}")
m2.metric("Container Runtime Credits", f"{total_container_credits:,.4f}")
m3.metric("Warehouse Pushdown Credits", f"{total_warehouse_credits:,.4f}")
container_pct = (total_container_credits / total_credits * 100) if total_credits > 0 else 0
m4.metric("Container Runtime %", f"{container_pct:.1f}%")

st.divider()

tab1, tab2, tab3, tab4 = st.tabs(["Daily Trend", "By User", "By Notebook (tagged)", "Raw Data"])

with tab1:
    st.subheader("Daily Credit Consumption")

    daily_container = pd.DataFrame()
    daily_warehouse = pd.DataFrame()

    if not container_df.empty:
        daily_container = container_df.groupby("USAGE_DATE").agg(
            container_credits=("CONTAINER_RUNTIME_CREDITS", "sum")
        ).reset_index()

    if not warehouse_df.empty:
        daily_warehouse = warehouse_df.groupby("USAGE_DATE").agg(
            warehouse_credits=("WAREHOUSE_CREDITS", "sum")
        ).reset_index()

    if not daily_container.empty or not daily_warehouse.empty:
        if not daily_container.empty and not daily_warehouse.empty:
            daily_merged = pd.merge(daily_container, daily_warehouse, on="USAGE_DATE", how="outer").fillna(0)
        elif not daily_container.empty:
            daily_merged = daily_container.copy()
            daily_merged["warehouse_credits"] = 0.0
        else:
            daily_merged = daily_warehouse.copy()
            daily_merged["container_credits"] = 0.0

        daily_merged = daily_merged.sort_values("USAGE_DATE")
        daily_merged["container_credits"] = daily_merged["container_credits"].astype(float)
        daily_merged["warehouse_credits"] = daily_merged["warehouse_credits"].astype(float)
        daily_merged["total_credits"] = daily_merged["container_credits"] + daily_merged["warehouse_credits"]

        chart_data = daily_merged.set_index("USAGE_DATE")[["container_credits", "warehouse_credits"]]

        if cost_type == "Container Runtime Only":
            st.area_chart(chart_data[["container_credits"]])
        elif cost_type == "Warehouse Pushdown Only":
            st.area_chart(chart_data[["warehouse_credits"]])
        else:
            st.area_chart(chart_data)
    else:
        st.info("No notebook cost data found for the selected period.")

with tab2:
    st.subheader("Cost by User")
    st.caption(
        "User is the common key across both cost dimensions. Container credits "
        "are tracked per user (Workspaces notebooks have no notebook name), and "
        "warehouse credits come from the notebook's session activity."
    )

    user_costs = []
    if not container_df.empty:
        for name, grp in container_df.groupby("USER_NAME"):
            user_costs.append({
                "user_name": name,
                "container_credits": float(grp["CONTAINER_RUNTIME_CREDITS"].sum()),
                "warehouse_credits": 0.0
            })
    if not warehouse_df.empty:
        for name, grp in warehouse_df.groupby("USER_NAME"):
            existing = next((u for u in user_costs if u["user_name"] == name), None)
            if existing:
                existing["warehouse_credits"] = float(grp["WAREHOUSE_CREDITS"].sum())
            else:
                user_costs.append({
                    "user_name": name,
                    "container_credits": 0.0,
                    "warehouse_credits": float(grp["WAREHOUSE_CREDITS"].sum())
                })

    if user_costs:
        user_df = pd.DataFrame(user_costs)
        user_df["total_credits"] = user_df["container_credits"] + user_df["warehouse_credits"]
        user_df = user_df.sort_values("total_credits", ascending=False)
        st.dataframe(user_df, use_container_width=True, hide_index=True)
        st.bar_chart(user_df.set_index("user_name")[["container_credits", "warehouse_credits"]])
    else:
        st.info("No user cost data found.")

with tab3:
    st.subheader("Cost by Notebook (tagged)")
    st.caption(
        "Warehouse pushdown credits broken down by notebook name. This requires "
        "setting a query tag in the notebook's first cell, e.g. "
        "`ALTER SESSION SET QUERY_TAG = '{\"notebook\": \"my_notebook\"}';` "
        "Untagged notebook queries appear under '(untagged)'. Container credits "
        "cannot be split by notebook name and are not shown here."
    )

    if not warehouse_df.empty:
        nb = warehouse_df.copy()
        nb["NOTEBOOK_NAME"] = nb["NOTEBOOK_NAME"].fillna("(untagged)")
        nb_df = nb.groupby("NOTEBOOK_NAME", as_index=False).agg(
            warehouse_credits=("WAREHOUSE_CREDITS", "sum"),
            query_count=("QUERY_COUNT", "sum")
        )
        nb_df = nb_df.sort_values("warehouse_credits", ascending=False)
        st.dataframe(nb_df, use_container_width=True, hide_index=True)
        st.bar_chart(nb_df.set_index("NOTEBOOK_NAME")[["warehouse_credits"]])
    else:
        st.info("No warehouse pushdown data found.")

with tab4:
    st.subheader("Raw Data Export")

    export_tab1, export_tab2 = st.tabs(["Container Runtime", "Warehouse Pushdown"])
    with export_tab1:
        if not container_df.empty:
            st.dataframe(container_df, use_container_width=True, hide_index=True)
            st.download_button(
                "Download CSV",
                container_df.to_csv(index=False),
                "container_runtime_costs.csv",
                "text/csv"
            )
        else:
            st.info("No container runtime data.")

    with export_tab2:
        if not warehouse_df.empty:
            st.dataframe(warehouse_df, use_container_width=True, hide_index=True)
            st.download_button(
                "Download CSV",
                warehouse_df.to_csv(index=False),
                "warehouse_pushdown_costs.csv",
                "text/csv"
            )
        else:
            st.info("No warehouse pushdown data.")

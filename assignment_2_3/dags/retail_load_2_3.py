"""
### retail_load_2_3

Loads the daily Northline source files into the Gold model, one business
date per run:

    setup -> wait_for_files (x4) -> ingest_file (x4) -> silver -> gold dimensions -> gold facts -> reconcile

* **setup**: creates schemas, stage and layer tables if missing (`00_setup.sql`).
* **wait_for_files**: one FileSensor per source file for the run's date, with a timeout.
* **ingest_file**: dynamically mapped, one task per file: PUT to stage and COPY into Bronze,
  then checks that every file row arrived (gate G1).
* **silver**: clean, dedupe and check each feed; bad rows are quarantined with a gate and
  reason code and the run carries on with the good rows. Also builds the fiscal calendar.
* **gold_dimensions**: calendar, product and location dimensions. DIM_ITEM and DIM_LOCN are
  SCD2 (new surrogate key per version); names are SCD1 (updated in place).
* **gold_facts**: sales (delete and reload the date) and inventory (positional: changed rows
  are closed, not deleted).
* **reconcile**: compares file, Silver and Gold counts and net sales; fails the run on any
  mismatch.

**No hard-coding:** credentials come from the `snowflake_conn` connection, the landing folder
from the `fs_landing` connection, the SQL folder from `AIRFLOW_HOME`, and every table name
lives in the SQL files under `include/sql`, never in this file.

**Idempotent:** every step either replaces the run's business date or only changes rows that
differ, so running the same date twice gives the same row counts and totals.
"""

from __future__ import annotations

import csv
import os
from datetime import datetime, timedelta
from pathlib import Path

from jinja2 import Template

from airflow.providers.common.sql.hooks.sql import fetch_all_handler, fetch_one_handler
from airflow.providers.snowflake.hooks.snowflake import SnowflakeHook
from airflow.providers.standard.hooks.filesystem import FSHook
from airflow.providers.standard.sensors.filesystem import FileSensor
from airflow.sdk import TaskGroup, dag, get_current_context, task

# Connection IDs (defined in Admin -> Connections, see README)
SNOWFLAKE_CONN_ID = "snowflake_conn"
LANDING_CONN_ID = "fs_landing"

# SQL folder: <AIRFLOW_HOME>/include/sql (mounted from the project's include/ folder)
SQL_DIR = Path(os.environ["AIRFLOW_HOME"]) / "include" / "sql"

# The four daily source feeds. File name = <feed>_<YYYYMMDD>.csv,
# Bronze SQL = include/sql/bronze/<feed>.sql
FEEDS = ["item_master", "store_master", "pos_sales", "inventory_snapshot"]

default_args = {
    "owner": "airflow",
    "retries": 2,
    "retry_delay": timedelta(minutes=1),
}


def render_sql(relative_path: str, **values) -> str:
    """Read a SQL file from include/sql, fill in its {{ placeholders }} and
    drop full-line comments.

    Comment lines are removed because the Snowflake connector only recognises
    client-side commands such as PUT when they are the first text in a statement.
    """
    text = (SQL_DIR / relative_path).read_text(encoding="utf-8")
    rendered = Template(text).render(**values)
    lines = [line for line in rendered.splitlines() if not line.strip().startswith("--")]
    return "\n".join(lines)


def snowflake() -> SnowflakeHook:
    return SnowflakeHook(snowflake_conn_id=SNOWFLAKE_CONN_ID)


@dag(
    dag_id="retail_load_2_3",
    description="Daily load of Northline source files: Bronze -> Silver -> Gold -> reconcile",
    start_date=datetime(2026, 11, 1),
    end_date=datetime(2026, 11, 5),   # last day of the sample data; remove for live daily loads
    schedule="@daily",
    catchup=False,           # past dates are loaded with an explicit backfill
    max_active_runs=1,       # dates run one after another (SCD2 and inventory depend on order)
    default_args=default_args,
    tags=["ycotek", "assignment-2.3", "snowflake"],
    doc_md=__doc__,
)
def retail_load_2_3():

    # ------------------------------------------------------------------
    # Generic step: run one SQL file for the run's business date.
    # Every SQL file ends with SELECT <rows_ok>, <rows_rejected>.
    # ------------------------------------------------------------------
    @task
    def run_sql_file(sql_file: str) -> dict:
        ds = get_current_context()["ds"]
        rows_ok, rows_rejected = snowflake().run(
            render_sql(sql_file, ds=ds), split_statements=True,
            handler=fetch_one_handler, return_last=True)
        print(f"{sql_file} for {ds}: {rows_ok} rows OK, {rows_rejected} rows rejected / not loaded")
        return {"sql_file": sql_file, "rows_ok": rows_ok, "rows_rejected": rows_rejected}

    def step(task_id: str, sql_file: str):
        return run_sql_file.override(task_id=task_id)(sql_file)

    # ------------------------------------------------------------------
    # 0. Setup: idempotent DDL (CREATE ... IF NOT EXISTS)
    # ------------------------------------------------------------------
    @task
    def setup() -> None:
        snowflake().run(render_sql("00_setup.sql"), split_statements=True)

    # ------------------------------------------------------------------
    # 1. Wait: one sensor per file for this business date, with a timeout
    # ------------------------------------------------------------------
    wait_for_files = FileSensor.partial(
        task_id="wait_for_files",
        fs_conn_id=LANDING_CONN_ID,
        poke_interval=30,
        timeout=60 * 60,          # fail after 1 hour without the file
        mode="reschedule",        # free the worker slot between checks
    ).expand(filepath=[f"{feed}_{{{{ ds_nodash }}}}.csv" for feed in FEEDS])

    # ------------------------------------------------------------------
    # 2. Bronze: dynamically mapped, one ingest task per file
    # ------------------------------------------------------------------
    @task(map_index_template="{{ feed }}")
    def ingest_file(feed: str) -> dict:
        context = get_current_context()
        ds, ds_nodash = context["ds"], context["ds_nodash"]
        context["feed"] = feed  # label for the mapped task in the UI

        file_name = f"{feed}_{ds_nodash}.csv"
        local_file = Path(FSHook(fs_conn_id=LANDING_CONN_ID).get_path()) / file_name

        # Rows in the file (excluding the header), for gate G1
        with local_file.open(newline="", encoding="utf-8") as f:
            file_rows = sum(1 for _ in csv.reader(f)) - 1

        sql = render_sql(f"bronze/{feed}.sql", local_file=local_file.as_posix(),
                         file_name=file_name, ds=ds)
        rows_loaded = snowflake().run(sql, split_statements=True,
                                      handler=fetch_one_handler, return_last=True)[0]

        # Gate G1: every row in the file must be in Bronze
        if rows_loaded != file_rows:
            raise ValueError(f"G1 failed for {file_name}: file has {file_rows} rows, "
                             f"Bronze has {rows_loaded}")
        print(f"G1 passed: {file_name} -> {rows_loaded} rows in Bronze")
        return {"feed": feed, "file": file_name, "rows": rows_loaded}

    ingested = ingest_file.expand(feed=FEEDS)

    # ------------------------------------------------------------------
    # 3. Silver: clean, dedupe, check. Bad rows are quarantined with a
    #    gate and reason code; the run continues with the good rows.
    # ------------------------------------------------------------------
    with TaskGroup(group_id="silver") as silver:
        silver_calendar = step("fiscal_day", "silver/slv_fiscal_day.sql")
        silver_item = step("item", "silver/slv_item.sql")
        silver_store = step("store", "silver/slv_store.sql")
        silver_sales = step("sales_line", "silver/slv_sales_line.sql")
        silver_inventory = step("inventory_position", "silver/slv_inventory_position.sql")
        # Masters first: sales and inventory are checked against them.
        [silver_item, silver_store] >> silver_sales
        [silver_item, silver_store] >> silver_inventory

    # ------------------------------------------------------------------
    # 4. Gold dimensions: parents before children, so keys can be looked up
    # ------------------------------------------------------------------
    with TaskGroup(group_id="gold_dimensions") as gold_dimensions:
        dim_year = step("dim_year", "gold/dim_year.sql")
        dim_month = step("dim_month", "gold/dim_month.sql")
        dim_week = step("dim_week", "gold/dim_week.sql")
        dim_day = step("dim_day", "gold/dim_day.sql")

        dim_catg = step("dim_catg", "gold/dim_catg.sql")
        dim_subcatg = step("dim_subcatg", "gold/dim_subcatg.sql")
        dim_item = step("dim_item", "gold/dim_item.sql")

        dim_area = step("dim_area", "gold/dim_area.sql")
        dim_regn = step("dim_regn", "gold/dim_regn.sql")
        dim_district = step("dim_district", "gold/dim_district.sql")
        dim_locn = step("dim_locn", "gold/dim_locn.sql")

        dim_year >> [dim_month, dim_week] >> dim_day
        dim_catg >> dim_subcatg >> dim_item
        dim_area >> dim_regn >> dim_district >> dim_locn

    # ------------------------------------------------------------------
    # 5. Gold facts
    # ------------------------------------------------------------------
    with TaskGroup(group_id="gold_facts") as gold_facts:
        fct_sales = step("fct_sales", "gold/fct_sales.sql")
        fct_inventory = step("fct_inventory", "gold/fct_inventory.sql")

    # ------------------------------------------------------------------
    # 6. Reconcile: file vs Silver vs Gold; any FAIL fails the run
    # ------------------------------------------------------------------
    @task
    def reconcile() -> list[dict]:
        context = get_current_context()
        ds = context["ds"]
        rows = snowflake().run(
            render_sql("reconcile/reconcile.sql", ds=ds, run_id=context["run_id"]),
            split_statements=True, handler=fetch_all_handler, return_last=True)

        print(f"Reconciliation for {ds}")
        print(f"{'check':<55}{'source':>14}{'target':>14}{'diff':>12}  status")
        results = []
        for check_nm, source, target, diff, status in rows:
            print(f"{check_nm:<55}{source!s:>14}{target!s:>14}{diff!s:>12}  {status}")
            results.append({"check": check_nm, "source": str(source), "target": str(target),
                            "difference": str(diff), "status": status})

        failed = [r["check"] for r in results if r["status"] == "FAIL"]
        if failed:
            raise ValueError(f"Reconciliation failed for {ds}: {failed}")
        print(f"All {len(results)} checks passed "
              f"({sum(r['status'] == 'ALERT' for r in results)} alert(s)).")
        return results

    # ------------------------------------------------------------------
    # Dependencies
    # ------------------------------------------------------------------
    setup_done = setup()
    setup_done >> wait_for_files >> ingested >> [silver_item, silver_store]
    setup_done >> silver_calendar >> dim_year

    silver_item >> dim_catg
    silver_store >> dim_area

    [dim_day, dim_item, dim_locn, silver_sales] >> fct_sales
    [dim_item, dim_locn, silver_inventory] >> fct_inventory

    [fct_sales, fct_inventory] >> reconcile()


retail_load_2_3()

"""
### load_files_to_snowflake

Loads every CSV file in a local source folder into its own Snowflake table,
as-is (no transformation).

**Flow**

1. `wait_for_complete_file`: FileSensor waits for the `.COMPLETE` signal file.
2. `list_source_files`: finds the CSV files and pushes the list to XCom.
3. `prepare_snowflake`: creates the target schema, stage and file format (Hook).
4. `load_file`: one mapped task per file (Dynamic Task Mapping):
   CREATE TABLE -> PUT file to stage -> COPY INTO table.
5. `summarize_load`: collects every mapped task's XCom and logs row counts.
6. `archive_files`: moves the loaded files and the signal file to an archive
   folder, so the next run waits for a fresh delivery.

**Airflow concepts used:** FileSensor (reschedule mode), XCom, Dynamic Task
Mapping (`partial` / `expand`), Connections (`file_con`, `snowflake_conn`),
Hooks (`SnowflakeHook`), Variables, Jinja templating, TaskFlow API,
default_args with retries, trigger rules, DAG docs.
"""

from __future__ import annotations

import csv
import os
import re
import shutil
from datetime import datetime, timedelta

from airflow.providers.snowflake.hooks.snowflake import SnowflakeHook
from airflow.providers.standard.sensors.filesystem import FileSensor
from airflow.sdk import Variable, dag, get_current_context, task

# Connection IDs (created in Admin -> Connections)
SNOWFLAKE_CONN_ID = "snowflake_conn"
FS_CONN_ID = "file_con"

default_args = {
    "owner": "airflow",
    "retries": 2,                          # retry a failed task twice
    "retry_delay": timedelta(minutes=1),   # wait 1 minute between retries
}


@dag(
    dag_id="load_files_to_snowflake",
    description="Wait for .COMPLETE, then load every CSV in the source folder into Snowflake",
    start_date=datetime(2026, 11, 1),
    schedule=None,          # triggered manually
    catchup=False,
    max_active_runs=1,      # never load the same folder twice at the same time
    default_args=default_args,
    tags=["ycotek", "orchestration", "snowflake"],
    doc_md=__doc__,
)
def load_files_to_snowflake():

    # 1. FILE SENSOR -------------------------------------------------------
    # filepath is a Jinja template that reads the Airflow Variable
    # "source_folder" at run time. mode="reschedule" frees the worker slot
    # between checks instead of blocking it while waiting.
    wait_for_complete_file = FileSensor(
        task_id="wait_for_complete_file",
        fs_conn_id=FS_CONN_ID,
        filepath="{{ var.value.source_folder }}/.COMPLETE",
        poke_interval=30,       # check every 30 seconds
        timeout=60 * 60,        # give up after 1 hour
        mode="reschedule",
    )

    # 2. LIST FILES (result goes to XCom) ----------------------------------
    @task
    def list_source_files() -> list[str]:
        """Return the full path of every .csv file in the source folder."""
        folder = Variable.get("source_folder")
        files = sorted(
            os.path.join(folder, name)
            for name in os.listdir(folder)
            if name.lower().endswith(".csv")
        )
        if not files:
            raise ValueError(f"No .csv files found in {folder}")
        print(f"Found {len(files)} file(s): {[os.path.basename(f) for f in files]}")
        return files  # returned value is pushed to XCom automatically

    # 3. PREPARE SNOWFLAKE (Hook + Connection + Variable) ------------------
    @task
    def prepare_snowflake() -> str:
        """Create the target schema, internal stage and CSV file format."""
        schema = Variable.get("snowflake_target_schema", default="RAW_LANDING")
        hook = SnowflakeHook(snowflake_conn_id=SNOWFLAKE_CONN_ID)
        hook.run(
            [
                f"CREATE SCHEMA IF NOT EXISTS {schema}",
                f"CREATE STAGE IF NOT EXISTS {schema}.AIRFLOW_STAGE",
                f"""CREATE FILE FORMAT IF NOT EXISTS {schema}.CSV_FMT
                        TYPE = CSV
                        SKIP_HEADER = 1
                        FIELD_OPTIONALLY_ENCLOSED_BY = '"'
                        EMPTY_FIELD_AS_NULL = TRUE""",
            ]
        )
        print(f"Snowflake schema {schema} is ready")
        return schema

    # 4. LOAD ONE FILE (mapped once per file) ------------------------------
    @task(max_active_tis_per_dag=4)
    def load_file(file_path: str, schema: str) -> dict:
        """Create a table from the CSV header, PUT the file, COPY it in."""
        file_name = os.path.basename(file_path)
        table = "RAW_" + re.sub(r"[^A-Za-z0-9]", "_", os.path.splitext(file_name)[0]).upper()
        full_table = f"{schema}.{table}"

        # Read only the header row to build the column list (all VARCHAR,
        # because the assignment asks for no transformation).
        with open(file_path, newline="", encoding="utf-8-sig") as f:
            header = next(csv.reader(f))
        columns = ", ".join(f'"{col.strip().upper()}" VARCHAR' for col in header)

        hook = SnowflakeHook(snowflake_conn_id=SNOWFLAKE_CONN_ID)
        hook.run(f"CREATE OR REPLACE TABLE {full_table} ({columns})")
        hook.run(
            f"PUT 'file://{file_path}' @{schema}.AIRFLOW_STAGE "
            f"AUTO_COMPRESS = TRUE OVERWRITE = TRUE"
        )
        hook.run(
            f"COPY INTO {full_table} "
            f"FROM @{schema}.AIRFLOW_STAGE/{file_name}.gz "
            f"FILE_FORMAT = (FORMAT_NAME = '{schema}.CSV_FMT') "
            f"ON_ERROR = 'ABORT_STATEMENT'"
        )
        rows = hook.get_first(f"SELECT COUNT(*) FROM {full_table}")[0]

        print(f"Loaded {rows} rows from {file_name} into {full_table}")
        return {"file": file_name, "table": full_table, "rows_loaded": rows}

    # 5. SUMMARIZE (pulls the XCom of every mapped task) -------------------
    @task
    def summarize_load(results) -> dict:
        results = list(results)
        total = sum(r["rows_loaded"] for r in results)
        print("Load summary")
        for r in results:
            print(f"  {r['file']:<20} -> {r['table']:<30} {r['rows_loaded']:>8} rows")
        print(f"  TOTAL: {len(results)} files, {total} rows")
        return {"files_loaded": len(results), "total_rows": total}

    # 6. ARCHIVE (optional, controlled by a Variable) ----------------------
    @task
    def archive_files(files: list[str], summary: dict) -> None:
        """Move loaded files and the signal file into archive/<run_id>/."""
        if Variable.get("archive_after_load", default="true").lower() != "true":
            print("archive_after_load is not 'true': files left in place")
            return
        folder = Variable.get("source_folder")
        run_id = re.sub(r"[^A-Za-z0-9_-]", "_", get_current_context()["run_id"])
        archive_dir = os.path.join(folder, "archive", run_id)
        os.makedirs(archive_dir, exist_ok=True)
        for path in files + [os.path.join(folder, ".COMPLETE")]:
            if os.path.exists(path):
                shutil.move(path, os.path.join(archive_dir, os.path.basename(path)))
        print(f"Archived {summary['files_loaded']} file(s) and .COMPLETE to {archive_dir}")

    # DEPENDENCIES ---------------------------------------------------------
    files = list_source_files()
    schema = prepare_snowflake()
    wait_for_complete_file >> [files, schema]

    loaded = load_file.partial(schema=schema).expand(file_path=files)  # Dynamic Task Mapping
    summary = summarize_load(loaded)
    archive_files(files, summary)


load_files_to_snowflake()

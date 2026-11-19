# Orchestration Assignment 2: Load Local Files into Snowflake with Airflow

## Overview

`load_files_to_snowflake.py` defines an Airflow 3 DAG, **`load_files_to_snowflake`**, that waits for a `.COMPLETE` signal file in a local folder and then loads every CSV file in that folder into its own Snowflake table, as-is (no transformation).

Sample files loaded: `sales.csv`, `inventory.csv`, `item.csv`, `location.csv`.

## Pipeline shape

```
wait_for_complete_file ─┬→ list_source_files ─┐
                        └→ prepare_snowflake ─┴→ load_file [×N, one per file] → summarize_load → archive_files
```

| Task | What it does |
|---|---|
| `wait_for_complete_file` | **FileSensor** that waits until `.COMPLETE` exists in the source folder. Checks every 30 seconds in `reschedule` mode; times out after 1 hour. |
| `list_source_files` | Lists every `.csv` file in the source folder and pushes the list to **XCom**. |
| `prepare_snowflake` | Uses **SnowflakeHook** to create the target schema, an internal stage and a CSV file format (idempotent: `IF NOT EXISTS`). |
| `load_file` | **Dynamically mapped**: one task instance per file. Builds the table from the CSV header (all `VARCHAR`), uploads the file to the stage with `PUT`, loads it with `COPY INTO`, and returns the row count to XCom. |
| `summarize_load` | Pulls the XCom results of every mapped `load_file` task and logs files loaded and total rows. |
| `archive_files` | Moves the loaded files and `.COMPLETE` into `archive/<run_id>/`, so the next run waits for a fresh delivery. |

Each file becomes a table named `RAW_<FILE_NAME>` in schema `RAW_LANDING`:
`sales.csv` → `RAW_LANDING.RAW_SALES`, `inventory.csv` → `RAW_LANDING.RAW_INVENTORY`, and so on.

## Airflow concepts used

| Concept | Where and how |
|---|---|
| **File Sensor** | `wait_for_complete_file` waits for the `.COMPLETE` signal file before anything is loaded. `mode="reschedule"` frees the worker slot between checks instead of blocking it. |
| **XCom** | `list_source_files` passes the file list to `load_file`; each `load_file` returns `{file, table, rows_loaded}`; `summarize_load` collects all of them and pushes `files_loaded` and `total_rows`. |
| **Dynamic Task Mapping** | `load_file.partial(schema=schema).expand(file_path=files)` creates one task per file at run time. 4 files produced 4 mapped tasks (Map Index 0–3) that ran in parallel, with no code change needed for more or fewer files. |
| **Connections** | `file_con` (type `fs`) for the FileSensor; `snowflake_conn` (type `snowflake`) holds the Snowflake account, user, warehouse, database and role. No credentials are in the code. |
| **Hooks** | `SnowflakeHook(snowflake_conn_id="snowflake_conn")` runs all Snowflake SQL (`CREATE`, `PUT`, `COPY INTO`, `SELECT COUNT(*)`). |
| **Variables** | `source_folder`, `snowflake_target_schema`, `archive_after_load` control the folder, target schema and archiving without editing code. |
| **Jinja templating** | The sensor's `filepath` is `{{ var.value.source_folder }}/.COMPLETE`, resolved at run time. |
| **TaskFlow API** | All Python tasks use `@task`; return values become XComs automatically. |
| **Retries** | `default_args` sets `retries=2` and `retry_delay=1 minute`. |
| **Concurrency control** | `max_active_runs=1` (never two loads of the same folder at once) and `max_active_tis_per_dag=4` on `load_file`. |
| **DAG documentation** | The module docstring is shown in the UI through `doc_md`. |

## Setup

### 1. Docker
- The project folder's `data/` directory is mounted into the containers (`docker-compose.yaml`):
  `- ${AIRFLOW_PROJ_DIR:-.}/data:/opt/airflow/data`
- Source folder on the host: `data/incoming/` → inside Airflow: `/opt/airflow/data/incoming`.
- Snowflake provider: `_PIP_ADDITIONAL_REQUIREMENTS=apache-airflow-providers-snowflake` in `.env`.

### 2. Snowflake service user
Airflow connects with a dedicated service user instead of a personal login (standard practice for pipelines):

```sql
CREATE USER IF NOT EXISTS AIRFLOW_USER
  PASSWORD = '********'
  TYPE = LEGACY_SERVICE
  DEFAULT_ROLE = ACCOUNTADMIN
  DEFAULT_WAREHOUSE = SNOWFLAKE_LEARNING_WH;
GRANT ROLE ACCOUNTADMIN TO USER AIRFLOW_USER;
```

(`ACCOUNTADMIN` is used only because this is a personal learning account; in production the user would get a narrower role.)

### 3. Connections (Admin → Connections)

| Connection Id | Type | Settings |
|---|---|---|
| `file_con` | File (path) | default |
| `snowflake_conn` | Snowflake | Login `AIRFLOW_USER`, password, schema `PUBLIC`; Extra: `account`, `warehouse` = `SNOWFLAKE_LEARNING_WH`, `database` = `SNOWFLAKE_LEARNING_DB`, `role` = `ACCOUNTADMIN` |

### 4. Variables (Admin → Variables)

| Key | Value |
|---|---|
| `source_folder` | `/opt/airflow/data/incoming` |
| `snowflake_target_schema` | `RAW_LANDING` |
| `archive_after_load` | `true` |

## How to run

1. Copy `load_files_to_snowflake.py` into `dags/`.
2. Put the CSV files into `data/incoming/`.
3. Unpause the DAG and trigger it once. `wait_for_complete_file` shows **up_for_reschedule** while it waits.
4. Create the signal file (PowerShell):
   `New-Item -ItemType File data\incoming\.COMPLETE`
5. On the next check the sensor succeeds and the rest of the DAG runs.

## Result

- All 9 task instances succeeded, including 4 mapped `load_file` tasks (Map Index 0–3) that ran in parallel.
- XCom from `summarize_load`: `files_loaded = 4`, `total_rows = 4778`.
- Row counts in Snowflake match the source files:

| Table | Rows |
|---|---|
| `RAW_LANDING.RAW_SALES` | 2000 |
| `RAW_LANDING.RAW_INVENTORY` | 2000 |
| `RAW_LANDING.RAW_ITEM` | 738 |
| `RAW_LANDING.RAW_LOCATION` | 40 |
| **Total** | **4778** |

- The loaded files and `.COMPLETE` were moved to `data/incoming/archive/<run_id>/`.

## Issues met and how they were solved

| Issue | Cause | Fix |
|---|---|---|
| Sensor kept waiting after `.COMPLETE` was created | `.COMPLETE` had been created as a **folder**, not a file (`ls -la` showed `drwx`) | Deleted it and created an empty file with `New-Item -ItemType File` |
| Extra runs stuck in **Queued** | The DAG was triggered several times; `max_active_runs=1` allows only one active run | Deleted the extra queued runs; retried failed tasks with **Clear** instead of new triggers |
| `251001: Account must be specified` | The Snowflake account was not saved in the connection | Added `account`, `warehouse`, `database`, `role` in the connection's Extra Fields JSON |
| `390100: Incorrect username or password` | Personal login not accepted from Airflow | Created the dedicated `AIRFLOW_USER` service user and updated `snowflake_conn` |

## Files

| File | Purpose |
|---|---|
| `load_files_to_snowflake.py` | The DAG |
| `README.md` | This document |
| `screenshots/1_sensor_waiting.png` | Sensor in `up_for_reschedule` before `.COMPLETE` existed |
| `screenshots/2_dag_success.png` | Successful run: graph and task list with 4 mapped `load_file` tasks |
| `screenshots/3_xcom.png` | XCom values from `summarize_load` |
| `screenshots/4_snowflake_tables.png` | Row counts of the 4 tables in Snowflake |
| `screenshots/1b_sensor_waiting_graph.png`, `2b_dag_graph.png`, `3b_xcom_log.png` | Extra views of the same results |

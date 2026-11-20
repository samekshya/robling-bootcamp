# Retail ETL: Assignment 2.3 (Ycotek Data Engineering, Module 2)

Airflow pipeline that loads five days of Northline retail source files into Snowflake through Bronze, Silver and Gold layers. Dimensions use SCD2 and SCD1, bad rows are quarantined with a reason code, and a reconcile task fails the run if Gold does not tie back to the source files.

## Repo layout

| Folder / file | Content |
|---|---|
| `dags/` | `retail_load_2_3.py` (dag_id `retail_load_2_3`) |
| `include/sql/` | `00_setup.sql` (schemas, stage, Bronze/Silver/audit tables) and one SQL file per table load: `bronze/` (4), `silver/` (5), `gold/` (13), `reconcile/` (1) |
| `tests/` | `test_dag.py` (DAG parses, no cycles, retries set, stages in order, sensor timeout, no hard-coded credentials, paths or table names) |
| `tools/` | `generate_source_files.py` (creates the daily files, fixed seed 2303) |
| `sample_data/` | The 20 generated files the DAG reads (4 feeds × 5 days) and `DATA_NOTES.md` |
| `sample_data/expected/` | Answer files: expected totals, Day 3 defects, SCD events |
| `evidence/` | Screenshots and `verify_queries.sql` (the queries behind them) |
| `docker-compose.yaml`, `.env.example` | Airflow setup |

The Gold tables come from my Assignment 2.1 model (`assignment_2_1/create_tables.sql`). The architecture is from Assignment 2.2 (`assignment_2_2/`).

## Pipeline

```
setup -> wait_for_files (x4) -> ingest_file (x4) -> silver -> gold_dimensions -> gold_facts -> reconcile
```

- **wait_for_files:** one `FileSensor` per file (`<feed>_<YYYYMMDD>.csv`), reschedule mode, checks every 30 s, fails after 1 hour.
- **Bronze (`ingest_file`):** dynamically mapped, one task per file. `PUT` to an internal stage, then `COPY INTO` a Bronze table with every column as text, plus the file name, row number and load time. Delete-and-reload per business date. Gate G1 compares the Bronze row count with the file and fails the task if they differ.
- **Silver:** typed and cleaned. Store codes `1101` / `01101` / `NL-01101` become `1101`; ISO and `M/D/YYYY` dates are both parsed; `USD` / `usd` / `US$` become `USD` (`CAD` is kept); names are trimmed and spaces collapsed. Bad rows go to `SILVER.REJ_ROW` with the gate (G3 value, G4 duplicate, G5 unknown key), reason code, file, row number and the raw record. The run continues with the good rows. Silver also builds the 4-5-4 fiscal calendar.
- **Gold:** dimensions first (calendar, product hierarchy, location hierarchy), parents before children, then the two facts. One SQL file per table.
- **Reconcile:** 11 checks per date, written to `SILVER.AUD_RECONCILIATION` and printed in the task log. Any `FAIL` raises an error and the run fails.

Business date = the run's logical date. Schedule `@daily`, start 2026-11-01, end 2026-11-05, `catchup=False`, `max_active_runs=1`, retries 2 (1 minute apart).

## Data

The source files are dummy data generated for this assignment. Items (40, plus 1 new on Day 5) and stores (12, including the Canadian store 1137) come from the Northline reference data used in 2.1 and 2.2.

| Day | Date | What happens |
|---|---|---|
| Every day | | Messy store codes, mixed date formats, currency spellings, stray spaces, upper-case names, negative stock |
| 2 | 2026-11-02 | Item 10000722 renamed "Yardline Pro Supplie" → "Yardline Pro Supplies" (SCD1) |
| 3 | 2026-11-03 | 5 bad sales rows: 2 null items, 1 negative quantity, 1 unknown item, 1 duplicate line |
| 3 | 2026-11-03 | Store 1112 moves from district 104 to 108 (SCD2) |
| 4 | 2026-11-04 | Item 10000020 moves from subclass Tees to Polos (SCD2) |
| 5 | 2026-11-05 | New item 10000901 |

## Data model

Gold follows my 2.1 snowflake model in schema `RETAIL_DW`:

- **Product:** `DIM_CATG` > `DIM_SUBCATG` > `DIM_ITEM` (SCD2 on `BRAND_NM` and `SUBCATG_KY`, SCD1 on `ITEM_NM`).
- **Location:** `DIM_AREA` > `DIM_REGN` > `DIM_DISTRICT` > `DIM_LOCN` (SCD2 on `DISTRICT_KY`, SCD1 on `LOCN_NM`).
- **Calendar:** `DIM_YEAR` > `DIM_MONTH` (fiscal period) / `DIM_WEEK` > `DIM_DAY`, retail 4-5-4 calendar with weeks starting on Sunday. `DIM_CUSTOMER` has an Unknown row (key -1), because there is no customer feed.
- **Facts:** `FCT_SALES` (grain: one transaction line, linked to the item and store version valid on the sale date). `FCT_INVENTORY` is positional: a new row only when the on-hand quantity changes, and old rows are closed with `EFF_END_DT`, never deleted.
- New SCD2 versions get a new surrogate key from `AUTOINCREMENT`.

Mapping: file `dept` → `DIM_CATG`, `subclass` → `DIM_SUBCATG`, `area` / `region` / `district` → `DIM_AREA` / `DIM_REGN` / `DIM_DISTRICT`, `store` → `DIM_LOCN`.

## How to run

Requirements: Docker Desktop and a Snowflake account. Python is not needed locally.

1. In Snowflake, run `assignment_2_1/create_tables.sql` once. It creates the 15 Gold tables in `RETAIL_DW`. The Bronze and Silver objects are created by the DAG's `setup` task.
2. Copy `.env.example` to `.env`. It only holds `AIRFLOW_UID` and the Snowflake provider package, no credentials. `.env` is git-ignored.
3. Start Airflow from this folder:
   ```
   docker compose up -d
   ```
   The UI is at http://localhost:8080 (airflow / airflow). The compose file mounts `dags/`, `include/` and `sample_data/` (read-only, as `/opt/airflow/data/retail_landing`).
4. In Airflow, under **Admin → Connections**, create:
   - `snowflake_conn`: type Snowflake, login and password of the Snowflake service user, Extra `{"account": "...", "warehouse": "...", "database": "...", "role": "..."}`. Credentials live only in this connection.
   - `fs_landing`: type File (path), Extra `{"path": "/opt/airflow/data/retail_landing"}`.
5. Unpause `retail_load_2_3`.

To regenerate the data (optional, any Python 3, from this folder): `python tools/generate_source_files.py --out sample_data --start 2026-11-01`. The seed is fixed, so the files come out identical.

## How to backfill

1. Open the DAG `retail_load_2_3`, click **Trigger**, then **Backfill**.
2. Set From 2026-11-01 to 2026-11-05 and choose **All Runs**. The days run one after another, in order.

The UI shows times in the browser's time zone. In Nepal (UTC+05:45), midnight UTC is 05:45, so enter 01 Nov 05:45 to 05 Nov 05:45. The window should say 5 runs.

To rerun a single day, use Backfill with both dates set to that day and **All Runs**. Only one backfill can run per DAG at a time.

CLI alternative:
```
docker compose exec airflow-scheduler airflow backfill create --dag-id retail_load_2_3 --from-date 2026-11-01 --to-date 2026-11-05 --reprocess-behavior completed
```

## Idempotency

- Bronze, Silver, `REJ_ROW`, `FCT_SALES` and `AUD_RECONCILIATION` delete and reload the business date inside one transaction.
- Calendar, category, area, region and district use `MERGE` on the business key.
- `DIM_ITEM` and `DIM_LOCN` close a version only when the run date is after its start date, and insert a new version only when no current row exists.
- SCD1 name updates only run when the date is the latest loaded date, so rerunning an older date cannot write an old name back.
- `FCT_INVENTORY` only closes and opens rows where the position differs from the open row. Rerunning the latest date changes nothing.

Running the full backfill twice leaves all counts and amounts unchanged (`evidence/10` and `evidence/11`).

## Error handling

Day 3 (2026-11-03) has five planted bad sales rows. They are moved to `REJ_ROW` with a reason code (`NULL_ITEM` 2, `NEGATIVE_QTY` 1, `UNKNOWN_ITEM` 1, `DUPLICATE_KEY` 1), and the run does not stop (`evidence/02`, `evidence/05`). Reconcile raises an `ALERT` (not a failure) when more than 1% of the sales file is quarantined; Day 3 is 1.02%.

| Situation | What happens |
|---|---|
| File missing | Sensor waits and fails after 1 hour |
| File only partly loaded | G1 fails the ingest task |
| Bad rows | Quarantined in `REJ_ROW`, counted, run continues |
| Gold does not tie to the files | Reconcile fails the run |
| Temporary Snowflake error | Each task retries twice |

### Reconciliation checks (per date)

- Business date exists in `DIM_DAY`
- Sales rows: file = Silver + quarantine
- Sales rows: Silver = Gold
- **Net sales: file − quarantined = Gold `SUM(SLS_AMT)`**
- Inventory rows: file = Silver + quarantine
- Inventory positions and on-hand quantity: Silver = Gold rows valid on the date
- No item, store or inventory position has two current rows
- Quarantine rate (alert above 1%)

Expected Gold results (also in `sample_data/expected/expected_totals.csv`):

| Date | Sales rows | Net sales |
|---|---|---|
| 2026-11-01 | 488 | 66,211.25 |
| 2026-11-02 | 552 | 71,196.44 |
| 2026-11-03 | 483 | 65,916.08 |
| 2026-11-04 | 501 | 70,970.50 |
| 2026-11-05 | 519 | 64,708.58 |
| **Total** | **2,543** | **339,002.85** |

Amounts mix the USD stores with the CAD store 1137, as the files do. Reports should group by `CURRENCY_CD`.

## Tests

`tests/test_dag.py` (10 tests, unittest with `DagBag`) checks the DAG file: it parses, has no cycles, every task has retries, the expected stages exist in the right order, the sensor has a timeout, only one run is active at a time, every SQL file exists, and the DAG has no credentials, paths or table names. It does not check the data; the reconcile task does that.

```
docker compose cp tests/. airflow-worker:/tmp/tests
docker compose exec airflow-worker python -m unittest discover -s /tmp/tests -v
```

## Evidence

| File | Shows |
|---|---|
| `01_backfill_all_green.png` | 5-day backfill, all runs green |
| `02_reconcile_log_day3.png` | Reconcile log for Day 3: all checks pass, quarantine alert raised |
| `03_reconciliation_all_days.png` | `AUD_RECONCILIATION` for all 5 days (55 checks) |
| `04_net_sales_per_day.png` | Gold net sales per day |
| `05_day3_rejects.png` | The 5 quarantined Day 3 rows |
| `06_scd2_item.png` | SCD2: item 10000020 Tees → Polos; new item 10000901 |
| `07_scd2_store_1112.png` | SCD2: store 1112 district 104 → 108 |
| `08_scd1_item_name.png` | SCD1: item 10000722 name corrected in place |
| `09_inventory_closed_rows.png` | Inventory rows closed, not deleted |
| `10_idempotency_before.png` / `11_idempotency_after.png` | Counts and totals before and after rerunning the backfill: identical |
| `12_tests_pass.png` | DAG tests passing |
| `13_dag_graph.png` | DAG graph |

## Limitations

- **Database:** Snowflake.
- **Sample period only:** `end_date` stops the DAG after 2026-11-05. Remove it for live daily loads.
- **Load order:** dates must be loaded in order. Rerunning the latest date or the whole range is safe. Rerunning a single older date reloads its Bronze, Silver, sales and audit rows, but does not rebuild later inventory history or SCD2 versions.
- **SCD1** overwrites the name on every version of an item or store (normal SCD1 behaviour).
- **Generated data:** not real extracts. The store master is sent every day so the sensor can wait for all four files.
- **Not loaded:** `FCT_PRICE` (no price feed), customers (every sale points to Unknown, -1), and the `AGG_SALES_MONTH_SUBCATG_DISTRICT` mart.
- **Calendar:** FY2025 to FY2027 (2 Feb 2025 to 29 Jan 2028).
- **Keys:** Snowflake does not enforce primary, unique or foreign keys, so uniqueness is checked by reconcile.
- **Answer files:** `sample_data/expected/` is only for checking results; the pipeline never reads it.
- **Tests** check structure, not data.

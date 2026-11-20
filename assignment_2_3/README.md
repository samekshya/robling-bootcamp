# Assignment 2.3 – Northline retail load (Airflow + Snowflake)

An Airflow pipeline that loads five days of Northline source files into the Gold model designed in Assignment 2.1, following the Bronze → Silver → Gold architecture from Assignment 2.2.

```
setup ─► wait_for_files (x4) ─► ingest_file (x4) ─► silver ─► gold_dimensions ─► gold_facts ─► reconcile
```

| Stage | What it does | Fails the run when |
|---|---|---|
| `wait_for_files` | One `FileSensor` per file (`<feed>_<YYYYMMDD>.csv`), reschedule mode, 1-hour timeout | A file has not arrived after 1 hour |
| `ingest_file` | Dynamically mapped, one task per file: `PUT` to the stage, `COPY INTO` Bronze (all text + file name, row number, load time) | **G1**: Bronze rows ≠ file rows |
| `silver.*` | Clean (trim, store codes, dates, currency), dedupe, check keys. Bad rows go to `SILVER.REJ_ROW` with gate and reason | Never for bad rows: they are quarantined and counted |
| `gold_dimensions.*` | Calendar, product and location dimensions, parents first | A SQL error |
| `gold_facts.*` | `FCT_SALES` and `FCT_INVENTORY` | A SQL error |
| `reconcile` | 11 checks written to `SILVER.AUD_RECONCILIATION` | Any check is `FAIL` |

## Project layout

```
assignment_2_3/
├── dags/retail_load_2_3.py          the DAG (no credentials, paths or table names)
├── include/sql/
│   ├── 00_setup.sql                 schemas, stage, Bronze/Silver/audit tables (IF NOT EXISTS)
│   ├── bronze/<feed>.sql            PUT + COPY INTO, one file per feed (4)
│   ├── silver/slv_*.sql             clean + quarantine, one file per table (5)
│   ├── gold/dim_*.sql, fct_*.sql    one file per Gold table load (13)
│   └── reconcile/reconcile.sql      reconciliation checks
├── sample_data/                     20 source files (5 days x 4 feeds) + DATA_NOTES.md
├── tools/generate_source_files.py   regenerates sample_data (fixed seed)
├── tests/test_dag.py                DAG tests
├── evidence/                        screenshots and reconciliation output
├── docker-compose.yaml
└── .env.example
```

## Data

The source files are dummy data generated for this assignment (`tools/generate_source_files.py`, fixed seed, so it always produces the same files). Items and stores come from the Northline reference data used in 2.1 and 2.2. Full description: [`sample_data/DATA_NOTES.md`](sample_data/DATA_NOTES.md).

The files are deliberately messy and contain planned changes:

| Day | What happens | Where it is handled |
|---|---|---|
| Every day | Store codes `1101` / `01101` / `NL-01101`, ISO and `M/D/YYYY` dates, `USD` / `usd` / `US$`, stray spaces, upper-case names, negative stock | Cleaned in Silver |
| 2 | Item 10000722 name corrected | SCD1: `DIM_ITEM.ITEM_NM` updated in place |
| 3 | 2 null items, 1 negative quantity, 1 unknown item, 1 duplicate line | Quarantined in `REJ_ROW` (5 rows), run continues |
| 3 | Store 1112 moves from district 104 to 108 | SCD2: new `DIM_LOCN` version |
| 4 | Item 10000020 moves from subclass Tees to Polos | SCD2: new `DIM_ITEM` version |
| 5 | New item 10000901 | New `DIM_ITEM` row |

## How to run

**Prerequisites:** Docker Desktop, a Snowflake account, and the Gold tables from Assignment 2.1 (`assignment_2_1/create_tables.sql`, run once in Snowflake: it creates the 15 tables in `RETAIL_DW`).

1. Copy `.env.example` to `.env` (it only holds the Airflow user id and the Snowflake provider package).
2. Start Airflow from this folder:
   ```
   docker compose up -d
   ```
   The compose file mounts `dags/`, `include/` (SQL) and `sample_data/` (read-only, as the landing folder `/opt/airflow/data/retail_landing`).
3. Open http://localhost:8080 and create two connections under **Admin → Connections**:

   | Connection ID | Type | Settings |
   |---|---|---|
   | `snowflake_conn` | Snowflake | Login and password of the Snowflake service user; Schema `PUBLIC`; Extra: `{"account": "<account>", "warehouse": "<warehouse>", "database": "<database>", "role": "<role>"}` |
   | `fs_landing` | File (path) | Extra: `{"path": "/opt/airflow/data/retail_landing"}` |

   Credentials live only in this connection, never in the repository.
4. Unpause `retail_load_2_3`. The DAG has `catchup=False` and an `end_date` of 5 Nov 2026 (the last sample day), so it does not create runs on its own: the sample days are loaded with a backfill.

## How to backfill

The five sample days are loaded in one backfill. Runs go one at a time in date order (`max_active_runs=1`), because SCD2 versions and inventory positions depend on the previous day.

**UI:** DAG page → **Trigger** → **Backfill**

| Field | Value |
|---|---|
| From | 2026-11-01 00:00 UTC |
| To | 2026-11-05 00:00 UTC |
| Reprocess behaviour | All Runs |

The UI shows times in the browser's time zone. In Nepal (UTC+05:45), midnight UTC is **05:45**, so enter 01 Nov 05:45 to 05 Nov 05:45. The window should show 5 runs.

**CLI:**
```
docker compose exec airflow-scheduler airflow backfill create --dag-id retail_load_2_3 \
    --from-date 2026-11-01 --to-date 2026-11-05 --reprocess-behavior completed
```

Only one backfill can run per DAG at a time (a second one returns `409 Conflict`).

## Idempotency

Running the same date again gives the same row counts and totals:

| Layer | How |
|---|---|
| Bronze, Silver, `REJ_ROW`, `FCT_SALES`, `AUD_RECONCILIATION` | Delete the business date and reload it, inside one transaction |
| Calendar, category, area, region, district | `MERGE` on the business key |
| `DIM_ITEM`, `DIM_LOCN` (SCD2) | A version is closed only if the run date is after its start date; a new version is inserted only when no current row exists |
| SCD1 name updates | Applied only when the run date is the latest loaded date, so rerunning an old date never brings back an old name |
| `FCT_INVENTORY` | Rows are only closed or added when the position differs from the open row. Rerunning the latest date finds no differences; older dates are skipped because their history is already built |

To prove it: run the backfill again with **All Runs** and compare the counts (`evidence/`).

## Error handling

| Situation | What happens |
|---|---|
| File missing | Sensor waits (reschedule mode, every 30 s) and fails after 1 hour |
| File only partly loaded | G1 check in `ingest_file` fails the task |
| Bad rows (null or unknown keys, bad numbers or dates, negative or zero quantity, duplicates) | Quarantined in `SILVER.REJ_ROW` with gate (`G3`/`G4`/`G5`), reason, file, row number and the raw record. The run continues |
| Too many rejects | `reconcile` raises an `ALERT` when more than 1 % of the sales file is quarantined |
| Gold does not tie to the files | `reconcile` fails the run |
| Temporary Snowflake error | Every task retries twice, 1 minute apart |

### Reconciliation checks

Written to `SILVER.AUD_RECONCILIATION` for every date and printed in the `reconcile` log:

- the business date exists in `DIM_DAY`
- sales rows: file = Silver + quarantine
- sales rows: Silver = Gold
- **net sales: file − quarantined rows = Gold `SUM(SLS_AMT)`**
- inventory rows: file = Silver + quarantine
- inventory positions: Silver = Gold rows valid on the date
- on-hand quantity: Silver = Gold
- no item, store or inventory position has two current rows
- quarantine rate (alert above 1 %)

Expected net sales per day (Gold):

| Date | Sales rows in Gold | Net sales |
|---|---|---|
| 2026-11-01 | 488 | 66,211.25 |
| 2026-11-02 | 552 | 71,196.44 |
| 2026-11-03 | 483 | 65,916.08 |
| 2026-11-04 | 501 | 70,970.50 |
| 2026-11-05 | 519 | 64,708.58 |

(The amounts mix USD stores with the one CAD store, 1137, exactly as the files do. Reports should group by `CURRENCY_CD`.)

## Tests

`tests/test_dag.py` (unittest, uses `DagBag`) checks that the DAG parses, has no cycles, every task has retries, the expected stages exist in the right order, the sensor has a timeout, only one run is active at a time, every SQL file exists, and the DAG file has no credentials, paths or table names.

```
docker compose cp tests/. airflow-worker:/tmp/tests
docker compose exec airflow-worker python -m unittest discover -s /tmp/tests -v
```

## Known limitations

- **Sample period only.** `end_date` stops the DAG after 5 Nov 2026. Remove it (and keep `catchup=False`) for live daily loads.
- **Dates must load in order.** SCD2 and inventory build on the previous day. Rerunning the latest date, or the whole range, is safe. Rerunning a single older date reloads its Bronze, Silver, sales and audit rows, but does not rebuild later inventory history or SCD2 versions.
- **SCD1 overwrites all versions.** A corrected item or store name is applied to every version of that item or store (normal SCD1 behaviour).
- **Generated data.** The source files are generated, not real extracts. The store master is sent daily so the sensor can wait for all four files every day.
- **Not loaded:** `FCT_PRICE` (no price feed in the sample), customers (every sale points to the Unknown customer, `-1`), and the `AGG_SALES_MONTH_SUBCATG_DISTRICT` mart.
- **Calendar range.** The fiscal calendar covers FY2025 to FY2027 (2 Feb 2025 to 29 Jan 2028).
- **Snowflake does not enforce keys.** Primary, unique and foreign keys are documentation only, so uniqueness is checked by `reconcile` instead.

## Evidence

See [`evidence/`](evidence/): backfill grid (all green), reconciliation output for the 5 days, Day 3 quarantine, SCD1 and SCD2 rows, idempotency before/after, and the test run.

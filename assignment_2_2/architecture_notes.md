# Architecture Notes: Assignment 2.2

Northline Retail data warehouse. These notes accompany the architecture diagram and `layer_inventory.csv`.

Reference flow: **Source files → Bronze → Silver → Gold → Marts**. All layers are Snowflake tables: Bronze in schema `BRONZE`, Silver in `SILVER`, Gold in `RETAIL_DW` (the Assignment 2.1 model) and the mart alongside Gold. Every object in `layer_inventory.csv` appears in exactly one layer: 24 Bronze tables, 10 Silver tables, 15 Gold tables and 1 mart.

## 1. Layer contracts

### Source files: what is loaded

The raw extract has 64 data files from 10 systems (`SOURCE_CATALOG.txt`, `EXTRACT_MANIFEST.csv`). Each file was assessed for relevance to the model.

| Decision | Files | Reason |
|---|---|---|
| Loaded and used for Gold | Xstore, NCR, OMS sales; RMS product, organisation, item, UPC and stock snapshots; RPM prices; Finance calendar | Each is the system of record for a Gold table. |
| Loaded to Bronze for checks only | RMS `CHAIN`, `CLASS`, `PACKITEM`, `TRAN_DATA`; store operations `LOCATION_ROSTER` | Not needed to build Gold, but used by quality checks (hierarchy validation, inventory reconciliation, location cross-check). |
| Not loaded | PIM `STYLE_EXPORT`; WMS `DC_ONHAND_SNAPSHOT` and `DC_MOVEMENT_DELTA`; RPAS `DEMAND_FORECAST_WK` | PIM has a second product tree that does not match RMS. WMS stock is in cases and already covered by RMS warehouse snapshots. RPAS forecasts have no fact table in the model. They can be added later if the model grows. |

### Bronze: raw, as landed

**Holds:** one table per source file type (`brz_` prefix), loaded exactly as received, every column as text, plus load metadata: `_SOURCE_FILE`, `_ROW_NUM` and `_LOAD_TS`.

**Guarantees**
- Files are stored unmodified, including header and trailer records, repeated headers, BOM characters and original encodings (cp1252 for the roster).
- Every file selected for loading is present with the row count stated in the manifest (G1).
- Every Gold row can be traced back to an exact file and line.
- Any run can be replayed from Bronze, which is the source of truth for reloads.

**Does not guarantee**
- Valid types, dates, keys or amounts.
- No duplicates, voids or junk rows.
- Consistent store or item codes across systems.

### Silver: clean and conformed

**Holds:** `slv_sales_line`, `slv_inventory_position`, `slv_price`, `slv_item`, `slv_item_upc`, `slv_merch_hierarchy`, `slv_org_hierarchy`, `slv_location`, `slv_fiscal_day`, and the quarantine table `rej_row`.

**Guarantees**
- Typed columns and one date format. Xstore ISO dates, NCR `M/D/YYYY`, OMS `YYYYMMDD` and UTC timestamps, RMS `D-MON-YY` and RPM `YYYY/MM/DD` are all parsed (G3).
- One key format per entity: store codes `1113`, `01113`, `NL-01113` become one location ID; items are resolved from the item number or, when blank, the UPC.
- A unique durable sales line key (system + store + business date + register + ticket + line), and unique natural keys for every other table (G4).
- One sales table for all three sales systems, with a `source_system` column.
- Returns carry a negative quantity; money is in dollars, not cents; currency codes `USD`, `US$`, `usd` become `USD`, and `CAD` is kept.
- One price per item, location and day: zone prices are applied to every location in the zone, and overlaps are resolved as clearance > promotion > regular.
- Every rejected row is in `rej_row` with its source file, row number, gate and reason code, so nothing is dropped silently.

**Does not guarantee**
- That item and location keys exist in the Gold dimensions (checked at G5).
- That voided, cancelled or post-close sales are excluded. Silver keeps them with flags, and G6 removes them on the way to Gold.
- That the calendar is complete (checked at G7).
- That inventory snapshots tie to the sum of daily movements. The source catalog says they will not (reported by G8).

### Gold: the 2.1 model

**Holds:** 12 dimension tables and 3 fact tables in `RETAIL_DW` (see the Assignment 2.1 `model_notes.md`).

**Guarantees**
- Every fact row has a valid surrogate key in each dimension (G5).
- Only completed sales and approved prices: no voids, cancelled or pending orders, and no sales on or after a store's close date (G6).
- A complete fiscal calendar with every day exactly once (G7).
- SCD2 versions in `DIM_ITEM` and `DIM_LOCN` do not overlap. The store 1112 district move on 15 Sep 2026 produces two `DIM_LOCN` versions, and each sale points to the version valid on its date.
- Missing dimension attributes use the reserved member (`-1` Unknown or Not applicable) instead of null.
- Amounts carry their currency (`CURRENCY_CD`); US and Canadian dollars are never mixed.

**Does not guarantee**
- Customer-level analysis: there is no customer feed, so every sale points to the Unknown customer.
- Coverage of PIM, WMS or RPAS data, which are not loaded.
- That rejected rows are included in totals. They are excluded and counted in `rej_row`.

### Marts

**Holds:** `AGG_SALES_MONTH_SUBCATG_DISTRICT` (fiscal period × subcategory × district × currency), designed in Assignment 2.1.

**Guarantees**
- Built only from Gold, never from Silver or Bronze, and rebuilt on every run.
- Totals equal `FCT_SALES` for the same fiscal period and currency (G9).

---

## 2. Quality gates

Nine rules, each at a named layer boundary with a failure action.

- **FAIL** stops the load. Used when the problem would make every result wrong.
- **QUARANTINE** moves the bad rows to `rej_row` with a gate and reason code, and continues with the rest.
- **ALERT** loads everything and notifies someone. Used for known or harmless issues.

| Gate | Boundary | Rule | Action | Evidence in the data |
|---|---|---|---|---|
| G1 | Source → Bronze | File is present, row count equals `EXTRACT_MANIFEST.csv`, encoding matches the manifest | FAIL | Xstore body is 274,245 rows and matches. NCR 2025 matches only when its repeated header line is counted (326,694 lines, 326,693 real rows). |
| G2 | Bronze → Silver | Xstore trailer count equals the body count. Repeated header lines and BOM characters are removed. | ALERT | Xstore trailer says 274,248, body has 274,245. NCR 2025 repeats its header once mid-file. Known source quirks, so alert instead of failing every run. |
| G3 | Bronze → Silver | Values cast to their types, dates parse and fall inside the load window, no junk rows, valid price ranges | QUARANTINE | Xstore: 1 row at store 9999 dated 1999. NCR 2025: 1 unreadable date. Inventory: 30 rows at store 9999 dated 1999 and 30 rows dated 2099. Prices: 10 backwards date ranges and 4 zero prices. |
| G4 | Bronze → Silver | Natural key is unique (sales durable key; inventory item + location + snapshot date; item; calendar day) | QUARANTINE | Extra copies: Xstore 1,132 (2,264 rows share a key), NCR 2025 58, NCR 2026 5, inventory 58, item 10000004 once, calendar day 2026-06-01 once. |
| G5 | Silver → Gold | Item and location keys resolve to a dimension | QUARANTINE | Blank item numbers recovered through UPC: Xstore 13,557 of 13,558, NCR 2025 22,028 of 22,284, NCR 2026 3,695 of 3,735. Item numbers not in `ITEM_MASTER`: Xstore 1,785, NCR 2025 2,051, NCR 2026 409. |
| G6 | Silver → Gold | Only real, completed sales and approved prices: no voids, cancelled or pending orders, no sales on or after a store's close date, no unapproved price events | QUARANTINE | Xstore 5,027 voided lines. NCR voids: 5,567 (2025) and 886 (2026). OMS: 756 cancelled and 523 pending. Store 1118: 3,851 lines on or after its 1 Oct 2026 close date. Prices: 5 pending or deleted events. |
| G7 | Silver → Gold | Fiscal calendar has no missing and no repeated day | FAIL | The seed has 1,092 rows but 1,091 distinct days: 2026-09-15 is missing and 2026-06-01 is repeated. |
| G8 | Silver (`rej_row` and cleaned data) | Unexpected rejects stay below the threshold; unusual values are reported | ALERT | Voids and post-close sales are expected and excluded from the rate. Also reported: 19,882 fractional stock quantities, negative stock down to -305,280, 16 prices corrected from cents, inventory snapshots that do not tie to daily movements. |
| G9 | Gold → Marts | Mart totals equal `FCT_SALES` totals for the same fiscal period and currency | FAIL | Prevents publishing a report that disagrees with the fact table. |

**Notes on the rules**

- **G3 window.** Business dates on 4 Nov come from transactions on the evening of 3 Nov (the business date rolls over). The window is 1 Aug to 4 Nov for each season, so these rows are kept.
- **G5 handling.** A fact row whose item or location cannot be resolved is quarantined, never loaded as Unknown, so real sales errors stay visible. A missing attribute on a dimension (for example the subclass of 23 items) uses the Unknown member (`-1`).
- **G6 close date.** A store's close date is treated as its first day closed, so sales on or after that date are excluded.
- **G8 threshold.** Starting value is 1% of a source's rows per run. This is a proposal to tune once real run data exists.
- **In Assignment 2.3** each gate becomes a SQL check run by an Airflow task: FAIL gates stop the DAG, QUARANTINE gates write to `rej_row`, and ALERT gates log a warning.

---

## 3. Retention policy

Principle: anything that can be rebuilt is kept for a shorter time; anything that cannot be rebuilt is kept.

| Layer | Retention | Why |
|---|---|---|
| Bronze | Keep all | The only copy of what the sources sent, and the source of truth for every reload. The full raw set is about 150 MB, so storage cost is small. |
| Silver | 12 months | Can be rebuilt from Bronze at any time. |
| `rej_row` | Until reprocessed, then 90 days | Rejected rows stay until the cause is fixed and they are reloaded; afterwards they are kept only for audit. |
| Gold | Keep all | The reporting layer. It holds history (SCD2 versions in `DIM_ITEM` and `DIM_LOCN`, positional facts). |
| Marts | None | Rebuilt from Gold on every run. |

Snowflake Time Travel (1 day, the default) adds a safety net against accidental deletes on every table. These values are proposals and can be changed if the instructor sets different rules.

---

## 4. Reload policy: reprocessing one bad day

**Scenario:** business date D (for example 14 Sep 2026) was loaded wrongly, or a gate flagged it.

**Why it works with the partitioning**
- Bronze keeps whole files, so the source rows for D are always available.
- `slv_sales_line` is clustered by business date, and `FCT_SALES` by `DAY_KY`.
- Both can be replaced for one day without touching other days.

**Steps**
1. **Find and fix the cause.** Read the gate output and the `rej_row` reasons for D. Fix the cause first (for example add a missing item mapping or correct a rule).
2. **Re-read Bronze.** Open the file(s) that contain D (the Xstore file, the NCR file for that season, the OMS file) and keep only rows whose business date is D.
3. **Replace Silver for D.** Delete D from `slv_sales_line` and that day's `rej_row` entries, then insert the re-transformed rows.
4. **Replace Gold for D.** Delete the `FCT_SALES` rows whose `DAY_KY` is D, then insert from Silver. Dimensions are not touched; if the fix is a dimension change, reload the dimension first.
5. **Rebuild the mart.** Rebuild the fiscal period that contains D in `AGG_SALES_MONTH_SUBCATG_DISTRICT`, then run G9.
6. **Reconcile.** Bronze rows for D must equal Silver rows plus `rej_row` rows for D. Otherwise the reload failed.

The steps are idempotent: deleting and re-inserting by date and durable sales key gives the same result if run twice.

**Other subjects**
- **Inventory.** Positional rows depend on the previous state, so a bad snapshot date is reloaded from that date forward (`slv_inventory_position` is clustered by snapshot date, `FCT_INVENTORY` by `EFF_START_DT`).
- **Prices and reference data.** Small full loads, so a reload is a full rerun.
- **Calendar.** Re-seed `slv_fiscal_day` and the calendar dimensions after Finance corrects the seed.

**Cost.** Reloading one day re-reads a whole Bronze file (the Xstore file is about 30 MB). This is acceptable at this volume, and it is the trade-off described in section 5.

---

## 5. Departure from the reference architecture

**Reference:** Bronze holds raw drops partitioned by date. Silver and Gold carry the logic.

**Departure:** Bronze is partitioned by **system and file**, not by business date. Business-date partitioning begins in Silver.

**Why**
- `EXTRACT_MANIFEST.csv` shows each sales system delivered as one file covering the whole range (for example the Xstore file covers 1 Aug to 3 Nov 2026), not as daily files.
- Splitting those files by date at landing would mean editing Bronze, which breaks "raw, as landed", and would separate the Xstore header and trailer records that gate G2 needs.
- The business date is only reliable after parsing, and the date formats differ by system (ISO, `M/D/YYYY`, `YYYYMMDD`, UTC timestamps), so it is derived in Silver.

**Trade-off:** reloading one day re-reads a whole file. At this volume (the largest file is about 30 MB) that cost is small, and reloads stay correct and idempotent. If the sources move to daily delivery files, Bronze can be partitioned by file date without changing Silver or Gold.
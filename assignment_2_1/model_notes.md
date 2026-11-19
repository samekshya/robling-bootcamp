# Model Notes: Retail Data Warehouse (Assignment 2.1)

## 1. Model overview

This is a snowflake-schema model for Northline Retail, with **12 dimension tables and 3 fact tables**, built in Snowflake in the schema `SNOWFLAKE_LEARNING_DB.RETAIL_DW`.

| Area | Tables |
|---|---|
| Product hierarchy | `DIM_CATG` → `DIM_SUBCATG` → `DIM_ITEM` |
| Location hierarchy | `DIM_AREA` → `DIM_REGN` → `DIM_DISTRICT` → `DIM_LOCN` |
| Calendar (fiscal 4-5-4) | `DIM_YEAR` → `DIM_MONTH` → `DIM_DAY`, and `DIM_YEAR` → `DIM_WEEK` → `DIM_DAY` |
| Customer | `DIM_CUSTOMER` |
| Transaction fact | `FCT_SALES` |
| Positional facts | `FCT_INVENTORY`, `FCT_PRICE` |

**Why a snowflake schema:** each hierarchy level has its own table instead of being flattened into one wide dimension. This avoids repeating parent values (for example, a category name on every item row) and makes each level easy to maintain.

**Naming standard:** `DIM_` / `FCT_` table prefixes; column suffixes `_KY` (surrogate key), `_ID` (business key), `_NM` (name), `_NUM` (number), `_CD` (code), `_AMT` (amount), `_QTY` (quantity), `_DT` (date), `_FLG` (flag), `_TS` (timestamp).

**Key rule:** fact tables join to dimensions only through surrogate keys (`_KY`), never through business keys (`_ID`). In SCD2 tables the same business key appears once per version, so only the surrogate key points to one exact version.

### Source of each table

The model was checked against the raw source extracts (`SOURCE_CATALOG.txt`, `EXTRACT_MANIFEST.csv`).

| Table | Source |
|---|---|
| `DIM_CATG` | RMS `DEPS.csv` (department) |
| `DIM_SUBCATG` | RMS `SUBCLASS.csv` (subclass) |
| `DIM_ITEM` | RMS `ITEM_MASTER.csv`, `ITEM_MASTER_HIST.csv`, `ITEM_UPC.csv` |
| `DIM_AREA`, `DIM_REGN`, `DIM_DISTRICT` | RMS `AREA.csv`, `REGION.csv`, `DISTRICT.csv` |
| `DIM_LOCN` | RMS `STORE.csv`, `WH.csv`, `STORE_DISTRICT_MOVE.csv` |
| `DIM_YEAR`, `DIM_MONTH`, `DIM_WEEK`, `DIM_DAY` | Finance `FISCAL_CALENDAR_SEED.csv` |
| `DIM_CUSTOMER` | No source feed (reserved Unknown row only) |
| `FCT_SALES` | Xstore POS, NCR Counterpoint, Ecommerce OMS |
| `FCT_INVENTORY` | RMS `soh_full` stock-on-hand snapshots |
| `FCT_PRICE` | RPM `PRICE_EVENTS.csv` and `PRICE_ZONE_LOC.csv` |

---

## 2. Grain of each fact table

The grain states exactly what one row in a fact table represents. It was decided before choosing any columns, because it determines which dimensions and measures belong in the table.

| Fact | Type | Grain |
|---|---|---|
| `FCT_SALES` | Transaction | One row per sales transaction line (`TXN_ID` + `TXN_LINE_ID`): one item, at one location, on one day, for one customer. |
| `FCT_INVENTORY` | Positional | One row per item and location for each period (`EFF_START_DT` to `EFF_END_DT`) during which the on-hand quantity stayed the same. |
| `FCT_PRICE` | Positional | One row per item and location for each price period, starting on `DAY_KY` and valid from `EFF_START_DT` to `EFF_END_DT`. |

**Transaction vs positional facts:**

- A **transaction fact** records events. Every sale is a new row, and rows are never updated. Measures (`SLS_QTY`, `SLS_AMT`) can be summed across any dimension, within one currency.
- A **positional fact** records a state that lasts over time. A new row is added only when the value changes, and the previous row's `EFF_END_DT` is closed. This keeps the tables small, because unchanged stock or prices are not repeated every day.

**Example (`FCT_SALES`):** a receipt with 2 tees and 1 polo produces two rows: (line 1, tee, qty 2) and (line 2, polo, qty 1).

**Note on additivity:** `ONHAND_QTY` and `INV_VALUE_AMT` are **semi-additive**. They can be summed across items and locations, but not across time (adding Monday's stock to Tuesday's stock is meaningless). To report stock on a date, select the row whose date range contains that date. `PRICE_AMT` is **non-additive**: prices are compared or averaged, never summed. Amounts in different currencies (`CURRENCY_CD`) are never added together without conversion.

---

## 3. SCD decisions

Only `DIM_ITEM` and `DIM_LOCN` are SCD2 (they keep history with a current flag and effective dates). Every other dimension is SCD1 (changes overwrite the old value).

Column types used below:

- **Key**: surrogate key (`_KY`) or business key (`_ID`). Not an SCD attribute.
- **SCD1**: overwritten when it changes; no history.
- **SCD2**: a change creates a new row (new version); the old row is closed.
- **Technical**: audit columns or SCD2 machinery, maintained by the load process.

`INSERT_TS` and `UPDATE_TS` are on every dimension and fact table and are always **Technical**.

### Product hierarchy

| Dimension | Column | Type |
|---|---|---|
| `DIM_CATG` | `CATG_KY`, `CATG_ID` | Key |
| | `CATG_NM` | SCD1 |
| `DIM_SUBCATG` | `SUBCATG_KY`, `SUBCATG_ID` | Key |
| | `SUBCATG_NM` | SCD1 |
| | `CATG_KY` (parent category) | SCD1 |
| `DIM_ITEM` | `ITEM_KY`, `ITEM_ID` | Key |
| | `ITEM_NM` | SCD1 |
| | `BRAND_NM` | **SCD2** |
| | `SUBCATG_KY` (parent subcategory) | **SCD2** |
| | `CURR_FLG`, `EFF_START_DT`, `EFF_END_DT` | Technical (SCD2 mechanics) |

### Location hierarchy

| Dimension | Column | Type |
|---|---|---|
| `DIM_AREA` | `AREA_KY`, `AREA_ID` | Key |
| | `AREA_NM` | SCD1 |
| `DIM_REGN` | `REGN_KY`, `REGN_ID` | Key |
| | `REGN_NM`, `COUNTRY_NM` | SCD1 |
| | `AREA_KY` (parent area) | SCD1 |
| `DIM_DISTRICT` | `DISTRICT_KY`, `DISTRICT_ID` | Key |
| | `DISTRICT_NM` | SCD1 |
| | `REGN_KY` (parent region) | SCD1 |
| `DIM_LOCN` | `LOCN_KY`, `LOCN_ID` | Key |
| | `LOCN_NM`, `LOCN_TYPE_CD` | SCD1 |
| | `DISTRICT_KY` (parent district) | **SCD2** |
| | `CURR_FLG`, `EFF_START_DT`, `EFF_END_DT` | Technical (SCD2 mechanics) |

### Calendar and customer

| Dimension | Column | Type |
|---|---|---|
| `DIM_YEAR` | `YEAR_KY`, `YEAR_ID` | Key |
| | `YEAR_START_DT`, `YEAR_END_DT` | SCD1 |
| `DIM_MONTH` | `MONTH_KY`, `MONTH_ID` | Key |
| | `MONTH_NUM`, `MONTH_NM`, `WEEKS_IN_MONTH_NUM`, `MONTH_START_DT`, `MONTH_END_DT` | SCD1 |
| | `YEAR_KY` (parent fiscal year) | SCD1 |
| `DIM_WEEK` | `WEEK_KY`, `WEEK_ID` | Key |
| | `WEEK_NUM`, `WEEK_START_DT`, `WEEK_END_DT` | SCD1 |
| | `YEAR_KY` (parent fiscal year) | SCD1 |
| `DIM_DAY` | `DAY_KY`, `DAY_ID` | Key |
| | `FULL_DT`, `DAY_NUM`, `HOLIDAY_NM` | SCD1 |
| | `WEEK_KY`, `MONTH_KY` (parents) | SCD1 |
| `DIM_CUSTOMER` | `CUSTOMER_KY`, `CUSTOMER_ID` | Key |
| | `CUSTOMER_NM`, `LOYALTY_FLG` | SCD1 |

### Reason for each SCD2 choice

| SCD2 attribute | Reason |
|---|---|
| `DIM_ITEM.BRAND_NM` | Past sales must stay under the brand the item had when it was sold, so brand reports for earlier periods do not change when a brand changes. |
| `DIM_ITEM.SUBCATG_KY` | When an item moves to another subcategory, its earlier sales must remain in the old subcategory (and therefore the old category). |
| `DIM_LOCN.DISTRICT_KY` | When a store is reassigned to another district, its earlier sales must remain in the old district (and therefore the old region and area). |

**Why everything else is SCD1:** a change is either a correction (for example a spelling fix), a value that never changes (calendar dates), or a change that should apply to all history (renaming a category, area, region or district should rename it in every report, past and present).

**How an SCD2 change works (real case from the data):** `STORE_DISTRICT_MOVE.csv` records that store 1112 moved from district 104 (Southeast D2) to district 108 (Plains D2) on 15 Sep 2026. `STORE.csv` only shows the current district, so both files are combined (surrogate key values are illustrative):

| LOCN_KY | LOCN_ID | District | CURR_FLG | EFF_START_DT | EFF_END_DT |
|---|---|---|---|---|---|
| 12 | 1112 | 104 Southeast D2 | FALSE | 2014-09-06 | 2026-09-14 |
| 41 | 1112 | 108 Plains D2 | TRUE | 2026-09-15 | 9999-12-31 |

Sales before 15 Sep 2026 point to `LOCN_KY = 12` and stay in Southeast; sales from 15 Sep point to `LOCN_KY = 41` and count for Plains. Because of this, `ITEM_ID` and `LOCN_ID` are not unique on their own; the unique keys are `(ITEM_ID, EFF_START_DT)` and `(LOCN_ID, EFF_START_DT)`.

**Note on items:** `ITEM_MASTER_HIST.csv` contains 43 changes, but none of them change the brand or the subclass (38 change nothing, the rest are status changes). The SCD2 design for `DIM_ITEM` is kept so future changes are handled correctly, but the current data produces one version per item.

---

## 4. Aggregate table

**`AGG_SALES_MONTH_SUBCATG_DISTRICT`**

| Item | Detail |
|---|---|
| Grain | One row per fiscal period (month), subcategory, district and currency. |
| Keys | `MONTH_KY`, `SUBCATG_KY`, `DISTRICT_KY`, `CURRENCY_CD` (composite primary key; the first three are foreign keys to their dimensions). |
| Measures | `SLS_QTY`, `SLS_AMT`, `TXN_CNT`, plus `INSERT_TS` and `UPDATE_TS`. |
| Source | Built from `FCT_SALES` joined to `DIM_DAY`, `DIM_ITEM` and `DIM_LOCN`. It adds no new information; it only pre-summarises existing data. |

**Why this grain:**

- The most common management question is "how much did each product group sell in each district, each fiscal period?". This table answers it directly, without scanning every sales line.
- Fiscal period, subcategory and district are the middle levels of the three main hierarchies, so the table stays small but can still be rolled up to fiscal year, category, region and area.
- The subcategory and district are taken from the item and location **version** linked to each sale, so the aggregate respects SCD2 history: sales made by store 1112 before 15 Sep 2026 stay in its old district.
- `CURRENCY_CD` is part of the grain so US and Canadian dollars are never added together.

**Caveats:**

- `TXN_CNT` is a distinct count of receipts, so it is **not additive** across subcategories or districts (a receipt with items from two subcategories counts once in each). Use `SLS_QTY` and `SLS_AMT` for roll-ups.
- This table is a design decision documented here. It is not created in `create_tables.sql`; it is built in the Marts layer (Assignment 2.2) during the load in Assignment 2.3.

Illustrative definition and load:

```sql
CREATE TABLE AGG_SALES_MONTH_SUBCATG_DISTRICT (
    MONTH_KY     INTEGER       NOT NULL,
    SUBCATG_KY   INTEGER       NOT NULL,
    DISTRICT_KY  INTEGER       NOT NULL,
    CURRENCY_CD  VARCHAR(3)    NOT NULL,
    SLS_QTY      INTEGER       NOT NULL,
    SLS_AMT      NUMERIC(16,2) NOT NULL,
    TXN_CNT      INTEGER       NOT NULL,
    INSERT_TS    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_AGG_SALES_MSD PRIMARY KEY (MONTH_KY, SUBCATG_KY, DISTRICT_KY, CURRENCY_CD)
);

INSERT INTO AGG_SALES_MONTH_SUBCATG_DISTRICT
    (MONTH_KY, SUBCATG_KY, DISTRICT_KY, CURRENCY_CD, SLS_QTY, SLS_AMT, TXN_CNT)
SELECT d.MONTH_KY,
       i.SUBCATG_KY,
       l.DISTRICT_KY,
       s.CURRENCY_CD,
       SUM(s.SLS_QTY),
       SUM(s.SLS_AMT),
       COUNT(DISTINCT s.TXN_ID)
FROM FCT_SALES s
JOIN DIM_DAY  d ON s.DAY_KY  = d.DAY_KY
JOIN DIM_ITEM i ON s.ITEM_KY = i.ITEM_KY
JOIN DIM_LOCN l ON s.LOCN_KY = l.LOCN_KY
GROUP BY d.MONTH_KY, i.SUBCATG_KY, l.DISTRICT_KY, s.CURRENCY_CD;
```

---

## 5. Assumptions about the source data

**Keys and identifiers**

1. RMS provides stable numeric business keys (`_ID`) for departments, subclasses, items, areas, regions, districts and locations. Other systems use different codes for the same thing (store `1113`, `01113`, `NL-01113`; items as RMS number or UPC); these are converted to the RMS key before loading Gold.
2. POS ticket numbers restart every day, so `TXN_ID` is a **durable key** built from source system, store, business date, register and ticket number (for example `XSTORE-1101-20260801-5-1`). Together with `TXN_LINE_ID` it is unique and is stored in `FCT_SALES` as a **degenerate dimension** (no separate dimension table, because there is nothing else to describe about a receipt).
3. Surrogate keys (`_KY`) are generated by the warehouse (`AUTOINCREMENT`) and have no business meaning.
4. Reserved members use `_KY = -1`: "Unknown" for a missing attribute (for example an item whose subclass is not in the hierarchy) and "Not applicable" for a level that does not exist (for example the district of a warehouse). They are inserted during the load (Assignment 2.3).

**Product and location hierarchies**

5. RMS product hierarchy is division > group > department > class > subclass > item. The model uses **department** as `DIM_CATG` and **subclass** as `DIM_SUBCATG`; division, group and class are not separate tables. 23 items point to a subclass that is not in `SUBCLASS.csv`; they are kept and linked to the Unknown subcategory.
6. RMS location hierarchy is chain > area > region > district > location. There is only one chain, so it is not a table; area, region and district are.
7. `DIM_LOCN` holds stores (`LOCN_TYPE_CD = 'S'`), the three distribution centres (`'W'`, from `WH.csv`) and the web store 9901 (`'E'`). Warehouses and the web store have no real district, so they point to the "Not applicable" district (`-1`). Row `503` in `STORE.csv` is a warehouse listed by mistake and is taken from `WH.csv` instead.
8. Both hierarchies are strict: each item has one subcategory, each subcategory one category, each location one district, each district one region, and each region one area.
9. Category, subcategory, area, region and district changes are treated as corrections and are overwritten (SCD1). History is kept only on the rows that point to them (`DIM_ITEM`, `DIM_LOCN`).
10. `LOCATION_ROSTER.csv` (store operations) is not used to build `DIM_LOCN`: it uses different codes and region names, misses store 1120 and contains a non-existent store. RMS is the system of record.

**History (SCD2)**

11. The source provides the date each item or location change took effect. The load closes the old row (`CURR_FLG = FALSE`, `EFF_END_DT` = the day before the change) and inserts a new row with `CURR_FLG = TRUE` and `EFF_END_DT = 9999-12-31`.
12. Each item or location has exactly one current row, and its versions never overlap in time.
13. Every fact row points to the dimension version valid at the time of the event: the sale date for `FCT_SALES`, and the start of the period for `FCT_INVENTORY` and `FCT_PRICE`.

**Facts**

14. `FCT_SALES.UNIT_PRICE_AMT` is the price actually charged at the till; `FCT_PRICE.PRICE_AMT` is the list price in force. They can differ because of discounts or promotions, so both are stored.
15. `SLS_AMT` = `SLS_QTY` × `UNIT_PRICE_AMT` for each line, after any line-level discount. Returns are stored as negative quantities and amounts, whatever convention the source system uses.
16. Amounts are stored in the location's currency, given by `CURRENCY_CD`: `USD` for US stores and `CAD` for the two Ottawa stores (1137, 1138). Source spellings `USD`, `US$` and `usd` are all stored as `USD`. No currency conversion is done in Gold.
17. `FCT_INVENTORY` is built from the weekly RMS stock-on-hand snapshots. A new row is created only when the on-hand quantity for an item and location changes. Time is held in `EFF_START_DT` and `EFF_END_DT` only, so the table has no `DAY_KY`. The daily movement file (`TRAN_DATA`) is not used for Gold, because the source catalog states that snapshots do not tie to the sum of daily movements.
18. `ONHAND_QTY` is `NUMERIC(12,2)` because the source sends fractional quantities. Negative stock is kept as RMS reports it (a real condition in retail systems, caused by selling before receipts are recorded).
19. `FCT_PRICE` keeps one row per item, location and price period. RPM sets prices per **zone**; each zone price is applied to every location in the zone. When regular, promotional and clearance prices overlap, the price in force is chosen in the order clearance > promotion > regular. `DAY_KY` is the day the price started.
20. There is no customer feed. `DIM_CUSTOMER` holds only the reserved row `CUSTOMER_KY = -1`, `CUSTOMER_ID = 0`, "Unknown customer", and every sale points to it. The table is kept so a customer feed can be added later without changing `FCT_SALES`.

**Calendar**

21. The calendar is the retail **4-5-4 fiscal calendar** from `FISCAL_CALENDAR_SEED.csv`, not the ISO calendar. Weeks run Sunday to Saturday. A fiscal year has 52 weeks and starts on a Sunday in early February (FY2025 = 2 Feb 2025 to 31 Jan 2026). `DIM_MONTH` holds the 12 fiscal periods of 4 or 5 weeks each (4-5-4 per quarter), and `DIM_WEEK` holds fiscal weeks 1 to 52.
22. Because every fiscal week and period falls entirely inside one fiscal year, `YEAR_KY` means the same fiscal year in both `DIM_MONTH` and `DIM_WEEK`.
23. The calendar is split into year, month (period), week and day tables (snowflaked), with two paths from the day: day → week → year and day → period → year. In a 4-5-4 calendar every week falls inside one period, so week could also sit under period; the two separate paths are kept from the original design so reports can roll up by week or by period directly from the day.

**Platform**

24. The model is built on Snowflake. Snowflake records primary, unique and foreign key constraints but does not enforce them (only `NOT NULL` is enforced). Uniqueness, a single current row per SCD2 member, and referential integrity are therefore guaranteed by the load process; the constraints are declared to document the model.
25. `CHECK` constraints (for example `EFF_END_DT >= EFF_START_DT`) are not supported in Snowflake, so they are not in the script. These rules are enforced by the load process instead.
26. `create_tables.sql` drops and recreates all tables, so it can be re-run from scratch at any time.

---

## 6. Deliverables

| File | Purpose |
|---|---|
| `create_tables.sql` | Creates all 15 tables in Snowflake in one run (re-runnable). |
| `erd_assignment_2_1.drawio` | Editable ER diagram: dimensions in blue, facts in green. |
| `erd_assignment_2_1.png` | Image export of the ER diagram. |
| `model_notes.md` | This document: grain, SCD decisions, aggregate table and assumptions. |

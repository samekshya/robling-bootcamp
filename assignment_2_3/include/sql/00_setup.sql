-- =====================================================================
-- 00_setup.sql
-- One-time setup for the Assignment 2.3 pipeline. Safe to run any number
-- of times: every statement uses IF NOT EXISTS or MERGE.
-- Runs in the database set on the Airflow connection (snowflake_conn).
--
-- Layers:
--   BRONZE     raw files, as landed (every column text + load metadata)
--   SILVER     cleaned, typed, conformed rows + REJ_ROW quarantine
--   RETAIL_DW  Gold: the Assignment 2.1 model (created by create_tables.sql)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Schemas
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS BRONZE;
CREATE SCHEMA IF NOT EXISTS SILVER;

-- ---------------------------------------------------------------------
-- Stage and file format: where files are uploaded (PUT) and how they
-- are read. Values are kept exactly as sent: no trimming, empty fields
-- stay empty strings, so Silver can see and count every defect.
-- ---------------------------------------------------------------------
CREATE FILE FORMAT IF NOT EXISTS BRONZE.CSV_RAW
    TYPE = CSV
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    EMPTY_FIELD_AS_NULL = FALSE
    TRIM_SPACE = FALSE
    ENCODING = 'UTF8';

CREATE STAGE IF NOT EXISTS BRONZE.LANDING_STAGE
    FILE_FORMAT = BRONZE.CSV_RAW;

-- ---------------------------------------------------------------------
-- BRONZE tables: one per source file type.
-- Every source column is VARCHAR so no row can fail on a bad value.
-- Load metadata makes every row traceable to its file and line.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS BRONZE.BRZ_ITEM_MASTER (
    ITEM_ID         VARCHAR,
    ITEM_NAME       VARCHAR,
    BRAND_NAME      VARCHAR,
    SUBCLASS_ID     VARCHAR,
    SUBCLASS_NAME   VARCHAR,
    DEPT_ID         VARCHAR,
    DEPT_NAME       VARCHAR,
    UNIT_COST       VARCHAR,
    UNIT_RETAIL     VARCHAR,
    STATUS          VARCHAR,
    _SOURCE_FILE    VARCHAR       NOT NULL,
    _ROW_NUM        NUMBER        NOT NULL,
    _BUSINESS_DATE  DATE          NOT NULL,
    _LOAD_TS        TIMESTAMP_NTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS BRONZE.BRZ_STORE_MASTER (
    STORE_ID        VARCHAR,
    STORE_NAME      VARCHAR,
    STORE_TYPE      VARCHAR,
    DISTRICT_ID     VARCHAR,
    DISTRICT_NAME   VARCHAR,
    REGION_ID       VARCHAR,
    REGION_NAME     VARCHAR,
    AREA_ID         VARCHAR,
    AREA_NAME       VARCHAR,
    COUNTRY         VARCHAR,
    CITY            VARCHAR,
    CURRENCY_CODE   VARCHAR,
    OPEN_DATE       VARCHAR,
    CLOSE_DATE      VARCHAR,
    _SOURCE_FILE    VARCHAR       NOT NULL,
    _ROW_NUM        NUMBER        NOT NULL,
    _BUSINESS_DATE  DATE          NOT NULL,
    _LOAD_TS        TIMESTAMP_NTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS BRONZE.BRZ_POS_SALES (
    TRANSACTION_ID  VARCHAR,
    LINE_NUMBER     VARCHAR,
    BUSINESS_DATE   VARCHAR,
    STORE_ID        VARCHAR,
    ITEM_ID         VARCHAR,
    QUANTITY        VARCHAR,
    UNIT_PRICE      VARCHAR,
    DISCOUNT_AMOUNT VARCHAR,
    NET_AMOUNT      VARCHAR,
    CURRENCY_CODE   VARCHAR,
    _SOURCE_FILE    VARCHAR       NOT NULL,
    _ROW_NUM        NUMBER        NOT NULL,
    _BUSINESS_DATE  DATE          NOT NULL,
    _LOAD_TS        TIMESTAMP_NTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS BRONZE.BRZ_INVENTORY_SNAPSHOT (
    SNAPSHOT_DATE   VARCHAR,
    STORE_ID        VARCHAR,
    ITEM_ID         VARCHAR,
    ON_HAND_QTY     VARCHAR,
    UNIT_COST       VARCHAR,
    _SOURCE_FILE    VARCHAR       NOT NULL,
    _ROW_NUM        NUMBER        NOT NULL,
    _BUSINESS_DATE  DATE          NOT NULL,
    _LOAD_TS        TIMESTAMP_NTZ NOT NULL
);

-- ---------------------------------------------------------------------
-- SILVER tables: typed, trimmed and conformed. One row per natural key
-- and business date. Rebuilt per date (delete + insert), so reruns are
-- idempotent.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS SILVER.SLV_ITEM (
    BUSINESS_DATE   DATE          NOT NULL,
    ITEM_ID         NUMBER        NOT NULL,
    ITEM_NAME       VARCHAR(150)  NOT NULL,
    BRAND_NAME      VARCHAR(100),
    SUBCLASS_ID     NUMBER        NOT NULL,
    SUBCLASS_NAME   VARCHAR(100)  NOT NULL,
    DEPT_ID         NUMBER        NOT NULL,
    DEPT_NAME       VARCHAR(100)  NOT NULL,
    UNIT_COST       NUMBER(12,2),
    UNIT_RETAIL     NUMBER(12,2),
    STATUS_CD       VARCHAR(1),
    _SOURCE_FILE    VARCHAR       NOT NULL,
    _LOAD_TS        TIMESTAMP_NTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS SILVER.SLV_STORE (
    BUSINESS_DATE   DATE          NOT NULL,
    STORE_ID        NUMBER        NOT NULL,
    STORE_NAME      VARCHAR(150)  NOT NULL,
    STORE_TYPE_CD   VARCHAR(1)    NOT NULL,
    DISTRICT_ID     NUMBER        NOT NULL,
    DISTRICT_NAME   VARCHAR(100)  NOT NULL,
    REGION_ID       NUMBER        NOT NULL,
    REGION_NAME     VARCHAR(100)  NOT NULL,
    AREA_ID         NUMBER        NOT NULL,
    AREA_NAME       VARCHAR(100)  NOT NULL,
    COUNTRY_CD      VARCHAR(2),
    CITY_NAME       VARCHAR(100),
    CURRENCY_CD     VARCHAR(3)    NOT NULL,
    OPEN_DT         DATE,
    CLOSE_DT        DATE,
    _SOURCE_FILE    VARCHAR       NOT NULL,
    _LOAD_TS        TIMESTAMP_NTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS SILVER.SLV_SALES_LINE (
    BUSINESS_DATE   DATE          NOT NULL,
    TXN_ID          VARCHAR(60)   NOT NULL,
    TXN_LINE_ID     NUMBER        NOT NULL,
    STORE_ID        NUMBER        NOT NULL,
    ITEM_ID         NUMBER        NOT NULL,
    SLS_QTY         NUMBER        NOT NULL,
    UNIT_PRICE_AMT  NUMBER(12,2)  NOT NULL,
    DISCOUNT_AMT    NUMBER(12,2)  NOT NULL,
    SLS_AMT         NUMBER(14,2)  NOT NULL,
    CURRENCY_CD     VARCHAR(3)    NOT NULL,
    _SOURCE_FILE    VARCHAR       NOT NULL,
    _ROW_NUM        NUMBER        NOT NULL,
    _LOAD_TS        TIMESTAMP_NTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS SILVER.SLV_INVENTORY_POSITION (
    BUSINESS_DATE   DATE          NOT NULL,
    STORE_ID        NUMBER        NOT NULL,
    ITEM_ID         NUMBER        NOT NULL,
    ONHAND_QTY      NUMBER(12,2)  NOT NULL,
    UNIT_COST       NUMBER(12,2)  NOT NULL,
    _SOURCE_FILE    VARCHAR       NOT NULL,
    _LOAD_TS        TIMESTAMP_NTZ NOT NULL
);

-- Quarantine: every rejected row, with the gate and reason, never dropped.
CREATE TABLE IF NOT EXISTS SILVER.REJ_ROW (
    BUSINESS_DATE   DATE          NOT NULL,
    SOURCE_TABLE    VARCHAR(100)  NOT NULL,
    SOURCE_FILE     VARCHAR       NOT NULL,
    ROW_NUM         NUMBER        NOT NULL,
    GATE_CD         VARCHAR(10)   NOT NULL,
    REASON_CD       VARCHAR(50)   NOT NULL,
    RAW_RECORD      VARIANT,
    LOAD_TS         TIMESTAMP_NTZ NOT NULL
);

-- Reconciliation results: one row per check per business date and run.
-- This is the evidence output for the reconcile task.
CREATE TABLE IF NOT EXISTS SILVER.AUD_RECONCILIATION (
    BUSINESS_DATE   DATE          NOT NULL,
    CHECK_NM        VARCHAR(100)  NOT NULL,
    SOURCE_VALUE    NUMBER(18,2),
    TARGET_VALUE    NUMBER(18,2),
    DIFFERENCE      NUMBER(18,2),
    STATUS_CD       VARCHAR(10)   NOT NULL,
    RUN_ID          VARCHAR(250),
    CHECKED_TS      TIMESTAMP_NTZ NOT NULL
);

-- ---------------------------------------------------------------------
-- GOLD reserved member: every sale points to the Unknown customer,
-- because the source has no customer feed. MERGE keeps it to one row.
-- ---------------------------------------------------------------------
MERGE INTO RETAIL_DW.DIM_CUSTOMER t
USING (SELECT -1 AS CUSTOMER_KY, 0 AS CUSTOMER_ID,
              'Unknown customer' AS CUSTOMER_NM, FALSE AS LOYALTY_FLG) s
   ON t.CUSTOMER_KY = s.CUSTOMER_KY
WHEN NOT MATCHED THEN
    INSERT (CUSTOMER_KY, CUSTOMER_ID, CUSTOMER_NM, LOYALTY_FLG)
    VALUES (s.CUSTOMER_KY, s.CUSTOMER_ID, s.CUSTOMER_NM, s.LOYALTY_FLG);

-- =====================================================================
-- Bronze load: store_master_YYYYMMDD.csv  ->  BRONZE.BRZ_STORE_MASTER
-- Rendered by the DAG with:
--   local_file  full path of the file inside the Airflow worker
--   file_name   file name, e.g. store_master_20261101.csv
--   ds          business date, e.g. 2026-11-01
-- Idempotent: the business date is deleted and reloaded in one
-- transaction, so a rerun replaces the day instead of duplicating it.
-- =====================================================================

-- Upload the file to the stage, in a folder per business date.
PUT 'file://{{ local_file }}' @BRONZE.LANDING_STAGE/{{ ds }}/
    AUTO_COMPRESS = TRUE OVERWRITE = TRUE;

BEGIN;

-- Remove anything already loaded for this business date.
DELETE FROM BRONZE.BRZ_STORE_MASTER
WHERE _BUSINESS_DATE = TO_DATE('{{ ds }}');

-- Load the file as-is (every column as text) plus load metadata.
COPY INTO BRONZE.BRZ_STORE_MASTER (
    STORE_ID,
    STORE_NAME,
    STORE_TYPE,
    DISTRICT_ID,
    DISTRICT_NAME,
    REGION_ID,
    REGION_NAME,
    AREA_ID,
    AREA_NAME,
    COUNTRY,
    CITY,
    CURRENCY_CODE,
    OPEN_DATE,
    CLOSE_DATE,
    _SOURCE_FILE,
    _ROW_NUM,
    _BUSINESS_DATE,
    _LOAD_TS
)
FROM (
    SELECT $1,
           $2,
           $3,
           $4,
           $5,
           $6,
           $7,
           $8,
           $9,
           $10,
           $11,
           $12,
           $13,
           $14,
           METADATA$FILENAME,
           METADATA$FILE_ROW_NUMBER,
           TO_DATE('{{ ds }}'),
           CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
    FROM @BRONZE.LANDING_STAGE/{{ ds }}/{{ file_name }}.gz
)
FILE_FORMAT = (FORMAT_NAME = 'BRONZE.CSV_RAW')
FORCE = TRUE
ON_ERROR = 'ABORT_STATEMENT';

COMMIT;

-- Row count for the G1 check (compared with the file's row count).
SELECT COUNT(*) AS ROWS_LOADED
FROM BRONZE.BRZ_STORE_MASTER
WHERE _BUSINESS_DATE = TO_DATE('{{ ds }}');

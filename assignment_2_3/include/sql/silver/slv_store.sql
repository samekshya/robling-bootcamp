-- =====================================================================
-- Silver: BRONZE.BRZ_STORE_MASTER -> SILVER.SLV_STORE  (+ SILVER.REJ_ROW)
-- One business date per run ({{ ds }}). Idempotent: delete + rebuild.
--
-- Cleaning: store codes 1101 / 01101 / NL-01101 -> 1101, double spaces
-- collapsed, currency USD / usd / US$ -> USD (CAD kept), dates typed.
-- Gates:  G3 missing or non-numeric key   -> BAD_KEY
--         G4 store listed twice on a date -> DUPLICATE_KEY (first kept)
-- =====================================================================
BEGIN;

DELETE FROM SILVER.SLV_STORE
WHERE BUSINESS_DATE = TO_DATE('{{ ds }}');

DELETE FROM SILVER.REJ_ROW
WHERE BUSINESS_DATE = TO_DATE('{{ ds }}') AND SOURCE_TABLE = 'BRZ_STORE_MASTER';

INSERT ALL
    WHEN REASON_CD IS NULL THEN
        INTO SILVER.SLV_STORE (BUSINESS_DATE, STORE_ID, STORE_NAME, STORE_TYPE_CD,
                               DISTRICT_ID, DISTRICT_NAME, REGION_ID, REGION_NAME,
                               AREA_ID, AREA_NAME, COUNTRY_CD, CITY_NAME, CURRENCY_CD,
                               OPEN_DT, CLOSE_DT, _SOURCE_FILE, _LOAD_TS)
        VALUES (BUSINESS_DATE, STORE_ID, STORE_NAME, STORE_TYPE_CD,
                DISTRICT_ID, DISTRICT_NAME, REGION_ID, REGION_NAME,
                AREA_ID, AREA_NAME, COUNTRY_CD, CITY_NAME, CURRENCY_CD,
                OPEN_DT, CLOSE_DT, SOURCE_FILE, LOAD_TS)
    ELSE
        INTO SILVER.REJ_ROW (BUSINESS_DATE, SOURCE_TABLE, SOURCE_FILE, ROW_NUM,
                             GATE_CD, REASON_CD, RAW_RECORD, LOAD_TS)
        VALUES (BUSINESS_DATE, 'BRZ_STORE_MASTER', SOURCE_FILE, ROW_NUM,
                GATE_CD, REASON_CD, RAW_RECORD, LOAD_TS)
SELECT
    c.*,
    CASE
        WHEN c.STORE_ID IS NULL OR c.DISTRICT_ID IS NULL OR c.REGION_ID IS NULL
             OR c.AREA_ID IS NULL OR c.STORE_NAME IS NULL THEN 'G3'
        WHEN c.DUP_RANK > 1 THEN 'G4'
    END AS GATE_CD,
    CASE
        WHEN c.STORE_ID IS NULL OR c.DISTRICT_ID IS NULL OR c.REGION_ID IS NULL
             OR c.AREA_ID IS NULL OR c.STORE_NAME IS NULL THEN 'BAD_KEY'
        WHEN c.DUP_RANK > 1 THEN 'DUPLICATE_KEY'
    END AS REASON_CD
FROM (
    SELECT
        p.*,
        ROW_NUMBER() OVER (PARTITION BY p.STORE_ID ORDER BY p.ROW_NUM) AS DUP_RANK
    FROM (
        SELECT
            _BUSINESS_DATE                                               AS BUSINESS_DATE,
            TRY_TO_NUMBER(REGEXP_REPLACE(TRIM(STORE_ID), '^NL-', ''))    AS STORE_ID,
            NULLIF(TRIM(REGEXP_REPLACE(STORE_NAME, '\\s+', ' ')), '')    AS STORE_NAME,
            COALESCE(NULLIF(UPPER(TRIM(STORE_TYPE)), ''), 'S')           AS STORE_TYPE_CD,
            TRY_TO_NUMBER(TRIM(DISTRICT_ID))                             AS DISTRICT_ID,
            TRIM(DISTRICT_NAME)                                          AS DISTRICT_NAME,
            TRY_TO_NUMBER(TRIM(REGION_ID))                               AS REGION_ID,
            TRIM(REGION_NAME)                                            AS REGION_NAME,
            TRY_TO_NUMBER(TRIM(AREA_ID))                                 AS AREA_ID,
            TRIM(AREA_NAME)                                              AS AREA_NAME,
            UPPER(TRIM(COUNTRY))                                         AS COUNTRY_CD,
            TRIM(CITY)                                                   AS CITY_NAME,
            CASE WHEN UPPER(TRIM(CURRENCY_CODE)) IN ('USD', 'US$') THEN 'USD'
                 ELSE UPPER(TRIM(CURRENCY_CODE)) END                     AS CURRENCY_CD,
            TRY_TO_DATE(NULLIF(TRIM(OPEN_DATE), ''), 'YYYYMMDD')         AS OPEN_DT,
            TRY_TO_DATE(NULLIF(TRIM(CLOSE_DATE), ''), 'YYYYMMDD')        AS CLOSE_DT,
            _SOURCE_FILE                                                 AS SOURCE_FILE,
            _ROW_NUM                                                     AS ROW_NUM,
            OBJECT_CONSTRUCT(*)                                          AS RAW_RECORD,
            CURRENT_TIMESTAMP()::TIMESTAMP_NTZ                           AS LOAD_TS
        FROM BRONZE.BRZ_STORE_MASTER
        WHERE _BUSINESS_DATE = TO_DATE('{{ ds }}')
    ) p
) c;

COMMIT;

SELECT
    (SELECT COUNT(*) FROM SILVER.SLV_STORE WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')) AS ROWS_OK,
    (SELECT COUNT(*) FROM SILVER.REJ_ROW   WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')
                                            AND SOURCE_TABLE = 'BRZ_STORE_MASTER')     AS ROWS_REJECTED;

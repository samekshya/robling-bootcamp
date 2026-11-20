-- =====================================================================
-- Silver: BRONZE.BRZ_ITEM_MASTER -> SILVER.SLV_ITEM  (+ SILVER.REJ_ROW)
-- One business date per run ({{ ds }}). Idempotent: the date is deleted
-- from Silver and from the quarantine, then rebuilt.
--
-- Cleaning: trim text, collapse double spaces, subclass names in title
-- case, numbers typed.
-- Gates:  G3 missing or non-numeric key  -> BAD_KEY
--         G4 item listed twice on a date -> DUPLICATE_KEY (first kept)
-- =====================================================================
BEGIN;

DELETE FROM SILVER.SLV_ITEM
WHERE BUSINESS_DATE = TO_DATE('{{ ds }}');

DELETE FROM SILVER.REJ_ROW
WHERE BUSINESS_DATE = TO_DATE('{{ ds }}') AND SOURCE_TABLE = 'BRZ_ITEM_MASTER';

-- Good rows go to Silver, bad rows to the quarantine, in one pass.
INSERT ALL
    WHEN REASON_CD IS NULL THEN
        INTO SILVER.SLV_ITEM (BUSINESS_DATE, ITEM_ID, ITEM_NAME, BRAND_NAME, SUBCLASS_ID,
                              SUBCLASS_NAME, DEPT_ID, DEPT_NAME, UNIT_COST, UNIT_RETAIL,
                              STATUS_CD, _SOURCE_FILE, _LOAD_TS)
        VALUES (BUSINESS_DATE, ITEM_ID, ITEM_NAME, BRAND_NAME, SUBCLASS_ID,
                SUBCLASS_NAME, DEPT_ID, DEPT_NAME, UNIT_COST, UNIT_RETAIL,
                STATUS_CD, SOURCE_FILE, LOAD_TS)
    ELSE
        INTO SILVER.REJ_ROW (BUSINESS_DATE, SOURCE_TABLE, SOURCE_FILE, ROW_NUM,
                             GATE_CD, REASON_CD, RAW_RECORD, LOAD_TS)
        VALUES (BUSINESS_DATE, 'BRZ_ITEM_MASTER', SOURCE_FILE, ROW_NUM,
                GATE_CD, REASON_CD, RAW_RECORD, LOAD_TS)
SELECT
    c.*,
    CASE
        WHEN c.ITEM_ID IS NULL OR c.SUBCLASS_ID IS NULL OR c.DEPT_ID IS NULL
             OR c.ITEM_NAME IS NULL THEN 'G3'
        WHEN c.DUP_RANK > 1 THEN 'G4'
    END AS GATE_CD,
    CASE
        WHEN c.ITEM_ID IS NULL OR c.SUBCLASS_ID IS NULL OR c.DEPT_ID IS NULL
             OR c.ITEM_NAME IS NULL THEN 'BAD_KEY'
        WHEN c.DUP_RANK > 1 THEN 'DUPLICATE_KEY'
    END AS REASON_CD
FROM (
    SELECT
        p.*,
        ROW_NUMBER() OVER (PARTITION BY p.ITEM_ID ORDER BY p.ROW_NUM) AS DUP_RANK
    FROM (
        SELECT
            _BUSINESS_DATE                                            AS BUSINESS_DATE,
            TRY_TO_NUMBER(TRIM(ITEM_ID))                              AS ITEM_ID,
            NULLIF(TRIM(REGEXP_REPLACE(ITEM_NAME, '\\s+', ' ')), '')  AS ITEM_NAME,
            NULLIF(TRIM(BRAND_NAME), '')                              AS BRAND_NAME,
            TRY_TO_NUMBER(TRIM(SUBCLASS_ID))                          AS SUBCLASS_ID,
            INITCAP(TRIM(SUBCLASS_NAME))                              AS SUBCLASS_NAME,
            TRY_TO_NUMBER(TRIM(DEPT_ID))                              AS DEPT_ID,
            TRIM(DEPT_NAME)                                           AS DEPT_NAME,
            TRY_TO_NUMBER(TRIM(UNIT_COST), 12, 2)                     AS UNIT_COST,
            TRY_TO_NUMBER(TRIM(UNIT_RETAIL), 12, 2)                   AS UNIT_RETAIL,
            UPPER(TRIM(STATUS))                                       AS STATUS_CD,
            _SOURCE_FILE                                              AS SOURCE_FILE,
            _ROW_NUM                                                  AS ROW_NUM,
            OBJECT_CONSTRUCT(*)                                       AS RAW_RECORD,
            CURRENT_TIMESTAMP()::TIMESTAMP_NTZ                        AS LOAD_TS
        FROM BRONZE.BRZ_ITEM_MASTER
        WHERE _BUSINESS_DATE = TO_DATE('{{ ds }}')
    ) p
) c;

COMMIT;

-- Summary for the task log: rows kept, rows quarantined.
SELECT
    (SELECT COUNT(*) FROM SILVER.SLV_ITEM WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')) AS ROWS_OK,
    (SELECT COUNT(*) FROM SILVER.REJ_ROW  WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')
                                           AND SOURCE_TABLE = 'BRZ_ITEM_MASTER')       AS ROWS_REJECTED;

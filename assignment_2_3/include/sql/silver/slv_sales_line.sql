-- =====================================================================
-- Silver: BRONZE.BRZ_POS_SALES -> SILVER.SLV_SALES_LINE  (+ SILVER.REJ_ROW)
-- One business date per run ({{ ds }}). Idempotent: delete + rebuild.
-- Runs after SLV_ITEM and SLV_STORE, which it uses for the key checks.
--
-- Cleaning: dates ISO or M/D/YYYY, store codes 1101 / 01101 / NL-01101,
-- item ids trimmed, currency USD / usd / US$ -> USD (CAD kept).
-- Gates (first failing reason wins):
--   G3 NULL_ITEM       item id is empty
--   G3 BAD_VALUE       a number or date cannot be read
--   G3 BAD_DATE        business date is not the run's date
--   G3 NEGATIVE_QTY    quantity below zero
--   G3 ZERO_QTY        quantity zero
--   G4 DUPLICATE_KEY   transaction line seen before (first kept)
--   G5 UNKNOWN_STORE   store not in today's store master
--   G5 UNKNOWN_ITEM    item not in today's item master
-- =====================================================================
BEGIN;

DELETE FROM SILVER.SLV_SALES_LINE
WHERE BUSINESS_DATE = TO_DATE('{{ ds }}');

DELETE FROM SILVER.REJ_ROW
WHERE BUSINESS_DATE = TO_DATE('{{ ds }}') AND SOURCE_TABLE = 'BRZ_POS_SALES';

INSERT ALL
    WHEN REASON_CD IS NULL THEN
        INTO SILVER.SLV_SALES_LINE (BUSINESS_DATE, TXN_ID, TXN_LINE_ID, STORE_ID, ITEM_ID,
                                    SLS_QTY, UNIT_PRICE_AMT, DISCOUNT_AMT, SLS_AMT,
                                    CURRENCY_CD, _SOURCE_FILE, _ROW_NUM, _LOAD_TS)
        VALUES (SALE_DATE, TXN_ID, TXN_LINE_ID, STORE_ID, ITEM_ID,
                SLS_QTY, UNIT_PRICE_AMT, DISCOUNT_AMT, SLS_AMT,
                CURRENCY_CD, SOURCE_FILE, ROW_NUM, LOAD_TS)
    ELSE
        INTO SILVER.REJ_ROW (BUSINESS_DATE, SOURCE_TABLE, SOURCE_FILE, ROW_NUM,
                             GATE_CD, REASON_CD, RAW_RECORD, LOAD_TS)
        VALUES (FILE_DATE, 'BRZ_POS_SALES', SOURCE_FILE, ROW_NUM,
                GATE_CD, REASON_CD, RAW_RECORD, LOAD_TS)
SELECT
    c.*,
    CASE
        WHEN c.ITEM_ID_RAW IS NULL THEN 'G3'
        WHEN c.ITEM_ID IS NULL OR c.STORE_ID IS NULL OR c.TXN_LINE_ID IS NULL
             OR c.SLS_QTY IS NULL OR c.UNIT_PRICE_AMT IS NULL OR c.SLS_AMT IS NULL
             OR c.SALE_DATE IS NULL OR c.TXN_ID IS NULL THEN 'G3'
        WHEN c.SALE_DATE <> c.FILE_DATE THEN 'G3'
        WHEN c.SLS_QTY < 0 THEN 'G3'
        WHEN c.SLS_QTY = 0 THEN 'G3'
        WHEN c.DUP_RANK > 1 THEN 'G4'
        WHEN NOT c.STORE_KNOWN THEN 'G5'
        WHEN NOT c.ITEM_KNOWN THEN 'G5'
    END AS GATE_CD,
    CASE
        WHEN c.ITEM_ID_RAW IS NULL THEN 'NULL_ITEM'
        WHEN c.ITEM_ID IS NULL OR c.STORE_ID IS NULL OR c.TXN_LINE_ID IS NULL
             OR c.SLS_QTY IS NULL OR c.UNIT_PRICE_AMT IS NULL OR c.SLS_AMT IS NULL
             OR c.SALE_DATE IS NULL OR c.TXN_ID IS NULL THEN 'BAD_VALUE'
        WHEN c.SALE_DATE <> c.FILE_DATE THEN 'BAD_DATE'
        WHEN c.SLS_QTY < 0 THEN 'NEGATIVE_QTY'
        WHEN c.SLS_QTY = 0 THEN 'ZERO_QTY'
        WHEN c.DUP_RANK > 1 THEN 'DUPLICATE_KEY'
        WHEN NOT c.STORE_KNOWN THEN 'UNKNOWN_STORE'
        WHEN NOT c.ITEM_KNOWN THEN 'UNKNOWN_ITEM'
    END AS REASON_CD
FROM (
    SELECT
        p.*,
        ROW_NUMBER() OVER (PARTITION BY p.TXN_ID, p.TXN_LINE_ID ORDER BY p.ROW_NUM) AS DUP_RANK,
        s.STORE_ID IS NOT NULL AS STORE_KNOWN,
        i.ITEM_ID  IS NOT NULL AS ITEM_KNOWN
    FROM (
        SELECT
            _BUSINESS_DATE                                               AS FILE_DATE,
            CASE
                WHEN TRIM(BUSINESS_DATE) LIKE '%/%' THEN
                    TRY_TO_DATE(LPAD(SPLIT_PART(TRIM(BUSINESS_DATE), '/', 1), 2, '0') || '/' ||
                                LPAD(SPLIT_PART(TRIM(BUSINESS_DATE), '/', 2), 2, '0') || '/' ||
                                SPLIT_PART(TRIM(BUSINESS_DATE), '/', 3), 'MM/DD/YYYY')
                ELSE TRY_TO_DATE(TRIM(BUSINESS_DATE), 'YYYY-MM-DD')
            END                                                          AS SALE_DATE,
            NULLIF(TRIM(TRANSACTION_ID), '')                             AS TXN_ID,
            TRY_TO_NUMBER(TRIM(LINE_NUMBER))                             AS TXN_LINE_ID,
            TRY_TO_NUMBER(REGEXP_REPLACE(TRIM(STORE_ID), '^NL-', ''))    AS STORE_ID,
            NULLIF(TRIM(ITEM_ID), '')                                    AS ITEM_ID_RAW,
            TRY_TO_NUMBER(NULLIF(TRIM(ITEM_ID), ''))                     AS ITEM_ID,
            TRY_TO_NUMBER(TRIM(QUANTITY))                                AS SLS_QTY,
            TRY_TO_NUMBER(TRIM(UNIT_PRICE), 12, 2)                       AS UNIT_PRICE_AMT,
            COALESCE(TRY_TO_NUMBER(NULLIF(TRIM(DISCOUNT_AMOUNT), ''), 12, 2), 0) AS DISCOUNT_AMT,
            TRY_TO_NUMBER(TRIM(NET_AMOUNT), 14, 2)                       AS SLS_AMT,
            CASE WHEN UPPER(TRIM(CURRENCY_CODE)) IN ('USD', 'US$') THEN 'USD'
                 ELSE UPPER(TRIM(CURRENCY_CODE)) END                     AS CURRENCY_CD,
            _SOURCE_FILE                                                 AS SOURCE_FILE,
            _ROW_NUM                                                     AS ROW_NUM,
            OBJECT_CONSTRUCT(*)                                          AS RAW_RECORD,
            CURRENT_TIMESTAMP()::TIMESTAMP_NTZ                           AS LOAD_TS
        FROM BRONZE.BRZ_POS_SALES
        WHERE _BUSINESS_DATE = TO_DATE('{{ ds }}')
    ) p
    LEFT JOIN (SELECT DISTINCT STORE_ID FROM SILVER.SLV_STORE
               WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')) s
           ON s.STORE_ID = p.STORE_ID
    LEFT JOIN (SELECT DISTINCT ITEM_ID FROM SILVER.SLV_ITEM
               WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')) i
           ON i.ITEM_ID = p.ITEM_ID
) c;

COMMIT;

SELECT
    (SELECT COUNT(*) FROM SILVER.SLV_SALES_LINE WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')) AS ROWS_OK,
    (SELECT COUNT(*) FROM SILVER.REJ_ROW        WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')
                                                 AND SOURCE_TABLE = 'BRZ_POS_SALES')        AS ROWS_REJECTED;

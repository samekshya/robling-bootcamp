-- =====================================================================
-- Silver: BRONZE.BRZ_INVENTORY_SNAPSHOT -> SILVER.SLV_INVENTORY_POSITION
--         (+ SILVER.REJ_ROW)
-- One business date per run ({{ ds }}). Idempotent: delete + rebuild.
-- Runs after SLV_ITEM and SLV_STORE, which it uses for the key checks.
--
-- Negative stock is kept: it is a real condition in retail systems.
-- Gates (first failing reason wins):
--   G3 BAD_VALUE       a number or date cannot be read
--   G3 BAD_DATE        snapshot date is not the run's date
--   G4 DUPLICATE_KEY   item and store listed twice (first kept)
--   G5 UNKNOWN_STORE   store not in today's store master
--   G5 UNKNOWN_ITEM    item not in today's item master
-- =====================================================================
BEGIN;

DELETE FROM SILVER.SLV_INVENTORY_POSITION
WHERE BUSINESS_DATE = TO_DATE('{{ ds }}');

DELETE FROM SILVER.REJ_ROW
WHERE BUSINESS_DATE = TO_DATE('{{ ds }}') AND SOURCE_TABLE = 'BRZ_INVENTORY_SNAPSHOT';

INSERT ALL
    WHEN REASON_CD IS NULL THEN
        INTO SILVER.SLV_INVENTORY_POSITION (BUSINESS_DATE, STORE_ID, ITEM_ID, ONHAND_QTY,
                                            UNIT_COST, _SOURCE_FILE, _LOAD_TS)
        VALUES (SNAPSHOT_DT, STORE_ID, ITEM_ID, ONHAND_QTY,
                UNIT_COST, SOURCE_FILE, LOAD_TS)
    ELSE
        INTO SILVER.REJ_ROW (BUSINESS_DATE, SOURCE_TABLE, SOURCE_FILE, ROW_NUM,
                             GATE_CD, REASON_CD, RAW_RECORD, LOAD_TS)
        VALUES (FILE_DATE, 'BRZ_INVENTORY_SNAPSHOT', SOURCE_FILE, ROW_NUM,
                GATE_CD, REASON_CD, RAW_RECORD, LOAD_TS)
SELECT
    c.*,
    CASE
        WHEN c.STORE_ID IS NULL OR c.ITEM_ID IS NULL OR c.ONHAND_QTY IS NULL
             OR c.UNIT_COST IS NULL OR c.SNAPSHOT_DT IS NULL THEN 'G3'
        WHEN c.SNAPSHOT_DT <> c.FILE_DATE THEN 'G3'
        WHEN c.DUP_RANK > 1 THEN 'G4'
        WHEN NOT c.STORE_KNOWN THEN 'G5'
        WHEN NOT c.ITEM_KNOWN THEN 'G5'
    END AS GATE_CD,
    CASE
        WHEN c.STORE_ID IS NULL OR c.ITEM_ID IS NULL OR c.ONHAND_QTY IS NULL
             OR c.UNIT_COST IS NULL OR c.SNAPSHOT_DT IS NULL THEN 'BAD_VALUE'
        WHEN c.SNAPSHOT_DT <> c.FILE_DATE THEN 'BAD_DATE'
        WHEN c.DUP_RANK > 1 THEN 'DUPLICATE_KEY'
        WHEN NOT c.STORE_KNOWN THEN 'UNKNOWN_STORE'
        WHEN NOT c.ITEM_KNOWN THEN 'UNKNOWN_ITEM'
    END AS REASON_CD
FROM (
    SELECT
        p.*,
        ROW_NUMBER() OVER (PARTITION BY p.STORE_ID, p.ITEM_ID ORDER BY p.ROW_NUM) AS DUP_RANK,
        s.STORE_ID IS NOT NULL AS STORE_KNOWN,
        i.ITEM_ID  IS NOT NULL AS ITEM_KNOWN
    FROM (
        SELECT
            _BUSINESS_DATE                                               AS FILE_DATE,
            TRY_TO_DATE(TRIM(SNAPSHOT_DATE), 'YYYY-MM-DD')               AS SNAPSHOT_DT,
            TRY_TO_NUMBER(REGEXP_REPLACE(TRIM(STORE_ID), '^NL-', ''))    AS STORE_ID,
            TRY_TO_NUMBER(TRIM(ITEM_ID))                                 AS ITEM_ID,
            TRY_TO_NUMBER(TRIM(ON_HAND_QTY), 12, 2)                      AS ONHAND_QTY,
            TRY_TO_NUMBER(TRIM(UNIT_COST), 12, 2)                        AS UNIT_COST,
            _SOURCE_FILE                                                 AS SOURCE_FILE,
            _ROW_NUM                                                     AS ROW_NUM,
            OBJECT_CONSTRUCT(*)                                          AS RAW_RECORD,
            CURRENT_TIMESTAMP()::TIMESTAMP_NTZ                           AS LOAD_TS
        FROM BRONZE.BRZ_INVENTORY_SNAPSHOT
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
    (SELECT COUNT(*) FROM SILVER.SLV_INVENTORY_POSITION WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')) AS ROWS_OK,
    (SELECT COUNT(*) FROM SILVER.REJ_ROW                WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')
                                                         AND SOURCE_TABLE = 'BRZ_INVENTORY_SNAPSHOT') AS ROWS_REJECTED;

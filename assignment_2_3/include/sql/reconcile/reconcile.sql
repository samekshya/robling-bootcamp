-- =====================================================================
-- Reconcile: proves Gold ties to the source files for the business date.
-- Writes one row per check to SILVER.AUD_RECONCILIATION (old rows for the
-- date are replaced, so reruns stay idempotent) and returns them.
-- The Airflow task fails the run if any check has STATUS_CD = 'FAIL'.
--
-- "Source" = the file as landed in Bronze (gate G1 already proved every
-- file row is in Bronze).
-- =====================================================================
BEGIN;

DELETE FROM SILVER.AUD_RECONCILIATION WHERE BUSINESS_DATE = TO_DATE('{{ ds }}');

INSERT INTO SILVER.AUD_RECONCILIATION
    (BUSINESS_DATE, CHECK_NM, SOURCE_VALUE, TARGET_VALUE, DIFFERENCE, STATUS_CD, RUN_ID, CHECKED_TS)
WITH
src_sales AS (   -- the pos_sales file
    SELECT COUNT(*) AS ROW_CNT,
            COALESCE(SUM(TRY_TO_NUMBER(TRIM(NET_AMOUNT), 14, 2)), 0) AS NET_AMT
    FROM BRONZE.BRZ_POS_SALES WHERE _BUSINESS_DATE = TO_DATE('{{ ds }}')
),
rej_sales AS (   -- quarantined sales rows
    SELECT COUNT(*) AS ROW_CNT,
            COALESCE(SUM(TRY_TO_NUMBER(TRIM(RAW_RECORD:NET_AMOUNT::STRING), 14, 2)), 0) AS NET_AMT
    FROM SILVER.REJ_ROW
    WHERE BUSINESS_DATE = TO_DATE('{{ ds }}') AND SOURCE_TABLE = 'BRZ_POS_SALES'
),
slv_sales AS (
    SELECT COUNT(*) AS ROW_CNT, SUM(SLS_AMT) AS NET_AMT
    FROM SILVER.SLV_SALES_LINE WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')
),
gld_sales AS (
    SELECT COUNT(*) AS ROW_CNT, SUM(f.SLS_AMT) AS NET_AMT
    FROM RETAIL_DW.FCT_SALES f JOIN RETAIL_DW.DIM_DAY d ON d.DAY_KY = f.DAY_KY
    WHERE d.FULL_DT = TO_DATE('{{ ds }}')
),
src_inv AS (
    SELECT COUNT(*) AS ROW_CNT FROM BRONZE.BRZ_INVENTORY_SNAPSHOT
    WHERE _BUSINESS_DATE = TO_DATE('{{ ds }}')
),
rej_inv AS (
    SELECT COUNT(*) AS ROW_CNT FROM SILVER.REJ_ROW
    WHERE BUSINESS_DATE = TO_DATE('{{ ds }}') AND SOURCE_TABLE = 'BRZ_INVENTORY_SNAPSHOT'
),
slv_inv AS (
    SELECT COUNT(*) AS ROW_CNT, SUM(ONHAND_QTY) AS QTY
    FROM SILVER.SLV_INVENTORY_POSITION WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')
),
gld_inv AS (
    SELECT COUNT(*) AS ROW_CNT, SUM(ONHAND_QTY) AS QTY
    FROM RETAIL_DW.FCT_INVENTORY
    WHERE TO_DATE('{{ ds }}') BETWEEN EFF_START_DT AND EFF_END_DT
),
checks AS (
    SELECT 'calendar: business date in DIM_DAY' AS CHECK_NM, 1 AS SOURCE_VALUE,
           (SELECT COUNT(*) FROM RETAIL_DW.DIM_DAY WHERE FULL_DT = TO_DATE('{{ ds }}')) AS TARGET_VALUE,
           'FAIL' AS ON_MISMATCH
    UNION ALL
    SELECT 'sales rows: file = silver + quarantine',
           (SELECT ROW_CNT FROM src_sales),
           (SELECT ROW_CNT FROM slv_sales) + (SELECT ROW_CNT FROM rej_sales), 'FAIL'
    UNION ALL
    SELECT 'sales rows: silver = gold',
           (SELECT ROW_CNT FROM slv_sales), (SELECT ROW_CNT FROM gld_sales), 'FAIL'
    UNION ALL
    SELECT 'net sales: file - quarantined = gold',
           (SELECT NET_AMT FROM src_sales) - (SELECT NET_AMT FROM rej_sales),
           COALESCE((SELECT NET_AMT FROM gld_sales), 0), 'FAIL'
    UNION ALL
    SELECT 'inventory rows: file = silver + quarantine',
           (SELECT ROW_CNT FROM src_inv),
           (SELECT ROW_CNT FROM slv_inv) + (SELECT ROW_CNT FROM rej_inv), 'FAIL'
    UNION ALL
    SELECT 'inventory positions: silver = gold valid on date',
           (SELECT ROW_CNT FROM slv_inv), (SELECT ROW_CNT FROM gld_inv), 'FAIL'
    UNION ALL
    SELECT 'on-hand qty: silver = gold valid on date',
           COALESCE((SELECT QTY FROM slv_inv), 0), COALESCE((SELECT QTY FROM gld_inv), 0), 'FAIL'
    UNION ALL
    SELECT 'DIM_ITEM: items with more than one current row', 0,
           (SELECT COUNT(*) FROM (SELECT ITEM_ID FROM RETAIL_DW.DIM_ITEM WHERE CURR_FLG
                                  GROUP BY ITEM_ID HAVING COUNT(*) > 1)), 'FAIL'
    UNION ALL
    SELECT 'DIM_LOCN: stores with more than one current row', 0,
           (SELECT COUNT(*) FROM (SELECT LOCN_ID FROM RETAIL_DW.DIM_LOCN WHERE CURR_FLG
                                  GROUP BY LOCN_ID HAVING COUNT(*) > 1)), 'FAIL'
    UNION ALL
    SELECT 'FCT_INVENTORY: positions with more than one open row', 0,
           (SELECT COUNT(*) FROM (SELECT ITEM_KY, LOCN_KY FROM RETAIL_DW.FCT_INVENTORY
                                  WHERE EFF_END_DT = DATE '9999-12-31'
                                  GROUP BY ITEM_KY, LOCN_KY HAVING COUNT(*) > 1)), 'FAIL'
    UNION ALL
    -- Warning only: quarantine above 1% of the sales file needs a look, but does not stop the load
    SELECT 'sales quarantine rate % (alert above 1)', 1,
           ROUND(100 * (SELECT ROW_CNT FROM rej_sales) / NULLIF((SELECT ROW_CNT FROM src_sales), 0), 2),
           'ALERT'
)
SELECT
    TO_DATE('{{ ds }}'),
    CHECK_NM,
    SOURCE_VALUE,
    TARGET_VALUE,
    TARGET_VALUE - SOURCE_VALUE,
    CASE
        WHEN ON_MISMATCH = 'ALERT' THEN IFF(TARGET_VALUE > SOURCE_VALUE, 'ALERT', 'PASS')
        WHEN TARGET_VALUE = SOURCE_VALUE THEN 'PASS'
        ELSE 'FAIL'
    END,
    '{{ run_id }}',
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM checks;

COMMIT;

SELECT CHECK_NM, SOURCE_VALUE, TARGET_VALUE, DIFFERENCE, STATUS_CD
FROM SILVER.AUD_RECONCILIATION
WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')
ORDER BY CHECK_NM;

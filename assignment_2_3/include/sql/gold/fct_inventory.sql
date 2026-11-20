-- =====================================================================
-- Gold: SILVER.SLV_INVENTORY_POSITION -> RETAIL_DW.FCT_INVENTORY
-- Positional fact: one row per item and store for each period in which
-- the on-hand quantity stayed the same (EFF_START_DT to EFF_END_DT).
--
-- For each business date:
--   1. CLOSE open rows (EFF_END_DT = day before) when the quantity changed,
--      the position disappeared, or the item / store got a new SCD2 version.
--      Rows are closed, never deleted, so history is kept.
--   2. INSERT a new open row for changed and new positions.
-- Unchanged positions are left alone (no new row).
--
-- Rerun safety:
--   * rerunning the latest date changes nothing: the open rows already
--     match it, and rows that started on this date are never closed;
--   * older dates (before the latest loaded position) are skipped
--     (IS_LATEST = FALSE), because their history is already built.
-- =====================================================================
CREATE OR REPLACE TEMPORARY TABLE SILVER.TMP_INV_GUARD AS
SELECT TO_DATE('{{ ds }}') >= COALESCE(MAX(EFF_START_DT), TO_DATE('1900-01-01')) AS IS_LATEST
FROM RETAIL_DW.FCT_INVENTORY;

-- Today's positions with the keys valid today
CREATE OR REPLACE TEMPORARY TABLE SILVER.TMP_INV_SRC AS
SELECT p.ITEM_ID, p.STORE_ID, i.ITEM_KY, l.LOCN_KY, p.ONHAND_QTY,
       ROUND(p.ONHAND_QTY * p.UNIT_COST, 2) AS INV_VALUE_AMT,
       st.CURRENCY_CD
FROM SILVER.SLV_INVENTORY_POSITION p
JOIN RETAIL_DW.DIM_ITEM i ON i.ITEM_ID = p.ITEM_ID
                         AND p.BUSINESS_DATE BETWEEN i.EFF_START_DT AND i.EFF_END_DT
JOIN RETAIL_DW.DIM_LOCN l ON l.LOCN_ID = p.STORE_ID
                         AND p.BUSINESS_DATE BETWEEN l.EFF_START_DT AND l.EFF_END_DT
JOIN SILVER.SLV_STORE st ON st.STORE_ID = p.STORE_ID AND st.BUSINESS_DATE = p.BUSINESS_DATE
WHERE p.BUSINESS_DATE = TO_DATE('{{ ds }}');

-- Open rows with their business ids (an item / store may have a new key today)
CREATE OR REPLACE TEMPORARY TABLE SILVER.TMP_INV_OPEN AS
SELECT f.INV_KY, i.ITEM_ID, l.LOCN_ID AS STORE_ID, f.ITEM_KY, f.LOCN_KY,
       f.ONHAND_QTY, f.EFF_START_DT
FROM RETAIL_DW.FCT_INVENTORY f
JOIN RETAIL_DW.DIM_ITEM i ON i.ITEM_KY = f.ITEM_KY
JOIN RETAIL_DW.DIM_LOCN l ON l.LOCN_KY = f.LOCN_KY
WHERE f.EFF_END_DT = DATE '9999-12-31';

BEGIN;

-- 1. Close changed or vanished positions
UPDATE RETAIL_DW.FCT_INVENTORY f
   SET EFF_END_DT = DATEADD(day, -1, TO_DATE('{{ ds }}')),
       UPDATE_TS  = CURRENT_TIMESTAMP()
  FROM (
        SELECT o.INV_KY
        FROM SILVER.TMP_INV_OPEN o
        LEFT JOIN SILVER.TMP_INV_SRC s
               ON s.ITEM_ID = o.ITEM_ID AND s.STORE_ID = o.STORE_ID
        WHERE o.EFF_START_DT < TO_DATE('{{ ds }}')
          AND (s.ITEM_ID IS NULL
               OR s.ONHAND_QTY <> o.ONHAND_QTY
               OR s.ITEM_KY    <> o.ITEM_KY
               OR s.LOCN_KY    <> o.LOCN_KY)
       ) c,
       SILVER.TMP_INV_GUARD g
 WHERE f.INV_KY = c.INV_KY
   AND g.IS_LATEST;

-- 2. Open a row for every position that has no open row now
INSERT INTO RETAIL_DW.FCT_INVENTORY (ITEM_KY, LOCN_KY, EFF_START_DT, EFF_END_DT,
                                     ONHAND_QTY, INV_VALUE_AMT, CURRENCY_CD)
SELECT s.ITEM_KY, s.LOCN_KY, TO_DATE('{{ ds }}'), DATE '9999-12-31',
       s.ONHAND_QTY, s.INV_VALUE_AMT, s.CURRENCY_CD
FROM SILVER.TMP_INV_SRC s
CROSS JOIN SILVER.TMP_INV_GUARD g
WHERE g.IS_LATEST
  AND NOT EXISTS (
        SELECT 1
        FROM RETAIL_DW.FCT_INVENTORY f
        JOIN RETAIL_DW.DIM_ITEM i ON i.ITEM_KY = f.ITEM_KY
        JOIN RETAIL_DW.DIM_LOCN l ON l.LOCN_KY = f.LOCN_KY
        WHERE f.EFF_END_DT = DATE '9999-12-31'
          AND i.ITEM_ID = s.ITEM_ID
          AND l.LOCN_ID = s.STORE_ID);

COMMIT;

-- ROWS_OK = positions valid on the date; ROWS_REJECTED = Silver positions
-- without a Gold row valid on the date (should be 0)
SELECT
    (SELECT COUNT(*) FROM RETAIL_DW.FCT_INVENTORY
      WHERE TO_DATE('{{ ds }}') BETWEEN EFF_START_DT AND EFF_END_DT)                    AS ROWS_OK,
    (SELECT COUNT(*) FROM SILVER.SLV_INVENTORY_POSITION WHERE BUSINESS_DATE = TO_DATE('{{ ds }}'))
    - (SELECT COUNT(*) FROM RETAIL_DW.FCT_INVENTORY
        WHERE TO_DATE('{{ ds }}') BETWEEN EFF_START_DT AND EFF_END_DT)                  AS ROWS_REJECTED;

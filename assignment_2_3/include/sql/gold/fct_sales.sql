-- =====================================================================
-- Gold: SILVER.SLV_SALES_LINE -> RETAIL_DW.FCT_SALES
-- Grain: one row per transaction line. Idempotent: the business date is
-- deleted and reloaded in one transaction.
-- Every sale is linked to the dimension version valid on its sale date
-- (SCD2 point-in-time join), and to the Unknown customer (-1).
-- =====================================================================
BEGIN;

DELETE FROM RETAIL_DW.FCT_SALES
WHERE DAY_KY IN (SELECT DAY_KY FROM RETAIL_DW.DIM_DAY WHERE FULL_DT = TO_DATE('{{ ds }}'));

INSERT INTO RETAIL_DW.FCT_SALES (TXN_ID, TXN_LINE_ID, ITEM_KY, LOCN_KY, DAY_KY, CUSTOMER_KY,
                                 SLS_QTY, UNIT_PRICE_AMT, SLS_AMT, CURRENCY_CD)
SELECT s.TXN_ID, s.TXN_LINE_ID, i.ITEM_KY, l.LOCN_KY, d.DAY_KY, -1,
       s.SLS_QTY, s.UNIT_PRICE_AMT, s.SLS_AMT, s.CURRENCY_CD
FROM SILVER.SLV_SALES_LINE s
JOIN RETAIL_DW.DIM_DAY  d ON d.FULL_DT = s.BUSINESS_DATE
JOIN RETAIL_DW.DIM_ITEM i ON i.ITEM_ID = s.ITEM_ID
                         AND s.BUSINESS_DATE BETWEEN i.EFF_START_DT AND i.EFF_END_DT
JOIN RETAIL_DW.DIM_LOCN l ON l.LOCN_ID = s.STORE_ID
                         AND s.BUSINESS_DATE BETWEEN l.EFF_START_DT AND l.EFF_END_DT
WHERE s.BUSINESS_DATE = TO_DATE('{{ ds }}');

COMMIT;

-- ROWS_OK = Gold rows for the date; ROWS_REJECTED = Silver rows that found no
-- dimension key (should be 0; the reconcile task fails the run if not).
SELECT
    (SELECT COUNT(*) FROM RETAIL_DW.FCT_SALES f JOIN RETAIL_DW.DIM_DAY d ON d.DAY_KY = f.DAY_KY
      WHERE d.FULL_DT = TO_DATE('{{ ds }}'))                                             AS ROWS_OK,
    (SELECT COUNT(*) FROM SILVER.SLV_SALES_LINE WHERE BUSINESS_DATE = TO_DATE('{{ ds }}'))
    - (SELECT COUNT(*) FROM RETAIL_DW.FCT_SALES f JOIN RETAIL_DW.DIM_DAY d ON d.DAY_KY = f.DAY_KY
        WHERE d.FULL_DT = TO_DATE('{{ ds }}'))                                           AS ROWS_REJECTED;

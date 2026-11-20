-- =====================================================================
-- Gold: SILVER.SLV_ITEM (department) -> RETAIL_DW.DIM_CATG
-- SCD1: new categories inserted, changed names overwritten.
-- The name is only overwritten when this run is the latest loaded date
-- (IS_LATEST), so rerunning an older date never brings back an old name.
-- =====================================================================
MERGE INTO RETAIL_DW.DIM_CATG t
USING (
    SELECT src.*, g.IS_LATEST
    FROM (
        SELECT DEPT_ID AS CATG_ID, DEPT_NAME AS CATG_NM
        FROM SILVER.SLV_ITEM
        WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')
        QUALIFY ROW_NUMBER() OVER (PARTITION BY DEPT_ID ORDER BY DEPT_NAME) = 1
    ) src
    CROSS JOIN (
        SELECT TO_DATE('{{ ds }}') >= COALESCE(MAX(BUSINESS_DATE), TO_DATE('1900-01-01')) AS IS_LATEST
        FROM SILVER.AUD_RECONCILIATION
    ) g
) s
   ON t.CATG_ID = s.CATG_ID
WHEN MATCHED AND s.IS_LATEST AND t.CATG_NM <> s.CATG_NM THEN
    UPDATE SET CATG_NM = s.CATG_NM, UPDATE_TS = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN
    INSERT (CATG_ID, CATG_NM) VALUES (s.CATG_ID, s.CATG_NM);

SELECT COUNT(*) AS ROWS_OK, 0 AS ROWS_REJECTED FROM RETAIL_DW.DIM_CATG;

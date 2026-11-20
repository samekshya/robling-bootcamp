-- =====================================================================
-- Gold: SILVER.SLV_STORE (area) -> RETAIL_DW.DIM_AREA
-- SCD1 MERGE with the IS_LATEST guard (see dim_catg.sql). Safe to rerun.
-- =====================================================================
MERGE INTO RETAIL_DW.DIM_AREA t
USING (
    SELECT src.*, g.IS_LATEST
    FROM (
        SELECT AREA_ID, AREA_NAME AS AREA_NM
        FROM SILVER.SLV_STORE
        WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')
        QUALIFY ROW_NUMBER() OVER (PARTITION BY AREA_ID ORDER BY AREA_NAME) = 1
    ) src
    CROSS JOIN (
        SELECT TO_DATE('{{ ds }}') >= COALESCE(MAX(BUSINESS_DATE), TO_DATE('1900-01-01')) AS IS_LATEST
        FROM SILVER.AUD_RECONCILIATION
    ) g
) s
   ON t.AREA_ID = s.AREA_ID
WHEN MATCHED AND s.IS_LATEST AND t.AREA_NM <> s.AREA_NM THEN
    UPDATE SET AREA_NM = s.AREA_NM, UPDATE_TS = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN
    INSERT (AREA_ID, AREA_NM) VALUES (s.AREA_ID, s.AREA_NM);

SELECT COUNT(*) AS ROWS_OK, 0 AS ROWS_REJECTED FROM RETAIL_DW.DIM_AREA;

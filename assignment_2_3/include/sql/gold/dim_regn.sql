-- =====================================================================
-- Gold: SILVER.SLV_STORE (region) -> RETAIL_DW.DIM_REGN
-- COUNTRY_NM from the store country code (US / CA). AREA_KY from DIM_AREA.
-- SCD1 MERGE with the IS_LATEST guard. Safe to rerun.
-- =====================================================================
MERGE INTO RETAIL_DW.DIM_REGN t
USING (
    SELECT src.REGN_ID, src.REGN_NM, src.COUNTRY_NM, a.AREA_KY, g.IS_LATEST
    FROM (
        SELECT REGION_ID AS REGN_ID,
               REGION_NAME AS REGN_NM,
               DECODE(COUNTRY_CD, 'US', 'United States', 'CA', 'Canada', COALESCE(COUNTRY_CD, 'Unknown')) AS COUNTRY_NM,
               AREA_ID
        FROM SILVER.SLV_STORE
        WHERE BUSINESS_DATE = TO_DATE('{{ ds }}')
        QUALIFY ROW_NUMBER() OVER (PARTITION BY REGION_ID ORDER BY REGION_NAME, STORE_ID) = 1
    ) src
    JOIN RETAIL_DW.DIM_AREA a ON a.AREA_ID = src.AREA_ID
    CROSS JOIN (
        SELECT TO_DATE('{{ ds }}') >= COALESCE(MAX(BUSINESS_DATE), TO_DATE('1900-01-01')) AS IS_LATEST
        FROM SILVER.AUD_RECONCILIATION
    ) g
) s
   ON t.REGN_ID = s.REGN_ID
WHEN MATCHED AND s.IS_LATEST AND (t.REGN_NM <> s.REGN_NM OR t.COUNTRY_NM <> s.COUNTRY_NM
                                  OR t.AREA_KY <> s.AREA_KY) THEN
    UPDATE SET REGN_NM = s.REGN_NM, COUNTRY_NM = s.COUNTRY_NM, AREA_KY = s.AREA_KY,
               UPDATE_TS = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN
    INSERT (REGN_ID, REGN_NM, COUNTRY_NM, AREA_KY)
    VALUES (s.REGN_ID, s.REGN_NM, s.COUNTRY_NM, s.AREA_KY);

SELECT COUNT(*) AS ROWS_OK, 0 AS ROWS_REJECTED FROM RETAIL_DW.DIM_REGN;

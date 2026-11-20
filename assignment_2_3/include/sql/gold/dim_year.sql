-- =====================================================================
-- Gold: SILVER.SLV_FISCAL_DAY -> RETAIL_DW.DIM_YEAR (fiscal years)
-- MERGE on the business key YEAR_ID: new years are inserted, existing
-- years are only updated if their dates changed (SCD1). Safe to rerun.
-- =====================================================================
MERGE INTO RETAIL_DW.DIM_YEAR t
USING (
    SELECT DISTINCT FISCAL_YEAR AS YEAR_ID, YEAR_START_DT, YEAR_END_DT
    FROM SILVER.SLV_FISCAL_DAY
) s
   ON t.YEAR_ID = s.YEAR_ID
WHEN MATCHED AND (t.YEAR_START_DT <> s.YEAR_START_DT OR t.YEAR_END_DT <> s.YEAR_END_DT) THEN
    UPDATE SET YEAR_START_DT = s.YEAR_START_DT, YEAR_END_DT = s.YEAR_END_DT,
               UPDATE_TS = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN
    INSERT (YEAR_ID, YEAR_START_DT, YEAR_END_DT)
    VALUES (s.YEAR_ID, s.YEAR_START_DT, s.YEAR_END_DT);

SELECT COUNT(*) AS ROWS_OK, 0 AS ROWS_REJECTED FROM RETAIL_DW.DIM_YEAR;

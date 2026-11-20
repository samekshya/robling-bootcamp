-- =====================================================================
-- Gold: SILVER.SLV_FISCAL_DAY -> RETAIL_DW.DIM_WEEK (fiscal weeks, Sun-Sat)
-- WEEK_ID = fiscal year * 100 + week, e.g. 202640 = week 40 of FY2026.
-- Parent key YEAR_KY is looked up from DIM_YEAR. SCD1 MERGE, safe to rerun.
-- =====================================================================
MERGE INTO RETAIL_DW.DIM_WEEK t
USING (
    SELECT DISTINCT
        f.FISCAL_YEAR * 100 + f.WEEK_NUM AS WEEK_ID,
        f.WEEK_NUM,
        f.WEEK_START_DT,
        f.WEEK_END_DT,
        y.YEAR_KY
    FROM SILVER.SLV_FISCAL_DAY f
    JOIN RETAIL_DW.DIM_YEAR y ON y.YEAR_ID = f.FISCAL_YEAR
) s
   ON t.WEEK_ID = s.WEEK_ID
WHEN MATCHED AND (t.WEEK_START_DT <> s.WEEK_START_DT OR t.WEEK_END_DT <> s.WEEK_END_DT
                  OR t.YEAR_KY <> s.YEAR_KY) THEN
    UPDATE SET WEEK_NUM = s.WEEK_NUM, WEEK_START_DT = s.WEEK_START_DT,
               WEEK_END_DT = s.WEEK_END_DT, YEAR_KY = s.YEAR_KY,
               UPDATE_TS = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN
    INSERT (WEEK_ID, WEEK_NUM, WEEK_START_DT, WEEK_END_DT, YEAR_KY)
    VALUES (s.WEEK_ID, s.WEEK_NUM, s.WEEK_START_DT, s.WEEK_END_DT, s.YEAR_KY);

SELECT COUNT(*) AS ROWS_OK, 0 AS ROWS_REJECTED FROM RETAIL_DW.DIM_WEEK;

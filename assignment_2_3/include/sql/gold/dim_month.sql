-- =====================================================================
-- Gold: SILVER.SLV_FISCAL_DAY -> RETAIL_DW.DIM_MONTH (fiscal periods)
-- MONTH_ID = fiscal year * 100 + period, e.g. 202610 = period 10 of FY2026.
-- Parent key YEAR_KY is looked up from DIM_YEAR. SCD1 MERGE, safe to rerun.
-- =====================================================================
MERGE INTO RETAIL_DW.DIM_MONTH t
USING (
    SELECT DISTINCT
        f.FISCAL_YEAR * 100 + f.PERIOD_NUM AS MONTH_ID,
        f.PERIOD_NUM                       AS MONTH_NUM,
        f.PERIOD_NM                        AS MONTH_NM,
        f.WEEKS_IN_PERIOD                  AS WEEKS_IN_MONTH_NUM,
        f.PERIOD_START_DT                  AS MONTH_START_DT,
        f.PERIOD_END_DT                    AS MONTH_END_DT,
        y.YEAR_KY
    FROM SILVER.SLV_FISCAL_DAY f
    JOIN RETAIL_DW.DIM_YEAR y ON y.YEAR_ID = f.FISCAL_YEAR
) s
   ON t.MONTH_ID = s.MONTH_ID
WHEN MATCHED AND (t.MONTH_NM <> s.MONTH_NM OR t.MONTH_START_DT <> s.MONTH_START_DT
                  OR t.MONTH_END_DT <> s.MONTH_END_DT OR t.YEAR_KY <> s.YEAR_KY) THEN
    UPDATE SET MONTH_NUM = s.MONTH_NUM, MONTH_NM = s.MONTH_NM,
               WEEKS_IN_MONTH_NUM = s.WEEKS_IN_MONTH_NUM,
               MONTH_START_DT = s.MONTH_START_DT, MONTH_END_DT = s.MONTH_END_DT,
               YEAR_KY = s.YEAR_KY, UPDATE_TS = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN
    INSERT (MONTH_ID, MONTH_NUM, MONTH_NM, WEEKS_IN_MONTH_NUM, MONTH_START_DT, MONTH_END_DT, YEAR_KY)
    VALUES (s.MONTH_ID, s.MONTH_NUM, s.MONTH_NM, s.WEEKS_IN_MONTH_NUM,
            s.MONTH_START_DT, s.MONTH_END_DT, s.YEAR_KY);

SELECT COUNT(*) AS ROWS_OK, 0 AS ROWS_REJECTED FROM RETAIL_DW.DIM_MONTH;

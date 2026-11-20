-- =====================================================================
-- Gold: SILVER.SLV_FISCAL_DAY -> RETAIL_DW.DIM_DAY (one row per date)
-- DAY_ID = YYYYMMDD. Each day points to its fiscal week and fiscal period.
-- HOLIDAY_NM: Thanksgiving (4th Thursday of November) and Black Friday.
-- SCD1 MERGE, safe to rerun.
-- =====================================================================
MERGE INTO RETAIL_DW.DIM_DAY t
USING (
    SELECT
        TO_NUMBER(TO_CHAR(f.FULL_DT, 'YYYYMMDD')) AS DAY_ID,
        f.FULL_DT,
        DAY(f.FULL_DT)                            AS DAY_NUM,
        CASE
            WHEN MONTH(f.FULL_DT) = 11 AND DAYOFWEEKISO(f.FULL_DT) = 4
                 AND DAY(f.FULL_DT) BETWEEN 22 AND 28 THEN 'Thanksgiving'
            WHEN MONTH(f.FULL_DT) = 11 AND DAYOFWEEKISO(f.FULL_DT) = 5
                 AND DAY(f.FULL_DT) BETWEEN 23 AND 29 THEN 'Black Friday'
        END                                       AS HOLIDAY_NM,
        w.WEEK_KY,
        m.MONTH_KY
    FROM SILVER.SLV_FISCAL_DAY f
    JOIN RETAIL_DW.DIM_WEEK  w ON w.WEEK_ID  = f.FISCAL_YEAR * 100 + f.WEEK_NUM
    JOIN RETAIL_DW.DIM_MONTH m ON m.MONTH_ID = f.FISCAL_YEAR * 100 + f.PERIOD_NUM
) s
   ON t.DAY_ID = s.DAY_ID
WHEN MATCHED AND (t.WEEK_KY <> s.WEEK_KY OR t.MONTH_KY <> s.MONTH_KY
                  OR COALESCE(t.HOLIDAY_NM, '') <> COALESCE(s.HOLIDAY_NM, '')) THEN
    UPDATE SET WEEK_KY = s.WEEK_KY, MONTH_KY = s.MONTH_KY, HOLIDAY_NM = s.HOLIDAY_NM,
               UPDATE_TS = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN
    INSERT (DAY_ID, FULL_DT, DAY_NUM, HOLIDAY_NM, WEEK_KY, MONTH_KY)
    VALUES (s.DAY_ID, s.FULL_DT, s.DAY_NUM, s.HOLIDAY_NM, s.WEEK_KY, s.MONTH_KY);

SELECT COUNT(*) AS ROWS_OK, 0 AS ROWS_REJECTED FROM RETAIL_DW.DIM_DAY;

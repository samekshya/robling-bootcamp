-- =====================================================================
-- Silver: retail 4-5-4 fiscal calendar -> SILVER.SLV_FISCAL_DAY
-- Rebuilt on every run (same result every time, so idempotent).
-- Rules (Finance calendar used in Assignments 2.1 and 2.2):
--   * fiscal year = 52 weeks, weeks run Sunday to Saturday
--   * FY2025 starts on Sunday 2 Feb 2025; each year starts 364 days later
--   * 12 periods per year in a 4-5-4 week pattern per quarter
-- Covers FY2025 to FY2027 (1,092 days), the range of the Finance seed.
-- =====================================================================
CREATE OR REPLACE TABLE SILVER.SLV_FISCAL_DAY AS
SELECT
    FULL_DT,
    FISCAL_YEAR,
    YEAR_START_DT,
    DATEADD(day, 363, YEAR_START_DT)                                    AS YEAR_END_DT,
    QTR_IDX * 3 + PERIOD_IN_QTR                                         AS PERIOD_NUM,
    DECODE(QTR_IDX * 3 + PERIOD_IN_QTR,
           1, 'February', 2, 'March', 3, 'April', 4, 'May', 5, 'June', 6, 'July',
           7, 'August', 8, 'September', 9, 'October', 10, 'November',
           11, 'December', 12, 'January')                               AS PERIOD_NM,
    CASE PERIOD_IN_QTR WHEN 2 THEN 5 ELSE 4 END                         AS WEEKS_IN_PERIOD,
    DATEADD(day, (QTR_IDX * 13 + CASE PERIOD_IN_QTR WHEN 1 THEN 0 WHEN 2 THEN 4 ELSE 9 END) * 7,
            YEAR_START_DT)                                              AS PERIOD_START_DT,
    DATEADD(day, (QTR_IDX * 13 + CASE PERIOD_IN_QTR WHEN 1 THEN 4 WHEN 2 THEN 9 ELSE 13 END) * 7 - 1,
            YEAR_START_DT)                                              AS PERIOD_END_DT,
    WEEK_NUM,
    DATEADD(day, (WEEK_NUM - 1) * 7, YEAR_START_DT)                     AS WEEK_START_DT,
    DATEADD(day, (WEEK_NUM - 1) * 7 + 6, YEAR_START_DT)                 AS WEEK_END_DT
FROM (
    SELECT
        q.*,
        CASE WHEN WEEK_IN_QTR <= 4 THEN 1 WHEN WEEK_IN_QTR <= 9 THEN 2 ELSE 3 END AS PERIOD_IN_QTR
    FROM (
        SELECT
            DATEADD(day, DAY_IDX::INT, DATE '2025-02-02')                    AS FULL_DT,
            (2025 + FLOOR(DAY_IDX / 364))::INT                          AS FISCAL_YEAR,
            DATEADD(day, (FLOOR(DAY_IDX / 364) * 364)::INT, DATE '2025-02-02') AS YEAR_START_DT,
            (FLOOR(MOD(DAY_IDX, 364) / 7) + 1)::INT                     AS WEEK_NUM,
            FLOOR(FLOOR(MOD(DAY_IDX, 364) / 7) / 13)::INT               AS QTR_IDX,
            (MOD(FLOOR(MOD(DAY_IDX, 364) / 7), 13) + 1)::INT            AS WEEK_IN_QTR
        FROM (
            SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS DAY_IDX
            FROM TABLE(GENERATOR(ROWCOUNT => 1092))
        )
    ) q
);

SELECT COUNT(*) AS ROWS_OK, 0 AS ROWS_REJECTED FROM SILVER.SLV_FISCAL_DAY;

-- =====================================================================
-- Gold: SILVER.SLV_STORE -> RETAIL_DW.DIM_LOCN
-- SCD2 on DISTRICT_KY: when a store moves district (store 1112 on
-- 3 Nov 2026) the current version is closed and a new one inserted,
-- with a new LOCN_KY from AUTOINCREMENT.
-- SCD1 on LOCN_NM and LOCN_TYPE_CD (overwritten in place).
-- Same rerun safety rules as dim_item.sql.
-- =====================================================================
CREATE OR REPLACE TEMPORARY TABLE SILVER.TMP_LOCN_SRC AS
SELECT s.STORE_ID AS LOCN_ID, s.STORE_NAME AS LOCN_NM, s.STORE_TYPE_CD AS LOCN_TYPE_CD, d.DISTRICT_KY
FROM SILVER.SLV_STORE s
JOIN RETAIL_DW.DIM_DISTRICT d ON d.DISTRICT_ID = s.DISTRICT_ID
WHERE s.BUSINESS_DATE = TO_DATE('{{ ds }}')
QUALIFY ROW_NUMBER() OVER (PARTITION BY s.STORE_ID ORDER BY s._LOAD_TS DESC) = 1;

BEGIN;

-- 1. SCD2: close the current version when the store changed district
UPDATE RETAIL_DW.DIM_LOCN t
   SET EFF_END_DT = DATEADD(day, -1, TO_DATE('{{ ds }}')),
       CURR_FLG   = FALSE,
       UPDATE_TS  = CURRENT_TIMESTAMP()
  FROM SILVER.TMP_LOCN_SRC s
 WHERE t.LOCN_ID = s.LOCN_ID
   AND t.CURR_FLG
   AND TO_DATE('{{ ds }}') > t.EFF_START_DT
   AND t.DISTRICT_KY <> s.DISTRICT_KY;

-- 2. SCD2: new current version for moved or new stores
INSERT INTO RETAIL_DW.DIM_LOCN (LOCN_ID, LOCN_NM, LOCN_TYPE_CD, DISTRICT_KY, CURR_FLG, EFF_START_DT, EFF_END_DT)
SELECT s.LOCN_ID, s.LOCN_NM, s.LOCN_TYPE_CD, s.DISTRICT_KY, TRUE,
       TO_DATE('{{ ds }}'), DATE '9999-12-31'
FROM SILVER.TMP_LOCN_SRC s
WHERE NOT EXISTS (SELECT 1 FROM RETAIL_DW.DIM_LOCN t
                  WHERE t.LOCN_ID = s.LOCN_ID AND t.CURR_FLG);

-- 3. SCD1: name and type overwritten in place (latest loaded date only)
UPDATE RETAIL_DW.DIM_LOCN t
   SET LOCN_NM = s.LOCN_NM, LOCN_TYPE_CD = s.LOCN_TYPE_CD, UPDATE_TS = CURRENT_TIMESTAMP()
  FROM SILVER.TMP_LOCN_SRC s
 WHERE t.LOCN_ID = s.LOCN_ID
   AND (t.LOCN_NM <> s.LOCN_NM OR t.LOCN_TYPE_CD <> s.LOCN_TYPE_CD)
   AND TO_DATE('{{ ds }}') >= (SELECT COALESCE(MAX(BUSINESS_DATE), TO_DATE('1900-01-01'))
                               FROM SILVER.AUD_RECONCILIATION);

COMMIT;

-- ROWS_OK = current versions; ROWS_REJECTED = stores whose district is not in DIM_DISTRICT
SELECT
    (SELECT COUNT(*) FROM RETAIL_DW.DIM_LOCN WHERE CURR_FLG) AS ROWS_OK,
    (SELECT COUNT(*) FROM SILVER.SLV_STORE WHERE BUSINESS_DATE = TO_DATE('{{ ds }}'))
      - (SELECT COUNT(*) FROM SILVER.TMP_LOCN_SRC)          AS ROWS_REJECTED;

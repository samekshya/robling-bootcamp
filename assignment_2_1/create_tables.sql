-- Creates the RETAIL_DW schema (if it doesn't exist) and switches to it,
-- so every table below is created inside RETAIL_DW.
CREATE SCHEMA IF NOT EXISTS snowflake_learning_db.retail_dw;
USE SCHEMA snowflake_learning_db.retail_dw;

-- Drops all tables (if they exist) so the script can be re-run from scratch.
-- Facts are dropped first, then dimensions from child to parent,
-- because child tables reference their parents.
DROP TABLE IF EXISTS FCT_PRICE;
DROP TABLE IF EXISTS FCT_INVENTORY;
DROP TABLE IF EXISTS FCT_SALES;
DROP TABLE IF EXISTS DIM_CUSTOMER;
DROP TABLE IF EXISTS DIM_DAY;
DROP TABLE IF EXISTS DIM_WEEK;
DROP TABLE IF EXISTS DIM_MONTH;
DROP TABLE IF EXISTS DIM_YEAR;
DROP TABLE IF EXISTS DIM_LOCN;
DROP TABLE IF EXISTS DIM_DISTRICT;
DROP TABLE IF EXISTS DIM_REGN;
DROP TABLE IF EXISTS DIM_AREA;
DROP TABLE IF EXISTS DIM_ITEM;
DROP TABLE IF EXISTS DIM_SUBCATG;
DROP TABLE IF EXISTS DIM_CATG;

-- =====================================================================
-- PRODUCT HIERARCHY: DIM_CATG -> DIM_SUBCATG -> DIM_ITEM
-- Source: RMS DEPS (department) -> SUBCLASS -> ITEM_MASTER
-- =====================================================================

-- DIM_CATG: top level of the product hierarchy (RMS department,
-- e.g. Mens Apparel, Footwear). One row per category.
-- SCD1: the name is overwritten when it changes.
CREATE TABLE DIM_CATG (
    CATG_KY    INTEGER AUTOINCREMENT,
    CATG_ID    INTEGER      NOT NULL,
    CATG_NM    VARCHAR(100) NOT NULL,
    INSERT_TS  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_DIM_CATG    PRIMARY KEY (CATG_KY),
    CONSTRAINT UK_DIM_CATG_ID UNIQUE (CATG_ID)
);

-- DIM_SUBCATG: middle level of the product hierarchy (RMS subclass,
-- e.g. Tees, Polos). Each subcategory belongs to one category
-- (CATG_KY -> DIM_CATG). SCD1.
CREATE TABLE DIM_SUBCATG (
    SUBCATG_KY  INTEGER AUTOINCREMENT,
    SUBCATG_ID  INTEGER      NOT NULL,
    SUBCATG_NM  VARCHAR(100) NOT NULL,
    CATG_KY     INTEGER      NOT NULL,
    INSERT_TS   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_DIM_SUBCATG       PRIMARY KEY (SUBCATG_KY),
    CONSTRAINT UK_DIM_SUBCATG_ID    UNIQUE (SUBCATG_ID),
    CONSTRAINT FK_DIM_SUBCATG_CATG  FOREIGN KEY (CATG_KY) REFERENCES DIM_CATG (CATG_KY)
);

-- DIM_ITEM: bottom level of the product hierarchy (individual products).
-- SCD2: keeps history when brand or subcategory changes.
CREATE TABLE DIM_ITEM (
    ITEM_KY       INTEGER AUTOINCREMENT,
    ITEM_ID       INTEGER      NOT NULL,
    ITEM_NM       VARCHAR(150) NOT NULL,
    BRAND_NM      VARCHAR(100),
    SUBCATG_KY    INTEGER      NOT NULL,
    CURR_FLG      BOOLEAN      NOT NULL DEFAULT TRUE,
    EFF_START_DT  DATE         NOT NULL,
    EFF_END_DT    DATE         NOT NULL DEFAULT DATE '9999-12-31',
    INSERT_TS     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_DIM_ITEM         PRIMARY KEY (ITEM_KY),
    CONSTRAINT UK_DIM_ITEM_VER     UNIQUE (ITEM_ID, EFF_START_DT),
    CONSTRAINT FK_DIM_ITEM_SUBCATG FOREIGN KEY (SUBCATG_KY) REFERENCES DIM_SUBCATG (SUBCATG_KY)
);

-- =====================================================================
-- LOCATION HIERARCHY: DIM_AREA -> DIM_REGN -> DIM_DISTRICT -> DIM_LOCN
-- Source: RMS AREA -> REGION -> DISTRICT -> STORE / WH
-- =====================================================================

-- DIM_AREA: top level of the location hierarchy
-- (East, Central, West, Canada). One row per area.
-- SCD1: the name is overwritten when it changes.
CREATE TABLE DIM_AREA (
    AREA_KY    INTEGER AUTOINCREMENT,
    AREA_ID    INTEGER      NOT NULL,
    AREA_NM    VARCHAR(100) NOT NULL,
    INSERT_TS  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_DIM_AREA    PRIMARY KEY (AREA_KY),
    CONSTRAINT UK_DIM_AREA_ID UNIQUE (AREA_ID)
);

-- DIM_REGN: second level of the location hierarchy (e.g. Northeast, Ontario).
-- Each region belongs to one area (AREA_KY -> DIM_AREA).
-- SCD1: name, country and parent area are overwritten when they change.
CREATE TABLE DIM_REGN (
    REGN_KY     INTEGER AUTOINCREMENT,
    REGN_ID     INTEGER      NOT NULL,
    REGN_NM     VARCHAR(100) NOT NULL,
    COUNTRY_NM  VARCHAR(100) NOT NULL,
    AREA_KY     INTEGER      NOT NULL,
    INSERT_TS   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_DIM_REGN      PRIMARY KEY (REGN_KY),
    CONSTRAINT UK_DIM_REGN_ID   UNIQUE (REGN_ID),
    CONSTRAINT FK_DIM_REGN_AREA FOREIGN KEY (AREA_KY) REFERENCES DIM_AREA (AREA_KY)
);

-- DIM_DISTRICT: third level of the location hierarchy (e.g. Northeast D1).
-- Each district belongs to one region (REGN_KY -> DIM_REGN).
-- SCD1: name and parent region are overwritten when they change.
CREATE TABLE DIM_DISTRICT (
    DISTRICT_KY  INTEGER AUTOINCREMENT,
    DISTRICT_ID  INTEGER      NOT NULL,
    DISTRICT_NM  VARCHAR(100) NOT NULL,
    REGN_KY      INTEGER      NOT NULL,
    INSERT_TS    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_DIM_DISTRICT      PRIMARY KEY (DISTRICT_KY),
    CONSTRAINT UK_DIM_DISTRICT_ID   UNIQUE (DISTRICT_ID),
    CONSTRAINT FK_DIM_DISTRICT_REGN FOREIGN KEY (REGN_KY) REFERENCES DIM_REGN (REGN_KY)
);

-- DIM_LOCN: bottom level of the location hierarchy: stores, warehouses
-- and the web store. LOCN_TYPE_CD: S = store, W = warehouse, E = ecommerce.
-- Warehouses and the web store have no real district, so they point to a
-- reserved "Not applicable" district row (DISTRICT_KY = -1).
-- SCD2: keeps history when a store moves to a different district
-- (store 1112 moves on 15 Sep 2026).
CREATE TABLE DIM_LOCN (
    LOCN_KY       INTEGER AUTOINCREMENT,
    LOCN_ID       INTEGER      NOT NULL,
    LOCN_NM       VARCHAR(150) NOT NULL,
    LOCN_TYPE_CD  VARCHAR(1)   NOT NULL,
    DISTRICT_KY   INTEGER      NOT NULL,
    CURR_FLG      BOOLEAN      NOT NULL DEFAULT TRUE,
    EFF_START_DT  DATE         NOT NULL,
    EFF_END_DT    DATE         NOT NULL DEFAULT DATE '9999-12-31',
    INSERT_TS     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_DIM_LOCN          PRIMARY KEY (LOCN_KY),
    CONSTRAINT UK_DIM_LOCN_VER      UNIQUE (LOCN_ID, EFF_START_DT),
    CONSTRAINT FK_DIM_LOCN_DISTRICT FOREIGN KEY (DISTRICT_KY) REFERENCES DIM_DISTRICT (DISTRICT_KY)
);

-- =====================================================================
-- CALENDAR: retail 4-5-4 fiscal calendar, weeks start on Sunday.
-- DIM_YEAR -> DIM_MONTH (fiscal period) -> DIM_DAY
-- DIM_YEAR -> DIM_WEEK  (fiscal week)   -> DIM_DAY
-- Source: finance FISCAL_CALENDAR_SEED
-- =====================================================================

-- DIM_YEAR: fiscal year (52 weeks, starts on a Sunday in early February,
-- e.g. FY2025 = 2 Feb 2025 to 31 Jan 2026). SCD1.
CREATE TABLE DIM_YEAR (
    YEAR_KY        INTEGER AUTOINCREMENT,
    YEAR_ID        INTEGER   NOT NULL,
    YEAR_START_DT  DATE      NOT NULL,
    YEAR_END_DT    DATE      NOT NULL,
    INSERT_TS      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_DIM_YEAR    PRIMARY KEY (YEAR_KY),
    CONSTRAINT UK_DIM_YEAR_ID UNIQUE (YEAR_ID)
);

-- DIM_MONTH: fiscal period (12 per year, each 4 or 5 whole weeks
-- in a 4-5-4 pattern), e.g. MONTH_ID 202601 = period 1 of FY2026.
-- Each period belongs to one fiscal year (YEAR_KY -> DIM_YEAR). SCD1.
CREATE TABLE DIM_MONTH (
    MONTH_KY          INTEGER AUTOINCREMENT,
    MONTH_ID          INTEGER     NOT NULL,
    MONTH_NUM         INTEGER     NOT NULL,
    MONTH_NM          VARCHAR(20) NOT NULL,
    WEEKS_IN_MONTH_NUM INTEGER    NOT NULL,
    MONTH_START_DT    DATE        NOT NULL,
    MONTH_END_DT      DATE        NOT NULL,
    YEAR_KY           INTEGER     NOT NULL,
    INSERT_TS         TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS         TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_DIM_MONTH      PRIMARY KEY (MONTH_KY),
    CONSTRAINT UK_DIM_MONTH_ID   UNIQUE (MONTH_ID),
    CONSTRAINT FK_DIM_MONTH_YEAR FOREIGN KEY (YEAR_KY) REFERENCES DIM_YEAR (YEAR_KY)
);

-- DIM_WEEK: fiscal week, Sunday to Saturday (1-52 per fiscal year),
-- e.g. WEEK_ID 202615 = week 15 of FY2026.
-- Each week belongs to one fiscal year (YEAR_KY -> DIM_YEAR). SCD1.
CREATE TABLE DIM_WEEK (
    WEEK_KY        INTEGER AUTOINCREMENT,
    WEEK_ID        INTEGER   NOT NULL,
    WEEK_NUM       INTEGER   NOT NULL,
    WEEK_START_DT  DATE      NOT NULL,
    WEEK_END_DT    DATE      NOT NULL,
    YEAR_KY        INTEGER   NOT NULL,
    INSERT_TS      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_DIM_WEEK      PRIMARY KEY (WEEK_KY),
    CONSTRAINT UK_DIM_WEEK_ID   UNIQUE (WEEK_ID),
    CONSTRAINT FK_DIM_WEEK_YEAR FOREIGN KEY (YEAR_KY) REFERENCES DIM_YEAR (YEAR_KY)
);

-- DIM_DAY: one row per calendar date, where both calendar paths meet,
-- e.g. DAY_ID 20261105 = 5 November 2026. Each day belongs to one fiscal
-- week (WEEK_KY) and one fiscal period (MONTH_KY).
-- HOLIDAY_NM is filled for holidays such as Black Friday. SCD1.
CREATE TABLE DIM_DAY (
    DAY_KY      INTEGER AUTOINCREMENT,
    DAY_ID      INTEGER     NOT NULL,
    FULL_DT     DATE        NOT NULL,
    DAY_NUM     INTEGER     NOT NULL,
    HOLIDAY_NM  VARCHAR(50),
    WEEK_KY     INTEGER     NOT NULL,
    MONTH_KY    INTEGER     NOT NULL,
    INSERT_TS   TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS   TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_DIM_DAY       PRIMARY KEY (DAY_KY),
    CONSTRAINT UK_DIM_DAY_ID    UNIQUE (DAY_ID),
    CONSTRAINT UK_DIM_DAY_DT    UNIQUE (FULL_DT),
    CONSTRAINT FK_DIM_DAY_WEEK  FOREIGN KEY (WEEK_KY)  REFERENCES DIM_WEEK (WEEK_KY),
    CONSTRAINT FK_DIM_DAY_MONTH FOREIGN KEY (MONTH_KY) REFERENCES DIM_MONTH (MONTH_KY)
);

-- =====================================================================
-- CUSTOMER
-- =====================================================================

-- DIM_CUSTOMER: one row per customer. The source data has no customer
-- feed, so for now it holds only the reserved row CUSTOMER_KY = -1,
-- "Unknown customer", which every sale points to. The table is kept so a
-- customer feed can be added later without changing the facts.
-- SCD1: name and loyalty status are overwritten when they change.
CREATE TABLE DIM_CUSTOMER (
    CUSTOMER_KY   INTEGER AUTOINCREMENT,
    CUSTOMER_ID   INTEGER      NOT NULL,
    CUSTOMER_NM   VARCHAR(150) NOT NULL,
    LOYALTY_FLG   BOOLEAN      NOT NULL DEFAULT FALSE,
    INSERT_TS     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_DIM_CUSTOMER    PRIMARY KEY (CUSTOMER_KY),
    CONSTRAINT UK_DIM_CUSTOMER_ID UNIQUE (CUSTOMER_ID)
);

-- =====================================================================
-- FACTS
-- Amounts are stored in the location's currency; CURRENCY_CD says which
-- (USD for US stores, CAD for the two Ottawa stores).
-- =====================================================================

-- FCT_SALES: transaction fact, the heart of the model.
-- Grain: one row per sales transaction line (TXN_ID + TXN_LINE_ID),
--        for one item, at one location, on one day.
CREATE TABLE FCT_SALES (
    SLS_LINE_KY     BIGINT AUTOINCREMENT,
    TXN_ID          VARCHAR(60)   NOT NULL,
    TXN_LINE_ID     INTEGER       NOT NULL,
    ITEM_KY         INTEGER       NOT NULL,
    LOCN_KY         INTEGER       NOT NULL,
    DAY_KY          INTEGER       NOT NULL,
    CUSTOMER_KY     INTEGER       NOT NULL,
    SLS_QTY         INTEGER       NOT NULL,
    UNIT_PRICE_AMT  NUMERIC(12,2) NOT NULL,
    SLS_AMT         NUMERIC(14,2) NOT NULL,
    CURRENCY_CD     VARCHAR(3)    NOT NULL,
    INSERT_TS       TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS       TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_FCT_SALES      PRIMARY KEY (SLS_LINE_KY),
    CONSTRAINT UK_FCT_SALES_BK   UNIQUE (TXN_ID, TXN_LINE_ID),
    CONSTRAINT FK_FCT_SALES_ITEM FOREIGN KEY (ITEM_KY)     REFERENCES DIM_ITEM (ITEM_KY),
    CONSTRAINT FK_FCT_SALES_LOCN FOREIGN KEY (LOCN_KY)     REFERENCES DIM_LOCN (LOCN_KY),
    CONSTRAINT FK_FCT_SALES_DAY  FOREIGN KEY (DAY_KY)      REFERENCES DIM_DAY (DAY_KY),
    CONSTRAINT FK_FCT_SALES_CUST FOREIGN KEY (CUSTOMER_KY) REFERENCES DIM_CUSTOMER (CUSTOMER_KY)
);

-- FCT_INVENTORY: positional fact (stock on hand).
-- Grain: one row per item and location for each period
--        (EFF_START_DT to EFF_END_DT) during which the on-hand quantity
--        stayed the same. A new row is added only when the quantity changes.
-- ONHAND_QTY keeps two decimals because the source sends fractional
-- quantities; negative stock is kept as reported by RMS.
CREATE TABLE FCT_INVENTORY (
    INV_KY          BIGINT AUTOINCREMENT,
    ITEM_KY         INTEGER       NOT NULL,
    LOCN_KY         INTEGER       NOT NULL,
    EFF_START_DT    DATE          NOT NULL,
    EFF_END_DT      DATE          NOT NULL DEFAULT DATE '9999-12-31',
    ONHAND_QTY      NUMERIC(12,2) NOT NULL,
    INV_VALUE_AMT   NUMERIC(14,2) NOT NULL,
    CURRENCY_CD     VARCHAR(3)    NOT NULL,
    INSERT_TS       TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS       TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_FCT_INVENTORY      PRIMARY KEY (INV_KY),
    CONSTRAINT UK_FCT_INVENTORY_BK   UNIQUE (ITEM_KY, LOCN_KY, EFF_START_DT),
    CONSTRAINT FK_FCT_INVENTORY_ITEM FOREIGN KEY (ITEM_KY) REFERENCES DIM_ITEM (ITEM_KY),
    CONSTRAINT FK_FCT_INVENTORY_LOCN FOREIGN KEY (LOCN_KY) REFERENCES DIM_LOCN (LOCN_KY)
);

-- FCT_PRICE: positional fact (list price of each item at each location).
-- Grain: one row per item and location for each price period,
--        starting on DAY_KY and valid from EFF_START_DT to EFF_END_DT.
-- Zone prices from RPM are spread to every location in the zone.
CREATE TABLE FCT_PRICE (
    PRICE_KY      BIGINT AUTOINCREMENT,
    ITEM_KY       INTEGER       NOT NULL,
    LOCN_KY       INTEGER       NOT NULL,
    DAY_KY        INTEGER       NOT NULL,
    PRICE_AMT     NUMERIC(12,2) NOT NULL,
    CURRENCY_CD   VARCHAR(3)    NOT NULL,
    EFF_START_DT  DATE          NOT NULL,
    EFF_END_DT    DATE          NOT NULL DEFAULT DATE '9999-12-31',
    INSERT_TS     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATE_TS     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_FCT_PRICE      PRIMARY KEY (PRICE_KY),
    CONSTRAINT UK_FCT_PRICE_BK   UNIQUE (ITEM_KY, LOCN_KY, DAY_KY),
    CONSTRAINT FK_FCT_PRICE_ITEM FOREIGN KEY (ITEM_KY) REFERENCES DIM_ITEM (ITEM_KY),
    CONSTRAINT FK_FCT_PRICE_LOCN FOREIGN KEY (LOCN_KY) REFERENCES DIM_LOCN (LOCN_KY),
    CONSTRAINT FK_FCT_PRICE_DAY  FOREIGN KEY (DAY_KY)  REFERENCES DIM_DAY (DAY_KY)
);

-- Lists every table in the schema to confirm all 15 were created.
SHOW TABLES;
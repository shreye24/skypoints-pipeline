-- =====================================================================
-- SkyPoints member pipeline - Snowflake DDL
-- Layers:  RAW (landing, all-VARCHAR, append-only)
--          STG (typed, validated, derived columns)
--          CORE (one table per country + routing table + unified view)
--          OPS (reference data, DQ results)
-- =====================================================================
CREATE DATABASE IF NOT EXISTS SKYPOINTS;
USE DATABASE SKYPOINTS;
CREATE SCHEMA IF NOT EXISTS RAW;
CREATE SCHEMA IF NOT EXISTS STG;
CREATE SCHEMA IF NOT EXISTS CORE;
CREATE SCHEMA IF NOT EXISTS OPS;

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS OPS.REF_COUNTRY (
    country_code  VARCHAR(3)   NOT NULL,   -- canonical ISO 3166 alpha-3
    country_name  VARCHAR(100) NOT NULL,
    target_table  VARCHAR(100) NOT NULL,   -- table in CORE, e.g. TABLE_INDIA
    CONSTRAINT pk_ref_country PRIMARY KEY (country_code)
);

-- Source-system spellings -> canonical code (sample data has AU, PHIL, ...)
CREATE TABLE IF NOT EXISTS OPS.REF_COUNTRY_ALIAS (
    alias         VARCHAR(5) NOT NULL,
    country_code  VARCHAR(3) NOT NULL,
    CONSTRAINT pk_ref_country_alias PRIMARY KEY (alias)
);

CREATE TABLE IF NOT EXISTS OPS.REF_TIER (
    tier_code VARCHAR(5) NOT NULL,
    CONSTRAINT pk_ref_tier PRIMARY KEY (tier_code)
);

MERGE INTO OPS.REF_COUNTRY t USING (
    SELECT * FROM VALUES
        ('IND','India','TABLE_INDIA'),
        ('USA','United States','TABLE_USA'),
        ('AUS','Australia','TABLE_AUSTRALIA'),
        ('CAN','Canada','TABLE_CANADA'),
        ('PHL','Philippines','TABLE_PHILIPPINES')
    AS v(country_code, country_name, target_table)) s
ON t.country_code = s.country_code
WHEN NOT MATCHED THEN INSERT VALUES (s.country_code, s.country_name, s.target_table);

MERGE INTO OPS.REF_COUNTRY_ALIAS t USING (
    SELECT * FROM VALUES
        ('IND','IND'),('IN','IND'),('USA','USA'),('US','USA'),
        ('AUS','AUS'),('AU','AUS'),('CAN','CAN'),('PHL','PHL'),('PHIL','PHL'),('PH','PHL')
    AS v(alias, country_code)) s
ON t.alias = s.alias
WHEN NOT MATCHED THEN INSERT VALUES (s.alias, s.country_code);

MERGE INTO OPS.REF_TIER t USING (SELECT * FROM VALUES ('GLD'),('SLV'),('PLT') AS v(tier_code)) s
ON t.tier_code = s.tier_code WHEN NOT MATCHED THEN INSERT VALUES (s.tier_code);

-- ---------------------------------------------------------------------
-- RAW: landing tables. Everything VARCHAR so a bad value can never fail
-- the load; lineage columns let us replay/audit any row.
-- ---------------------------------------------------------------------
CREATE FILE FORMAT IF NOT EXISTS RAW.FF_MEMBER_PIPE
    TYPE = CSV FIELD_DELIMITER = '|' SKIP_HEADER = 1
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE   -- short rows land as NULLs; caught by DQ
    EMPTY_FIELD_AS_NULL = TRUE NULL_IF = ('', 'NULL')
    TRIM_SPACE = TRUE ENCODING = 'UTF8';

CREATE TABLE IF NOT EXISTS RAW.MEMBER_FEED (
    filler            VARCHAR,      -- text before the leading '|'
    rec_type          VARCHAR,      -- 'D' for detail rows
    member_name       VARCHAR,
    member_id         VARCHAR,
    enrollment_date   VARCHAR,
    last_flight_date  VARCHAR,
    tier_code         VARCHAR,
    agent_name        VARCHAR,
    state             VARCHAR,
    country           VARCHAR,
    dob               VARCHAR,
    is_active         VARCHAR,
    post_code         VARCHAR,      -- in the design doc layout, absent from the sample feed
    -- lineage
    source_file       VARCHAR   NOT NULL,
    source_file_row   NUMBER    NOT NULL,
    feed_date         DATE      NOT NULL,   -- business date of the feed (from file name)
    loaded_at         TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (feed_date);

-- Load pattern (run by Snowpipe auto-ingest or a scheduled task):
-- COPY INTO RAW.MEMBER_FEED (filler, rec_type, member_name, member_id, enrollment_date,
--        last_flight_date, tier_code, agent_name, state, country, dob, is_active, post_code,
--        source_file, source_file_row, feed_date)
-- FROM (SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,
--              METADATA$FILENAME, METADATA$FILE_ROW_NUMBER,
--              TO_DATE(REGEXP_SUBSTR(METADATA$FILENAME,'[0-9]{8}'),'YYYYMMDD')
--       FROM @RAW.MEMBER_STAGE)
-- FILE_FORMAT = (FORMAT_NAME = RAW.FF_MEMBER_PIPE) ON_ERROR = CONTINUE;
-- Files should be split to ~100-250 MB compressed so the warehouse loads them in parallel.

CREATE FILE FORMAT IF NOT EXISTS RAW.FF_REDEMPTION_NDJSON TYPE = JSON;

-- One JSON document (one member) per line = NDJSON. Do NOT ship a single giant
-- array: it forces STRIP_OUTER_ARRAY and a single-threaded parse at scale.
CREATE TABLE IF NOT EXISTS RAW.REDEMPTION_FEED (
    doc               VARIANT   NOT NULL,
    source_file       VARCHAR   NOT NULL,
    source_file_row   NUMBER    NOT NULL,
    loaded_at         TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (TO_DATE(doc:feed_date::STRING, 'YYYYMMDD'));

-- ---------------------------------------------------------------------
-- STG: typed + derived. One row per valid-or-invalid source row; the
-- dq_errors array is what routes a row to quarantine (no row is dropped).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS STG.MEMBER (
    member_id         VARCHAR(18)  NOT NULL,   -- treated as the business key (see README)
    member_name       VARCHAR(255),
    enrollment_date   DATE,
    last_flight_date  DATE,
    tier_code         CHAR(5),
    agent_name        VARCHAR(255),
    state             VARCHAR(5),
    country_code      VARCHAR(3),              -- canonical, after alias mapping
    country_raw       VARCHAR(20),             -- as received, kept for audit
    post_code         VARCHAR(5),              -- VARCHAR not INT: leading zeros (e.g. 02134)
    dob               DATE,
    is_active         CHAR(1),
    member_type       CHAR(1),                 -- I/C, only some country extracts carry it
    -- derived
    age               NUMBER(3,0),             -- whole years at run_date
    stale_member      BOOLEAN,                 -- days since last_flight_date > 90; NULL if never flew
    -- lineage + DQ
    source_file       VARCHAR,
    source_file_row   NUMBER,
    feed_date         DATE         NOT NULL,
    run_date          DATE         NOT NULL,   -- as-of date used for age/stale
    dq_errors         ARRAY,                   -- rules that quarantine the row
    dq_warnings       ARRAY,                   -- rules that load the row but are reported
    is_valid          BOOLEAN      NOT NULL,
    loaded_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (feed_date, country_code);

CREATE OR REPLACE VIEW STG.MEMBER_QUARANTINE AS
    SELECT * FROM STG.MEMBER WHERE NOT is_valid;

-- ---------------------------------------------------------------------
-- CORE: country tables are all cloned from one template so they can never
-- drift. Additional countries are created on demand by SP_SPLIT_BY_COUNTRY.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CORE.MEMBER_TEMPLATE (
    member_id         VARCHAR(18)  NOT NULL,
    member_name       VARCHAR(255) NOT NULL,
    enrollment_date   DATE         NOT NULL,
    last_flight_date  DATE,
    tier_code         CHAR(5),
    agent_name        VARCHAR(255),
    state             VARCHAR(5),
    country_code      VARCHAR(3)   NOT NULL,
    post_code         VARCHAR(5),
    dob               DATE,
    is_active         CHAR(1),
    member_type       CHAR(1),
    age               NUMBER(3,0),
    stale_member      BOOLEAN,
    feed_date         DATE         NOT NULL,   -- feed the current version came from (latest wins)
    source_file       VARCHAR,
    updated_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_member PRIMARY KEY (member_id)   -- informational in Snowflake; enforced by MERGE + DQ check
);

CREATE TABLE IF NOT EXISTS CORE.TABLE_INDIA       LIKE CORE.MEMBER_TEMPLATE;
CREATE TABLE IF NOT EXISTS CORE.TABLE_USA         LIKE CORE.MEMBER_TEMPLATE;
CREATE TABLE IF NOT EXISTS CORE.TABLE_AUSTRALIA   LIKE CORE.MEMBER_TEMPLATE;
CREATE TABLE IF NOT EXISTS CORE.TABLE_CANADA      LIKE CORE.MEMBER_TEMPLATE;
CREATE TABLE IF NOT EXISTS CORE.TABLE_PHILIPPINES LIKE CORE.MEMBER_TEMPLATE;

-- Routing table: "which country table currently holds this member?"
-- Lets a country move be handled with one targeted DELETE instead of scanning
-- every country table (matters at billions of rows).
CREATE TABLE IF NOT EXISTS CORE.MEMBER_ROUTING (
    member_id     VARCHAR(18) NOT NULL,
    country_code  VARCHAR(3)  NOT NULL,
    feed_date     DATE        NOT NULL,
    CONSTRAINT pk_member_routing PRIMARY KEY (member_id)
)
CLUSTER BY (member_id);

-- Unified view (rebuilt by the split procedure whenever a country is added).
CREATE OR REPLACE VIEW CORE.V_MEMBER_ALL AS
    SELECT * FROM CORE.TABLE_INDIA       UNION ALL
    SELECT * FROM CORE.TABLE_USA         UNION ALL
    SELECT * FROM CORE.TABLE_AUSTRALIA   UNION ALL
    SELECT * FROM CORE.TABLE_CANADA      UNION ALL
    SELECT * FROM CORE.TABLE_PHILIPPINES;

-- ---------------------------------------------------------------------
-- Redemptions (flattened fact) - see 04_redemptions.sql
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CORE.REDEMPTION (
    txn_id          VARCHAR(30)  NOT NULL,
    member_id       VARCHAR(18)  NOT NULL,
    txn_date        DATE,
    partner         VARCHAR(100),
    miles_redeemed  NUMBER(12,0),
    status          VARCHAR(20),
    feed_date       DATE         NOT NULL,   -- feed the current version came from
    source_file     VARCHAR,
    updated_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_redemption PRIMARY KEY (txn_id)
)
CLUSTER BY (txn_date);

CREATE TABLE IF NOT EXISTS STG.REDEMPTION_REJECT (
    txn_id VARCHAR, member_id VARCHAR, feed_date DATE, reason VARCHAR,
    payload VARIANT, source_file VARCHAR, rejected_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------
-- DQ results: every check writes one row per run
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS OPS.DQ_RESULT (
    run_id        VARCHAR,
    check_name    VARCHAR,
    severity      VARCHAR,          -- ERROR | WARN
    failed_rows   NUMBER,
    total_rows    NUMBER,
    passed        BOOLEAN,
    detail        VARCHAR,
    checked_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =====================================================================
-- Stage -> RAW with COPY INTO.
-- 1. Upload files into the stages first (Snowsight: Ingestion > Add Data > Load files into a Stage,
--    or SnowSQL / Snowflake CLI:  PUT file://members_20240115.txt @RAW.MEMBER_STAGE).
-- 2. Run this script.
-- COPY tracks which files it has loaded (64-day load metadata), so re-running never double-loads a file.
-- =====================================================================
USE DATABASE SKYPOINTS;
USE WAREHOUSE COMPUTE_WH;

LIST @RAW.MEMBER_STAGE;
LIST @RAW.REDEMPTION_STAGE;

-- Member files: one row per LINE (header + detail records), nothing parsed yet.
COPY INTO RAW.MEMBER_LINE (raw_line, source_file, source_file_row, feed_date)
FROM (
    SELECT $1,
           METADATA$FILENAME,
           METADATA$FILE_ROW_NUMBER,
           TO_DATE(REGEXP_SUBSTR(METADATA$FILENAME, '[0-9]{8}'), 'YYYYMMDD')
    FROM @RAW.MEMBER_STAGE
)
FILE_FORMAT = (FORMAT_NAME = RAW.FF_MEMBER_LINE)
ON_ERROR = CONTINUE;

-- Redemption files: one JSON document per line (NDJSON).
COPY INTO RAW.REDEMPTION_FEED (doc, source_file, source_file_row)
FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER FROM @RAW.REDEMPTION_STAGE)
FILE_FORMAT = (FORMAT_NAME = RAW.FF_REDEMPTION_NDJSON)
ON_ERROR = CONTINUE;

SELECT (SELECT COUNT(*) FROM RAW.MEMBER_LINE)      AS member_lines,
       (SELECT COUNT(*) FROM RAW.REDEMPTION_FEED) AS redemption_docs;

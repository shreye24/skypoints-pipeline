-- =====================================================================
-- OPTIONAL scale smoke test: 3,000,000 members on day 1, then a day-2 file of 600,000 updates in which
-- most members change country. Exercises the set-based path (01b -> 02 -> 03) at millions of rows and
-- shows the routing-table country moves at volume. It is NOT a billions-of-rows benchmark.
-- Run on an XSMALL warehouse (a few credits at most). Run sections in order; between sections run the
-- pipeline scripts as noted. Start from an EMPTY database (DROP DATABASE SKYPOINTS, rerun 01_ddl, 03 proc, 04 views).
-- =====================================================================
USE DATABASE SKYPOINTS;
USE WAREHOUSE COMPUTE_WH;

-- ---- SECTION A: generate day 1 (2025-01-01) ----
INSERT INTO RAW.MEMBER_LINE (raw_line, source_file, source_file_row, feed_date)
SELECT '|H|Member_Name|Member_Id|Enrollment_Date|Last_Flight_Date|Tier_Code|Agent_Name|State|Country|DOB|Is_Active',
       'scale_20250101.txt', 1, '2025-01-01'::DATE;

INSERT INTO RAW.MEMBER_LINE (raw_line, source_file, source_file_row, feed_date)
SELECT '|D|Member ' || seq || '|' || (100000000 + seq) || '|'
       || TO_CHAR(DATEADD('day', -UNIFORM(200, 5000, RANDOM()), '2025-01-01'::DATE), 'YYYYMMDD') || '|'
       || TO_CHAR(DATEADD('day', -UNIFORM(0, 400, RANDOM()), '2025-01-01'::DATE), 'YYYYMMDD') || '|'
       || GET(ARRAY_CONSTRUCT('GLD','SLV','PLT'), UNIFORM(0, 2, RANDOM()))::STRING || '|Agent|ST|'
       || GET(ARRAY_CONSTRUCT('USA','IND','AUS','CAN','PHL'), UNIFORM(0, 4, RANDOM()))::STRING || '|'
       || TO_CHAR(DATEADD('day', -UNIFORM(7000, 25000, RANDOM()), '2025-01-01'::DATE), 'DDMMYYYY') || '|A',
       'scale_20250101.txt', seq + 2, '2025-01-01'::DATE
FROM (SELECT SEQ8() AS seq FROM TABLE(GENERATOR(ROWCOUNT => 3000000)));

-- >>> Now run 01b_split_lines.sql, then 02_staging_load.sql (SET run_date = '2025-01-01', batch_id = 'scale_1'),
-- >>> then CALL CORE.SP_SPLIT_BY_COUNTRY();   Note the elapsed time of each step in Snowsight.

-- ---- SECTION B: generate day 2 (2025-01-02): 600,000 existing members re-sent (every 5th id), random new country ----
INSERT INTO RAW.MEMBER_LINE (raw_line, source_file, source_file_row, feed_date)
SELECT '|H|Member_Name|Member_Id|Enrollment_Date|Last_Flight_Date|Tier_Code|Agent_Name|State|Country|DOB|Is_Active',
       'scale_20250102.txt', 1, '2025-01-02'::DATE;

INSERT INTO RAW.MEMBER_LINE (raw_line, source_file, source_file_row, feed_date)
SELECT '|D|Member ' || (seq * 5) || '|' || (100000000 + seq * 5) || '|'
       || TO_CHAR(DATEADD('day', -UNIFORM(200, 5000, RANDOM()), '2025-01-02'::DATE), 'YYYYMMDD') || '|'
       || TO_CHAR(DATEADD('day', -UNIFORM(0, 30, RANDOM()), '2025-01-02'::DATE), 'YYYYMMDD') || '|'
       || GET(ARRAY_CONSTRUCT('GLD','SLV','PLT'), UNIFORM(0, 2, RANDOM()))::STRING || '|Agent|ST|'
       || GET(ARRAY_CONSTRUCT('USA','IND','AUS','CAN','PHL'), UNIFORM(0, 4, RANDOM()))::STRING || '|'
       || TO_CHAR(DATEADD('day', -UNIFORM(7000, 25000, RANDOM()), '2025-01-02'::DATE), 'DDMMYYYY') || '|A',
       'scale_20250102.txt', seq + 2, '2025-01-02'::DATE
FROM (SELECT SEQ8() AS seq FROM TABLE(GENERATOR(ROWCOUNT => 600000)));

-- >>> Run 01b, then 02 (run_date = '2025-01-02', batch_id = 'scale_2'), then CALL CORE.SP_SPLIT_BY_COUNTRY();
-- >>> Expect roughly 480,000 country moves (4 in 5 random countries differ from the old one).

-- ---- SECTION C: verify ----
SELECT country_code, COUNT(*) AS members FROM CORE.V_MEMBER_ALL GROUP BY 1 ORDER BY 1;           -- total must be 3,000,000
SELECT COUNT(*) AS members_in_more_than_one_table
FROM (SELECT member_id FROM CORE.V_MEMBER_ALL GROUP BY 1 HAVING COUNT(*) > 1);                     -- must be 0
SELECT COUNT(*) AS routing_rows, COUNT_IF(feed_date = '2025-01-02') AS updated_by_day2 FROM CORE.MEMBER_ROUTING;  -- 3,000,000 / 600,000
SELECT LEFT(query_text, 70) AS statement, ROUND(total_elapsed_time / 1000, 1) AS seconds
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(RESULT_LIMIT => 60))
WHERE query_type IN ('INSERT', 'CALL', 'MERGE', 'DELETE', 'UPDATE', 'CREATE_TABLE_AS_SELECT')
ORDER BY start_time DESC;

-- ---- CLEAN UP: return to an empty database before running the sample data again ----
-- DROP DATABASE SKYPOINTS;   then rerun 01_ddl.sql, 03_country_split.sql (procedure), 04_redemptions.sql

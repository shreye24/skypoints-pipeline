-- =====================================================================
-- RAW.MEMBER_LINE -> RAW.MEMBER_FEED
-- Splits each detail line into columns using the column order declared in THAT FILE'S header record,
-- and records how many fields the line has vs. how many the header declares (short/long rows are
-- flagged in staging, never padded with NULLs and passed off as valid).
-- Header-driven, so the 10-column sample layout and the 11-column design-doc layout both work.
-- Reads the append-only stream, so each new line is processed exactly once.
-- =====================================================================
USE DATABASE SKYPOINTS;
USE WAREHOUSE COMPUTE_WH;

INSERT INTO RAW.MEMBER_FEED (
    filler, rec_type, member_name, member_id, enrollment_date, last_flight_date, tier_code, agent_name,
    state, country, dob, is_active, post_code, member_type, field_count, expected_field_count,
    source_file, source_file_row, feed_date)
WITH hdr AS (            -- header record of each file, upper-cased and split: ['', 'H', 'MEMBER_NAME', ...]
    SELECT source_file, SPLIT(UPPER(REGEXP_REPLACE(raw_line, '\\r$', '')), '|') AS h
    FROM RAW.MEMBER_LINE
    WHERE SPLIT_PART(raw_line, '|', 2) = 'H'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY source_file ORDER BY source_file_row) = 1
),
det AS (                 -- new detail lines only
    SELECT source_file, source_file_row, feed_date,
           SPLIT(REGEXP_REPLACE(raw_line, '\\r$', ''), '|') AS p
    FROM RAW.MEMBER_LINE_STREAM
    WHERE SPLIT_PART(raw_line, '|', 2) = 'D'
)
SELECT
    NULL, 'D',
    NULLIF(TRIM(GET(d.p, ARRAY_POSITION('MEMBER_NAME'::VARIANT,     h.h))::STRING), ''),
    NULLIF(TRIM(GET(d.p, ARRAY_POSITION('MEMBER_ID'::VARIANT,       h.h))::STRING), ''),
    NULLIF(TRIM(GET(d.p, ARRAY_POSITION('ENROLLMENT_DATE'::VARIANT, h.h))::STRING), ''),
    NULLIF(TRIM(GET(d.p, ARRAY_POSITION('LAST_FLIGHT_DATE'::VARIANT,h.h))::STRING), ''),
    NULLIF(TRIM(GET(d.p, ARRAY_POSITION('TIER_CODE'::VARIANT,       h.h))::STRING), ''),
    NULLIF(TRIM(GET(d.p, ARRAY_POSITION('AGENT_NAME'::VARIANT,      h.h))::STRING), ''),
    NULLIF(TRIM(GET(d.p, ARRAY_POSITION('STATE'::VARIANT,           h.h))::STRING), ''),
    NULLIF(TRIM(GET(d.p, ARRAY_POSITION('COUNTRY'::VARIANT,         h.h))::STRING), ''),
    NULLIF(TRIM(GET(d.p, ARRAY_POSITION('DOB'::VARIANT,             h.h))::STRING), ''),
    NULLIF(TRIM(GET(d.p, ARRAY_POSITION('IS_ACTIVE'::VARIANT,       h.h))::STRING), ''),
    NULLIF(TRIM(GET(d.p, ARRAY_POSITION('POST_CODE'::VARIANT,       h.h))::STRING), ''),
    NULLIF(TRIM(GET(d.p, ARRAY_POSITION('MEMBER_TYPE'::VARIANT,     h.h))::STRING), ''),
    ARRAY_SIZE(d.p) - 2,
    ARRAY_SIZE(h.h) - 2,
    d.source_file, d.source_file_row, d.feed_date
FROM det d
LEFT JOIN hdr h ON h.source_file = d.source_file;   -- no header -> expected_field_count NULL -> flagged MISSING_HEADER

-- Nothing may be lost between the two landing tables (checked again in 05_validations.sql)
SELECT (SELECT COUNT(*) FROM RAW.MEMBER_LINE WHERE SPLIT_PART(raw_line, '|', 2) = 'D') AS detail_lines,
       (SELECT COUNT(*) FROM RAW.MEMBER_FEED) AS split_rows;

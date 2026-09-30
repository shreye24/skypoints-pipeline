-- =====================================================================
-- RAW.MEMBER_FEED -> STG.MEMBER   (deliverable 2: Age + Stale_Member)
-- One set-based INSERT..SELECT: no row-by-row logic, no row can fail the load.
-- Bad values become NULL + an entry in dq_errors / dq_warnings; no raw row is dropped.
-- Parameters (constants, set by the orchestrator per run):
--   run_date  = as-of date for Age / Stale_Member
--   batch_id  = id of this run, stamped on every row it produces
-- Reads the append-only stream on RAW.MEMBER_FEED (exactly-once incremental processing).
-- =====================================================================
USE DATABASE SKYPOINTS;
USE WAREHOUSE COMPUTE_WH;

SET run_date = '2024-01-16'::DATE;
SET batch_id = 'batch_001';

INSERT INTO STG.MEMBER (member_id, member_name, enrollment_date, last_flight_date, tier_code, agent_name, state,
    country_code, country_raw, post_code, dob, is_active, member_type, age, stale_member, source_file,
    source_file_row, feed_date, run_date, dq_errors, dq_warnings, is_valid, batch_id, loaded_at)
WITH src AS (
    SELECT
        NULLIF(TRIM(r.member_id), '')                              AS member_id,
        NULLIF(TRIM(r.member_name), '')                            AS member_name,
        -- Enrollment/flight: YYYYMMDD.  DOB: DDMMYYYY with a lost leading zero restored (3051985 -> 03051985)
        TRY_TO_DATE(NULLIF(TRIM(r.enrollment_date), ''),  'YYYYMMDD')            AS enrollment_date,
        TRY_TO_DATE(NULLIF(TRIM(r.last_flight_date), ''), 'YYYYMMDD')            AS last_flight_date,
        TRY_TO_DATE(LPAD(NULLIF(TRIM(r.dob), ''), 8, '0'), 'DDMMYYYY')           AS dob,
        r.enrollment_date AS enrollment_date_txt, r.last_flight_date AS last_flight_date_txt, r.dob AS dob_txt,
        UPPER(NULLIF(TRIM(r.tier_code), ''))                       AS tier_code,
        NULLIF(TRIM(r.agent_name), '')                             AS agent_name,
        UPPER(NULLIF(TRIM(r.state), ''))                           AS state,
        UPPER(NULLIF(TRIM(r.country), ''))                         AS country_raw,
        NULLIF(TRIM(r.post_code), '')                              AS post_code,
        UPPER(NULLIF(TRIM(r.is_active), ''))                       AS is_active,
        UPPER(NULLIF(TRIM(r.member_type), ''))                     AS member_type,
        r.field_count, r.expected_field_count,
        r.source_file, r.source_file_row, r.feed_date
    FROM RAW.MEMBER_FEED_STREAM r
    WHERE r.rec_type = 'D'
),
enriched AS (
    SELECT s.*,
           a.country_code,
           -- ---- derived columns ----
           IFF(s.dob IS NULL OR s.dob > $run_date, NULL,
               DATEDIFF('year', s.dob, $run_date)
               - IFF(DATEADD('year', DATEDIFF('year', s.dob, $run_date), s.dob) > $run_date, 1, 0)) AS age,
           IFF(s.last_flight_date IS NULL, NULL,
               DATEDIFF('day', s.last_flight_date, $run_date) > 90)                                  AS stale_member
    FROM src s
    LEFT JOIN OPS.REF_COUNTRY_ALIAS a ON a.alias = s.country_raw
),
checked AS (
    SELECT e.*,
        ARRAY_COMPACT(ARRAY_CONSTRUCT(
            IFF(expected_field_count IS NULL, 'MISSING_HEADER',
                IFF(field_count <> expected_field_count, 'BAD_FIELD_COUNT:' || field_count || 'vs' || expected_field_count, NULL)),
            IFF(member_id   IS NULL, 'MISSING_MANDATORY:member_id', NULL),
            IFF(member_name IS NULL, 'MISSING_MANDATORY:member_name', NULL),
            IFF(enrollment_date_txt IS NULL OR TRIM(enrollment_date_txt) = '', 'MISSING_MANDATORY:enrollment_date',
                IFF(enrollment_date IS NULL, 'INVALID_DATE:' || enrollment_date_txt, NULL)),
            IFF(country_raw IS NULL, 'UNROUTABLE_COUNTRY:missing',
                IFF(country_code IS NULL, 'UNROUTABLE_COUNTRY:' || country_raw, NULL)),
            IFF(LENGTH(member_id) > 18,  'LENGTH_EXCEEDED:member_id>18', NULL),
            IFF(LENGTH(member_name) > 255, 'LENGTH_EXCEEDED:member_name>255', NULL),
            IFF(LENGTH(state) > 5,       'LENGTH_EXCEEDED:state>5', NULL),
            IFF(LENGTH(post_code) > 5,   'LENGTH_EXCEEDED:post_code>5', NULL),
            IFF(enrollment_date > $run_date, 'ENROLLMENT_IN_FUTURE', NULL),
            IFF(dob > $run_date,             'DOB_IN_FUTURE', NULL)
        )) AS dq_errors,
        ARRAY_COMPACT(ARRAY_CONSTRUCT(
            IFF(dob IS NULL AND NULLIF(TRIM(dob_txt),'') IS NOT NULL, 'INVALID_DATE:dob', NULL),
            IFF(last_flight_date IS NULL AND NULLIF(TRIM(last_flight_date_txt),'') IS NOT NULL, 'INVALID_DATE:last_flight_date', NULL),
            IFF(country_code IS NOT NULL AND country_raw <> country_code, 'COUNTRY_ALIAS_MAPPED:' || country_raw || '->' || country_code, NULL),
            IFF(tier_code IS NOT NULL AND tier_code NOT IN (SELECT tier_code FROM OPS.REF_TIER), 'UNKNOWN_TIER:' || tier_code, NULL),
            IFF(is_active IS NOT NULL AND is_active NOT IN ('A','I'), 'UNKNOWN_ACTIVE_FLAG:' || is_active, NULL),
            IFF(post_code IS NOT NULL AND NOT REGEXP_LIKE(post_code, '[0-9]+'), 'NON_NUMERIC_POST_CODE:' || post_code, NULL),
            IFF(last_flight_date < enrollment_date, 'FLIGHT_BEFORE_ENROLLMENT', NULL),
            IFF(last_flight_date > $run_date,       'FLIGHT_IN_FUTURE', NULL),
            IFF(dob >= enrollment_date,             'DOB_NOT_BEFORE_ENROLLMENT', NULL),
            IFF(age > 120,                          'AGE_OVER_120', NULL)
        )) AS dq_warnings
    FROM enriched e
)
SELECT
    member_id, member_name, enrollment_date, last_flight_date, tier_code, agent_name, state,
    country_code, country_raw, post_code, dob, is_active, member_type,
    age, stale_member,
    source_file, source_file_row, feed_date, $run_date AS run_date,
    dq_errors, dq_warnings,
    ARRAY_SIZE(dq_errors) = 0 AS is_valid,
    $batch_id,
    CURRENT_TIMESTAMP()
FROM checked;   -- no WHERE: every raw row is kept; bad ones land with is_valid = FALSE

-- ---------------------------------------------------------------------------------------------
-- Batch-level warnings: rules that need the whole file, applied to this batch's rows only.
-- (Same rules as the Python reference implementation in staging.py.)
-- ---------------------------------------------------------------------------------------------
-- 1. Member-id length outliers vs the file's dominant length (needs >= 50% of the file at that length)
UPDATE STG.MEMBER m
SET dq_warnings = ARRAY_APPEND(m.dq_warnings, 'MEMBER_ID_LENGTH_OUTLIER:' || LENGTH(m.member_id) || 'vs' || f.mode_len)
FROM (
    SELECT source_file, LENGTH(member_id) AS mode_len
    FROM STG.MEMBER WHERE batch_id = $batch_id AND member_id IS NOT NULL
    GROUP BY source_file, LENGTH(member_id)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY source_file ORDER BY COUNT(*) DESC) = 1
       AND COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY source_file) >= 0.5
) f
WHERE m.batch_id = $batch_id AND m.source_file = f.source_file
  AND m.member_id IS NOT NULL AND LENGTH(m.member_id) <> f.mode_len;

-- 2. Placeholder columns: one value covering >= 80% of a file's non-null values (files with >= 3 values)
UPDATE STG.MEMBER m SET dq_warnings = ARRAY_APPEND(m.dq_warnings, 'SUSPECT_CONSTANT_COLUMN:dob')
FROM (SELECT source_file FROM STG.MEMBER WHERE batch_id = $batch_id AND dob IS NOT NULL
      GROUP BY source_file, dob
      QUALIFY COUNT(*) >= 3 AND COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY source_file) >= 0.8) f
WHERE m.batch_id = $batch_id AND m.source_file = f.source_file;

UPDATE STG.MEMBER m SET dq_warnings = ARRAY_APPEND(m.dq_warnings, 'SUSPECT_CONSTANT_COLUMN:enrollment_date')
FROM (SELECT source_file FROM STG.MEMBER WHERE batch_id = $batch_id AND enrollment_date IS NOT NULL
      GROUP BY source_file, enrollment_date
      QUALIFY COUNT(*) >= 3 AND COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY source_file) >= 0.8) f
WHERE m.batch_id = $batch_id AND m.source_file = f.source_file;

UPDATE STG.MEMBER m SET dq_warnings = ARRAY_APPEND(m.dq_warnings, 'SUSPECT_CONSTANT_COLUMN:last_flight_date')
FROM (SELECT source_file FROM STG.MEMBER WHERE batch_id = $batch_id AND last_flight_date IS NOT NULL
      GROUP BY source_file, last_flight_date
      QUALIFY COUNT(*) >= 3 AND COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY source_file) >= 0.8) f
WHERE m.batch_id = $batch_id AND m.source_file = f.source_file;

-- 3. Same member_id more than once in one file (resolved later by latest-wins, but reported)
UPDATE STG.MEMBER m SET dq_warnings = ARRAY_APPEND(m.dq_warnings, 'DUPLICATE_KEY_IN_FILE')
FROM (SELECT source_file, member_id FROM STG.MEMBER
      WHERE batch_id = $batch_id AND member_id IS NOT NULL
      GROUP BY source_file, member_id HAVING COUNT(*) > 1) d
WHERE m.batch_id = $batch_id AND m.source_file = d.source_file AND m.member_id = d.member_id;

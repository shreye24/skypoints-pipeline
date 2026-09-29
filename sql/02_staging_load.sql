-- =====================================================================
-- RAW.MEMBER_FEED -> STG.MEMBER   (deliverable 2: Age + Stale_Member)
-- One set-based INSERT..SELECT: no row-by-row logic, no row can fail the load.
-- Bad values become NULL + an entry in dq_errors / dq_warnings.
-- Parameter: run_date (as-of date for Age / Stale_Member). Bind per run.
-- =====================================================================
SET run_date  = CURRENT_DATE();
SET batch_lo  = (SELECT COALESCE(MAX(feed_date), '1900-01-01'::DATE) FROM STG.MEMBER);  -- incremental watermark
-- (Replace with a Snowflake STREAM on RAW.MEMBER_FEED for exactly-once incremental processing.)

INSERT INTO STG.MEMBER
WITH src AS (
    SELECT
        NULLIF(TRIM(r.member_id), '')                              AS member_id,
        NULLIF(TRIM(r.member_name), '')                            AS member_name,
        -- Enrollment/flight: YYYYMMDD.  DOB: DDMMYYYY with the lost leading zero restored (3051985 -> 03051985)
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
        r.source_file, r.source_file_row, r.feed_date
    FROM RAW.MEMBER_FEED r
    WHERE r.rec_type = 'D'
      AND r.feed_date > $batch_lo
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
            IFF(last_flight_date < enrollment_date, 'FLIGHT_BEFORE_ENROLLMENT', NULL),
            IFF(last_flight_date > $run_date,       'FLIGHT_IN_FUTURE', NULL),
            IFF(dob >= enrollment_date,             'DOB_NOT_BEFORE_ENROLLMENT', NULL),
            IFF(age > 120,                          'AGE_OVER_120', NULL)
        )) AS dq_warnings
    FROM enriched e
)
SELECT
    member_id, member_name, enrollment_date, last_flight_date, tier_code, agent_name, state,
    country_code, country_raw, post_code, dob, is_active,
    NULL AS member_type,
    age, stale_member,
    source_file, source_file_row, feed_date, $run_date AS run_date,
    dq_errors, dq_warnings,
    ARRAY_SIZE(dq_errors) = 0 AS is_valid,
    CURRENT_TIMESTAMP()
FROM checked
WHERE member_id IS NOT NULL OR TRUE;   -- keep rows with NULL keys too: they land as invalid, not dropped
-- NB: STG.MEMBER.member_id is NOT NULL in the DDL for the typed layer; if you prefer NULL-key rows to be
-- retained in staging, relax that constraint (recommended) or route them to a reject table.

-- Batch-level warnings (need the whole file, so done as a second pass) -----------------------------
-- 1. Member-id length outliers vs the file's dominant length (sample: 6,6,6,5,4)
UPDATE STG.MEMBER m
SET dq_warnings = ARRAY_APPEND(m.dq_warnings, 'MEMBER_ID_LENGTH_OUTLIER:' || LENGTH(m.member_id) || 'vs' || f.mode_len)
FROM (
    SELECT source_file, LENGTH(member_id) AS mode_len
    FROM STG.MEMBER WHERE loaded_at >= DATEADD('hour', -1, CURRENT_TIMESTAMP())
    GROUP BY source_file, LENGTH(member_id)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY source_file ORDER BY COUNT(*) DESC) = 1
       AND COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY source_file) >= 0.5
) f
WHERE m.source_file = f.source_file AND LENGTH(m.member_id) <> f.mode_len
  AND m.loaded_at >= DATEADD('hour', -1, CURRENT_TIMESTAMP());
-- 2. Suspect constant columns (every row has the same DOB etc.) are reported by OPS.DQ_RESULT in 05_validations.sql.

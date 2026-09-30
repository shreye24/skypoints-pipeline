USE DATABASE SKYPOINTS;
USE WAREHOUSE COMPUTE_WH;

-- =====================================================================
-- Data validations (deliverable 5). Each check writes a row to OPS.DQ_RESULT.
-- ERROR checks gate the pipeline (task stops / alert); WARN checks are reported only.
-- Row-level rules already ran in 02_staging_load.sql (dq_errors/dq_warnings); these are batch/set-level.
-- =====================================================================
-- Snowflake's SET only accepts constant expressions (UUID_STRING() fails), so the orchestrator passes the run id.
SET run_id = 'run_001';

INSERT INTO OPS.DQ_RESULT (run_id, check_name, severity, failed_rows, total_rows, passed, detail)
WITH t AS (SELECT COUNT(*) AS n FROM STG.MEMBER WHERE applied_at IS NULL OR applied_at >= DATEADD('day', -1, CURRENT_TIMESTAMP())),
checks AS (
    -- 1. Mandatory fields: no VALID row may lack one (bad rows are quarantined and reported separately)
    SELECT 'mandatory_fields_in_valid_rows' AS name, 'ERROR' AS sev,
           COUNT_IF(is_valid AND (member_id IS NULL OR member_name IS NULL OR enrollment_date IS NULL)) AS failed,
           'member_id, member_name, enrollment_date must be present on every valid row' AS detail FROM STG.MEMBER
    UNION ALL SELECT 'quarantined_rows', 'WARN', COUNT_IF(NOT is_valid),
           'rows that failed an ERROR rule (see STG.MEMBER_QUARANTINE)' FROM STG.MEMBER
    -- 2. Key uniqueness: (a) in the batch, (b) in each target, (c) across ALL country tables
    UNION ALL SELECT 'batch_duplicate_keys', 'WARN', COUNT(*), 'member_id repeated in staging; latest wins resolves it'
        FROM (SELECT member_id FROM STG.MEMBER WHERE is_valid AND applied_at IS NULL GROUP BY 1 HAVING COUNT(*) > 1)
    UNION ALL SELECT 'target_unique_across_countries', 'ERROR', COUNT(*), 'member_id present in >1 country table (a move was not cleaned up)'
        FROM (SELECT member_id FROM CORE.V_MEMBER_ALL GROUP BY 1 HAVING COUNT(*) > 1)
    UNION ALL SELECT 'routing_matches_tables', 'ERROR', COUNT(*), 'routing country differs from the table holding the member'
        FROM CORE.V_MEMBER_ALL m JOIN CORE.MEMBER_ROUTING r USING (member_id) WHERE m.country_code <> r.country_code
    -- 3. Referential / domain
    UNION ALL SELECT 'unroutable_country', 'ERROR', COUNT_IF(ARRAY_TO_STRING(dq_errors, ',') ILIKE '%UNROUTABLE_COUNTRY%'), 'country not in REF_COUNTRY_ALIAS' FROM STG.MEMBER
    UNION ALL SELECT 'unknown_tier', 'WARN', COUNT_IF(ARRAY_TO_STRING(dq_warnings, ',') ILIKE '%UNKNOWN_TIER%'), 'tier_code not in REF_TIER' FROM STG.MEMBER
    -- 4. Issues visible in the sample data
    UNION ALL SELECT 'country_alias_used', 'WARN', COUNT_IF(country_raw <> country_code), 'AU / PHIL style non-canonical country codes' FROM STG.MEMBER
    UNION ALL SELECT 'member_id_length_outlier', 'WARN', COUNT_IF(ARRAY_TO_STRING(dq_warnings, ',') ILIKE '%MEMBER_ID_LENGTH_OUTLIER%'), 'IDs shorter/longer than the file mode (22345, 2256)' FROM STG.MEMBER
    UNION ALL SELECT 'flight_before_enrollment', 'WARN', COUNT_IF(last_flight_date < enrollment_date), 'impossible chronology' FROM STG.MEMBER
    UNION ALL SELECT 'dob_after_enrollment', 'WARN', COUNT_IF(dob >= enrollment_date), 'member enrolled before being born' FROM STG.MEMBER
    UNION ALL SELECT 'age_out_of_range', 'WARN', COUNT_IF(age > 120 OR age < 0), 'implausible age' FROM STG.MEMBER
    -- Placeholder detection: a column where one value covers >= 80% of a file (sample: every DOB = 03051985)
    UNION ALL SELECT 'suspect_constant_column_rows', 'WARN', COUNT_IF(ARRAY_TO_STRING(dq_warnings, ',') ILIKE '%SUSPECT_CONSTANT_COLUMN%'),
        'rows in files where one DOB / enrollment / flight date covers >=80% of the values' FROM STG.MEMBER
    UNION ALL SELECT 'field_count_errors', 'WARN', COUNT_IF(ARRAY_TO_STRING(dq_errors, ',') ILIKE '%FIELD_COUNT%' OR ARRAY_TO_STRING(dq_errors, ',') ILIKE '%MISSING_HEADER%'),
        'lines with fewer/more fields than their file header declares (quarantined)' FROM STG.MEMBER
    -- Source-vs-staging reconciliation: catches a load that silently drops columns (sample staging lost Agent_Name)
    UNION ALL SELECT 'recon_row_count', 'ERROR',
        ABS((SELECT COUNT(*) FROM RAW.MEMBER_FEED WHERE rec_type = 'D') - (SELECT COUNT(*) FROM STG.MEMBER)),
        'RAW detail rows must equal STG rows (nothing dropped)' FROM (SELECT 1 AS x)
    UNION ALL SELECT 'recon_line_to_feed', 'ERROR',
        ABS((SELECT COUNT(*) FROM RAW.MEMBER_LINE WHERE SPLIT_PART(raw_line, '|', 2) = 'D') - (SELECT COUNT(*) FROM RAW.MEMBER_FEED)),
        'every detail line landed must appear in RAW.MEMBER_FEED after the split' FROM (SELECT 1 AS x)
    UNION ALL SELECT 'recon_agent_name', 'ERROR',
        GREATEST((SELECT COUNT_IF(NULLIF(TRIM(agent_name),'') IS NOT NULL) FROM RAW.MEMBER_FEED WHERE rec_type='D')
               - (SELECT COUNT_IF(agent_name IS NOT NULL) FROM STG.MEMBER), 0),
        'agent_name non-null count dropped between RAW and STG' FROM (SELECT 1 AS x)
    -- Redemptions
    UNION ALL SELECT 'redemption_unique_txn', 'ERROR', COUNT(*), 'txn_id duplicated in CORE.REDEMPTION'
        FROM (SELECT txn_id FROM CORE.REDEMPTION GROUP BY 1 HAVING COUNT(*) > 1)
    UNION ALL SELECT 'redemption_orphans', 'WARN', COUNT(*), 'redemptions whose member is unknown' FROM CORE.V_REDEMPTION_ORPHAN
    UNION ALL SELECT 'redemption_rejects', 'WARN', COUNT(*), 'rows in STG.REDEMPTION_REJECT' FROM STG.REDEMPTION_REJECT
)
SELECT $run_id, name, sev, failed, (SELECT n FROM t), failed = 0, detail FROM checks;

-- Gate: fail the task if any ERROR check failed
-- SELECT IFF(COUNT_IF(severity='ERROR' AND NOT passed) > 0,
--            1/0,  -- forces the task to fail and alert
--            0)
-- FROM OPS.DQ_RESULT WHERE run_id = $run_id;

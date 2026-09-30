USE DATABASE SKYPOINTS;
USE WAREHOUSE COMPUTE_WH;

-- =====================================================================
-- Semi-structured redemption feed -> flattened, queryable table  (deliverable 4)
-- Input shape: one JSON document per member per day (NDJSON), redemptions is an array.
-- =====================================================================

-- COPY INTO RAW.REDEMPTION_FEED (doc, source_file, source_file_row)
-- FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER FROM @RAW.REDEMPTION_STAGE)
-- FILE_FORMAT = (FORMAT_NAME = RAW.FF_REDEMPTION_NDJSON) ON_ERROR = CONTINUE;

-- 1. Flatten: one output row per redemption. TRY_ casts so a bad value can't fail the run.
--    LATERAL FLATTEN (no OUTER) drops members with an empty array - correct, they have no transactions.
CREATE OR REPLACE TRANSIENT TABLE STG.REDEMPTION_FLAT AS
SELECT
    NULLIF(TRIM(f.value:txn_id::STRING), '')                      AS txn_id,
    NULLIF(TRIM(d.doc:member_id::STRING), '')                     AS member_id,
    TRY_TO_DATE(f.value:txn_date::STRING, 'YYYYMMDD')             AS txn_date,
    f.value:partner::STRING                                       AS partner,
    TRY_TO_NUMBER(f.value:miles_redeemed::STRING)                 AS miles_redeemed,
    UPPER(f.value:status::STRING)                                 AS status,
    TRY_TO_DATE(d.doc:feed_date::STRING, 'YYYYMMDD')              AS feed_date,
    d.source_file, d.source_file_row,
    f.index                                                       AS array_pos,
    f.value                                                       AS payload
FROM RAW.REDEMPTION_FEED d,
     LATERAL FLATTEN(INPUT => d.doc:redemptions) f
WHERE d.loaded_at > COALESCE((SELECT MAX(updated_at) FROM CORE.REDEMPTION), '1900-01-01'::TIMESTAMP_NTZ);

-- 2. Validate; rejects go to a side table with the reason.
CREATE OR REPLACE TEMPORARY TABLE STG.REDEMPTION_CHECKED AS
SELECT s.*,
    ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(txn_id IS NULL,                     'MISSING_MANDATORY:txn_id', NULL),
        IFF(member_id IS NULL,                  'MISSING_MANDATORY:member_id', NULL),
        IFF(txn_date IS NULL,                   'INVALID_OR_MISSING_DATE:txn_date', NULL),
        IFF(feed_date IS NULL,                  'INVALID_OR_MISSING_DATE:feed_date', NULL),
        IFF(txn_date > feed_date,               'TXN_DATE_AFTER_FEED_DATE', NULL),
        IFF(miles_redeemed IS NULL OR miles_redeemed <= 0, 'INVALID_MILES', NULL),
        IFF(status NOT IN ('COMPLETED','PENDING','CANCELLED','REVERSED') OR status IS NULL, 'INVALID_STATUS', NULL)
    )), ';') AS reject_reason
FROM STG.REDEMPTION_FLAT s;

INSERT INTO STG.REDEMPTION_REJECT (txn_id, member_id, feed_date, reason, payload, source_file)
SELECT txn_id, member_id, feed_date, reject_reason, payload, source_file
FROM STG.REDEMPTION_CHECKED WHERE reject_reason <> '';

-- 3. Upsert. A txn re-appears in later feeds as its status changes (PENDING -> COMPLETED).
--    Newest feed wins; a late old file cannot roll a status backwards.
MERGE INTO CORE.REDEMPTION t
USING (
    SELECT txn_id, member_id, txn_date, partner, miles_redeemed, status, feed_date, source_file
    FROM STG.REDEMPTION_CHECKED
    WHERE reject_reason = ''
    QUALIFY ROW_NUMBER() OVER (PARTITION BY txn_id ORDER BY feed_date DESC, source_file DESC, source_file_row DESC) = 1
) s
ON t.txn_id = s.txn_id
WHEN MATCHED AND s.feed_date >= t.feed_date THEN UPDATE SET
    member_id = s.member_id, txn_date = s.txn_date, partner = s.partner, miles_redeemed = s.miles_redeemed,
    status = s.status, feed_date = s.feed_date, source_file = s.source_file, updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (txn_id, member_id, txn_date, partner, miles_redeemed, status, feed_date, source_file)
    VALUES (s.txn_id, s.member_id, s.txn_date, s.partner, s.miles_redeemed, s.status, s.feed_date, s.source_file);

-- =====================================================================
-- Joining redemptions back to member profiles
-- =====================================================================
-- Join key: member_id (VARCHAR, trimmed, identical in both feeds).
-- Members are split over many country tables, so join to the unified view CORE.V_MEMBER_ALL.
-- Because a member lives in exactly ONE country table (invariant enforced in 03 + 05), the join
-- cannot fan out. Country moves are handled for free: the member's *current* row is what joins.
CREATE OR REPLACE VIEW CORE.V_REDEMPTION_ENRICHED AS
SELECT r.txn_id, r.txn_date, r.partner, r.miles_redeemed, r.status,
       m.member_id, m.member_name, m.tier_code, m.country_code, m.state, m.is_active, m.stale_member
FROM CORE.REDEMPTION r
JOIN CORE.V_MEMBER_ALL m ON m.member_id = r.member_id;

-- Orphans (redemption without a known profile: unloaded, quarantined, or arrived first). LEFT JOIN, never drop.
CREATE OR REPLACE VIEW CORE.V_REDEMPTION_ORPHAN AS
SELECT r.* FROM CORE.REDEMPTION r
LEFT JOIN CORE.MEMBER_ROUTING m ON m.member_id = r.member_id
WHERE m.member_id IS NULL;
-- At scale join through CORE.MEMBER_ROUTING (member_id -> country_code) when you only need the country,
-- and to a single TABLE_<COUNTRY> when the query is country-scoped, so partition pruning applies.

-- Example: miles redeemed per country and tier, completed only
-- SELECT country_code, tier_code, SUM(miles_redeemed) FROM CORE.V_REDEMPTION_ENRICHED
-- WHERE status = 'COMPLETED' GROUP BY 1,2;

-- =====================================================================
-- STG.MEMBER -> CORE.TABLE_<COUNTRY>   (deliverable 3)
-- "Latest record wins", including members who moved countries.
--
-- Design for billions of rows:
--   * dedupe once (window function) into a transient batch table
--   * ROUTING table (member_id -> current country) so a move is a targeted DELETE
--     against ONE old table rather than a scan of every country table
--   * MERGE (set-based, idempotent) per country; late-arriving OLD files can never overwrite newer data
--   * whole apply step is one transaction -> a member is never in 0 or 2 country tables
--   * DDL (create table) happens BEFORE the transaction because Snowflake DDL auto-commits
-- =====================================================================
CREATE OR REPLACE PROCEDURE CORE.SP_SPLIT_BY_COUNTRY()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    -- one cursor per loop: re-using a single cursor for two FOR loops is fragile
    countries_ddl   CURSOR FOR SELECT DISTINCT country_code FROM CORE.BATCH_LATEST;
    countries_merge CURSOR FOR SELECT DISTINCT country_code FROM CORE.BATCH_APPLY;
    old_countries CURSOR FOR
        SELECT DISTINCT r.country_code AS old_cc
        FROM CORE.BATCH_APPLY b JOIN CORE.MEMBER_ROUTING r ON r.member_id = b.member_id
        WHERE r.country_code <> b.country_code;
    tbl VARCHAR;
    cc  VARCHAR;
    view_sql VARCHAR DEFAULT '';
    n_moved NUMBER DEFAULT 0;
    n_rows NUMBER DEFAULT 0;
BEGIN
    -- 1. Latest record per member for rows not yet applied. Newest feed wins; ties -> later file, later row.
    CREATE OR REPLACE TRANSIENT TABLE CORE.BATCH_LATEST AS
        SELECT member_id, member_name, enrollment_date, last_flight_date, tier_code, agent_name, state,
               country_code, post_code, dob, is_active, member_type, age, stale_member, feed_date, source_file
        FROM STG.MEMBER
        WHERE is_valid AND applied_at IS NULL
        QUALIFY ROW_NUMBER() OVER (PARTITION BY member_id
                                   ORDER BY feed_date DESC, source_file DESC, source_file_row DESC) = 1;
    n_rows := (SELECT COUNT(*) FROM CORE.BATCH_LATEST);

    -- 2. Make sure every country in the batch has a table (new country = no code change).
    FOR rec IN countries_ddl DO
        cc  := rec.country_code;
        tbl := COALESCE((SELECT target_table FROM OPS.REF_COUNTRY WHERE country_code = :cc), 'TABLE_' || :cc);
        EXECUTE IMMEDIATE 'CREATE TABLE IF NOT EXISTS CORE.' || tbl || ' LIKE CORE.MEMBER_TEMPLATE';
        INSERT INTO OPS.REF_COUNTRY (country_code, country_name, target_table)
            SELECT :cc, :cc, :tbl
            WHERE NOT EXISTS (SELECT 1 FROM OPS.REF_COUNTRY WHERE country_code = :cc);
    END FOR;

    -- 3. Work out what to apply. (DDL such as CREATE TABLE auto-commits in Snowflake, so all DDL is done
    --    before the transaction starts.)
    -- Rows that lost to a newer copy already stored are ignored (late-arriving old file).
    CREATE OR REPLACE TRANSIENT TABLE CORE.BATCH_APPLY AS
        SELECT b.* FROM CORE.BATCH_LATEST b
        LEFT JOIN CORE.MEMBER_ROUTING r ON r.member_id = b.member_id
        WHERE r.member_id IS NULL OR b.feed_date >= r.feed_date;
    n_moved := (SELECT COUNT(*) FROM CORE.BATCH_APPLY b JOIN CORE.MEMBER_ROUTING r ON r.member_id = b.member_id
                WHERE r.country_code <> b.country_code);

    -- 4. Apply atomically: a member is never in zero or two country tables.
    BEGIN TRANSACTION;

    -- 4a. Country moves: remove from the OLD country table (found via routing, one table per move).
    FOR old IN old_countries DO
        cc  := old.old_cc;
        tbl := (SELECT target_table FROM OPS.REF_COUNTRY WHERE country_code = :cc);
        EXECUTE IMMEDIATE
            'DELETE FROM CORE.' || tbl || ' t USING (' ||
            '  SELECT b.member_id FROM CORE.BATCH_APPLY b JOIN CORE.MEMBER_ROUTING r ON r.member_id = b.member_id ' ||
            '  WHERE r.country_code = ''' || cc || ''' AND b.country_code <> r.country_code) m ' ||
            'WHERE t.member_id = m.member_id';
    END FOR;

    -- 4b. Upsert into each destination country table.
    FOR rec IN countries_merge DO
        cc  := rec.country_code;
        tbl := (SELECT target_table FROM OPS.REF_COUNTRY WHERE country_code = :cc);
        EXECUTE IMMEDIATE
            'MERGE INTO CORE.' || tbl || ' t USING ' ||
            '(SELECT * FROM CORE.BATCH_APPLY WHERE country_code = ''' || cc || ''') s ' ||
            'ON t.member_id = s.member_id ' ||
            'WHEN MATCHED AND s.feed_date >= t.feed_date THEN UPDATE SET ' ||
            '  member_name=s.member_name, enrollment_date=s.enrollment_date, last_flight_date=s.last_flight_date, ' ||
            '  tier_code=s.tier_code, agent_name=s.agent_name, state=s.state, country_code=s.country_code, ' ||
            '  post_code=s.post_code, dob=s.dob, is_active=s.is_active, member_type=s.member_type, age=s.age, ' ||
            '  stale_member=s.stale_member, feed_date=s.feed_date, source_file=s.source_file, updated_at=CURRENT_TIMESTAMP() ' ||
            'WHEN NOT MATCHED THEN INSERT (member_id, member_name, enrollment_date, last_flight_date, tier_code, ' ||
            '  agent_name, state, country_code, post_code, dob, is_active, member_type, age, stale_member, feed_date, source_file) ' ||
            'VALUES (s.member_id, s.member_name, s.enrollment_date, s.last_flight_date, s.tier_code, s.agent_name, s.state, ' ||
            '  s.country_code, s.post_code, s.dob, s.is_active, s.member_type, s.age, s.stale_member, s.feed_date, s.source_file)';
    END FOR;

    -- 4c. Routing table follows the member.
    MERGE INTO CORE.MEMBER_ROUTING r USING CORE.BATCH_APPLY b ON r.member_id = b.member_id
    WHEN MATCHED THEN UPDATE SET country_code = b.country_code, feed_date = b.feed_date
    WHEN NOT MATCHED THEN INSERT (member_id, country_code, feed_date) VALUES (b.member_id, b.country_code, b.feed_date);

    -- 4d. Mark staging rows as applied (superseded duplicates included) so the next run is incremental.
    UPDATE STG.MEMBER SET applied_at = CURRENT_TIMESTAMP() WHERE is_valid AND applied_at IS NULL;

    COMMIT;

    -- 5. Rebuild the unified view (DDL, so after COMMIT) so new countries show up.
    SELECT LISTAGG('SELECT * FROM CORE.' || target_table, ' UNION ALL ') INTO :view_sql FROM OPS.REF_COUNTRY;
    EXECUTE IMMEDIATE 'CREATE OR REPLACE VIEW CORE.V_MEMBER_ALL AS ' || view_sql;

    RETURN 'batch rows=' || n_rows || ', country moves=' || n_moved;
END;
$$;

-- CALL CORE.SP_SPLIT_BY_COUNTRY();
-- Schedule with a TASK after the staging load, or trigger from a STREAM: 
--   CREATE TASK ... AFTER <staging-load task> AS CALL CORE.SP_SPLIT_BY_COUNTRY();

-- ---------------------------------------------------------------------
-- The same split as plain SQL for the 3 known countries (readable version of what the proc generates):
-- One MERGE per country as above. A single-statement alternative for *initial loads* (empty targets) is a multi-table insert:
--
-- INSERT ALL
--   WHEN country_code = 'IND' THEN INTO CORE.TABLE_INDIA     (member_id, member_name, ...) VALUES (member_id, member_name, ...)
--   WHEN country_code = 'USA' THEN INTO CORE.TABLE_USA       (member_id, member_name, ...) VALUES (member_id, member_name, ...)
--   WHEN country_code = 'AUS' THEN INTO CORE.TABLE_AUSTRALIA (member_id, member_name, ...) VALUES (member_id, member_name, ...)
-- SELECT * FROM CORE.BATCH_LATEST;

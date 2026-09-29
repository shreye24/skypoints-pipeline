# SkyPoints member & redemption pipeline

Snowflake-first design (SQL in `sql/`) with a Python reference implementation (`src/skypoints/`) that mirrors the
SQL logic, runs locally on the sample files, and is covered by 37 pytest tests (`python -m pytest`).

| Deliverable | Where |
|---|---|
| 1. DDL: raw, staging, country tables | `sql/01_ddl.sql` |
| 2. Staging load + `Age` + `Stale_Member` | `sql/02_staging_load.sql` · `staging.py` |
| 3. Split by country, latest-record-wins | `sql/03_country_split.sql` · `pipeline.py` |
| 4. JSON flatten + join back to members | `sql/04_redemptions.sql` · `redemptions.py` |
| 5. Validations | `sql/05_validations.sql` · `staging.py` · `tests/` |

Run locally: `PYTHONPATH=src python -m skypoints.cli --members data/sample/members_2024011*.txt --xlsx AUS=data/sample/AUS.xlsx USA=data/sample/USA.xlsx IND=data/sample/IND.xlsx --redemptions data/sample/redemptions_2024011*.ndjson --as-of 2024-01-16`

## Architecture

```
files ─COPY/Snowpipe─▶ RAW (all VARCHAR, append-only, lineage) ─stream─▶ STG.MEMBER (typed, derived, dq_errors/warnings)
                                                                           │ is_valid
                                                            latest-wins (window) + routing table
                                                                           ▼
                                   CORE.TABLE_INDIA / _USA / _AUSTRALIA / ... (cloned from one template) + V_MEMBER_ALL
JSON NDJSON ─▶ RAW.REDEMPTION_FEED (VARIANT) ─LATERAL FLATTEN─▶ CORE.REDEMPTION ──join on member_id──▶ V_MEMBER_ALL
```

Key decisions
- **Landing is all-VARCHAR.** A bad value can never fail a load of billions of rows; typing happens with `TRY_TO_DATE` in staging.
- **No row is ever dropped.** Bad rows stay in `STG.MEMBER` with `is_valid = FALSE` and a reason array (view `STG.MEMBER_QUARANTINE`). A RAW-vs-STG row-count reconciliation check enforces it.
- **Severity policy.** Missing/invalid *mandatory* field, unroutable country, length overflow, future enrollment/DOB → ERROR (quarantined). A bad value in an *optional* field → nulled + WARN, member still loads.
- **Set-based everywhere** (`INSERT…SELECT`, `QUALIFY ROW_NUMBER`, `MERGE`); nothing row-by-row. Streams give exactly-once incremental processing.
- **Latest record wins** = newest `feed_date`, ties → later file, later row. `MERGE` only overwrites when the incoming `feed_date >=` the stored one, so a late-arriving old file can't roll data back. Re-running a batch is idempotent (tested).
- **Country moves.** A `MEMBER_ROUTING` table (member_id → current country) makes a move one targeted `DELETE` from one table instead of scanning every country table; delete + insert + routing update run in one transaction so a member is never in 0 or 2 tables. New countries get a table automatically (`CREATE TABLE … LIKE template`), no code change.
- **Redemption join.** Flatten to one row/txn; join on `member_id` to `V_MEMBER_ALL`. Because a member is in exactly one country table there is no fan-out, and moves are handled automatically. Unmatched redemptions are surfaced (`V_REDEMPTION_ORPHAN`), not dropped, and match on a later run.
- **Feed format.** Ask the partner for NDJSON (one member document per line), not one giant array, so files split and parse in parallel. Split flat files to ~100–250 MB compressed.

## Issues found in the provided data (and what the pipeline does)

Sample flat file / staging table
1. **Country codes are inconsistent**: `AU` vs `AUS`, `PHIL` (not ISO). → alias table → ISO alpha-3, warning `COUNTRY_ALIAS_MAPPED`; unknown codes are quarantined.
2. **Member_Id lengths vary** (`223457` vs `22345` vs `2256`). → warning `MEMBER_ID_LENGTH_OUTLIER` vs the file's dominant length (VARCHAR(18), so not rejected, but likely truncated/padded upstream).
3. **Every row has the same DOB, enrollment and flight dates** → almost certainly placeholders. → `SUSPECT_CONSTANT_COLUMN`.
4. **Staging lost `Agent_Name`** for 4 of 5 rows (source has `Sam` on all). → source-vs-staging non-null reconciliation (`recon_agent_name`).
5. **Leading zero lost in DOB** (`03051985` → `3051985`). → left-padded to 8 digits before parsing.
6. Column drift: staging has `County` (typo), `FLAG` vs `Is_Active`, `Mem_Id`, `Name`, etc.; the doc's layout has **11 columns incl. Post Code but the sample has 10**. → flat-file reader is header-driven, not position-driven.
7. **Post Code is `INT`** in the spec → leading zeros would be lost (02134). I use `VARCHAR(5)`.
8. **`Member Name` is marked Key Column = Y**, `Member ID` = N. I treated this as a typo and use `member_id`; two different people can share a name.
9. Names/dates: all last flights are 2012 → everyone is stale (correct per the rule, but worth a sanity check with the business).

Country Excel extracts (`AUS/USA/IND.xlsx`)
10. **Three different layouts** (`Unique ID` / `ID`, `Tier Type` / `TierCode`, `Date of Flight` / `Flight Date`); only IND has `Individual or Corporate`; none has a country column. → per-country column mapping in `config.XLSX_PROFILES`; country taken from the file.
11. **IDs are per-country sequences (1,2,3 in every file)** → collide with each other and with global IDs. → prefixed (`AUS-1`). **Open question for the business.**
12. **Three date encodings**: real Excel dates, ISO strings, and USA as integers `MDDYYYY` (`6152022`, `1052022`). Leading zero is lost, so the integers are left-padded to `MMDDYYYY` (Jan 5 2022, not Oct 5). This assumes a zero-padded fixed-width source; the alternative reading is ambiguous, so please confirm.
13. **Junk values**: `2021-13-13` (invalid month) in AUS → mandatory enrollment date → quarantined; literal string `'NULL'` in AUS DOB → NULL; the "used range" contains blank rows → skipped.

Redemption feed
14. `partner: "SkyPoints"` on a redemption — SkyPoints is the program itself, not a partner airline. Flagged for the business, not rejected.
15. A txn appears again with a new status (`PENDING` → `COMPLETED`) → treated as an update (latest feed wins), not a duplicate.
16. Negative/zero miles, txn dated after its feed, bad status, missing txn_id, malformed JSON lines → rejected with reason; empty `redemptions` array → valid, zero rows.

## Assumptions / open questions
- `Stale_Member` is `TRUE` when `run_date − last_flight_date > 90` (strictly greater); **NULL** when the member has never flown (unknown ≠ stale). Easy to flip if the business wants never-flown = stale.
- `Age` = completed years at `run_date` (birthday-aware), NULL if DOB missing/invalid/future. Because it depends on the run date it is a *snapshot*; consider computing it in a view instead of storing it.
- Flat-file `DOB` format is not specified; I assumed `DDMMYYYY` (`03051985` is ambiguous: 3 May vs 5 March). Configurable in `config.FLAT_DATE_HINTS`.
- Flat-file `feed_date` comes from the file name (`YYYYMMDD`).

## Verification status

Verified
- **Python:** 37 pytest tests pass (also confirmed on Windows, Python 3.14, pandas 3), and the CLI reproduces the expected results on the sample files.
- **Snowflake (trial account, run end-to-end on the sample data):** DDL (`01`), staging load (`02`), country split incl. a USA -> CAN move and latest-wins (`03`), redemption flatten/upsert/join (`04`) and validations (`05`). Staging output matched the Python output row for row; the final country tables, routing table and DQ results matched expectations.

Bugs found by running it on Snowflake (and fixed)
- New SQL files have no database selected -> every script starts with `USE DATABASE` / `USE WAREHOUSE`.
- `03`: re-using one cursor for two `FOR` loops meant the country-table `MERGE` silently ran zero times while the routing table updated. Now one cursor per loop.
- `05`: `SET run_id = UUID_STRING()` is rejected (SET needs a constant), so the run id is passed in. The mandatory-field check also counted quarantined rows as pipeline failures; it now checks valid rows only, with quarantined rows reported as a WARN.

Not verified on Snowflake
- `COPY INTO` from a stage and Snowpipe/streams/tasks: the sample rows were loaded with `sql/00_sample_data_inserts.sql` instead. The `COPY` statements in `01_ddl.sql` are untested.
- Performance at billions of rows (reasoned, not benchmarked).
- The Excel country extracts are handled by the Python readers only; there is no Snowflake load path for them yet.

Run order on Snowflake: `01_ddl` -> `00_sample_data_inserts` (or COPY) -> `02_staging_load` (set `run_date`) -> `03_country_split`, then `CALL CORE.SP_SPLIT_BY_COUNTRY()` -> `04_redemptions` -> `05_validations`. To see a country move, mark the 16 Jan staging rows applied first, call the procedure, then unmark them and call it again.

## Known limitations
- **Short rows are not caught in the Snowflake path.** A detail row with too few fields (e.g. `|D|Liam|223462|...|USA`) lands with NULLs and is staged as valid, while the Python reader rejects it as `BAD_FIELD_COUNT`. Proposed fix: land each line whole (`raw_line`) and `SPLIT` it in staging, so the field count can be checked. Not implemented.
- Row-level warnings `SUSPECT_CONSTANT_COLUMN` and `DUPLICATE_KEY_IN_FILE` exist in Python only; on Snowflake they are covered by set-level checks in `05_validations.sql` (and only for DOB).
- `02_staging_load.sql` stamps `applied_at` on all pending valid rows at the end of the split; rows landing mid-run should be excluded with a batch id in production.
- The Python runner is in-memory pandas (demo scale); the production path for billions of rows is the SQL.
- Age/stale columns on country tables are point-in-time; refresh daily or expose them through a view.

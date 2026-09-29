import datetime as dt

import pandas as pd
import pytest

from skypoints import pipeline, readers, redemptions, staging
from skypoints.dates import age_in_years, parse_date

AS_OF = dt.date(2024, 1, 16)
S = "data/sample/"


def raw_flat(name):
    df, rej = readers.read_flat_file(S + name)
    return df, rej


# ---------- dates ----------
@pytest.mark.parametrize("val,hint,exp", [
    ("20101012", "YMD", dt.date(2010, 10, 12)),
    ("03051985", "DMY", dt.date(1985, 5, 3)),
    ("3051985", "DMY", dt.date(1985, 5, 3)),        # leading zero lost
    (6152022, "MDY", dt.date(2022, 6, 15)),          # USA xlsx, int
    (1052022, "MDY", dt.date(2022, 1, 5)),
    (12282021, "MDY", dt.date(2021, 12, 28)),
    ("2022-05-11", "YMD", dt.date(2022, 5, 11)),
    (dt.datetime(2022, 5, 11), "YMD", dt.date(2022, 5, 11)),
])
def test_parse_date_ok(val, hint, exp):
    assert parse_date(val, hint) == (exp, None)


@pytest.mark.parametrize("val", ["2021-13-13", "20151332", "abc", "3051985"])
def test_parse_date_bad(val):
    d, err = parse_date(val, "YMD")
    assert d is None and err.startswith("INVALID_DATE")


@pytest.mark.parametrize("val", ["NULL", "", None, "  "])
def test_parse_date_null(val):
    assert parse_date(val) == (None, None)


def test_age_birthday_boundary():
    assert age_in_years(dt.date(1985, 5, 3), dt.date(2024, 5, 2)) == 38
    assert age_in_years(dt.date(1985, 5, 3), dt.date(2024, 5, 3)) == 39
    assert age_in_years(dt.date(2000, 2, 29), dt.date(2023, 2, 28)) == 22


# ---------- staging / derived columns ----------
def test_age_and_stale_flag():
    raw, _ = raw_flat("members_20240116.txt")
    s = staging.stage(raw, AS_OF).set_index("source_file_row")
    elena = s.loc[2]
    assert elena.age == 38 and elena.stale_member == False       # flew 6 days ago
    assert s.loc[3].stale_member == True                          # 2012 flight
    assert s.loc[4].stale_member == False                         # 20231220 -> 27 days


def test_stale_boundary_is_strictly_greater_than_90():
    base = raw_flat("members_20240115.txt")[0].iloc[[0]].copy()
    for days, expected in [(90, False), (91, True)]:
        base["last_flight_date"] = (AS_OF - dt.timedelta(days=days)).strftime("%Y%m%d")
        assert staging.stage(base, AS_OF).stale_member.iloc[0] == expected


def test_null_flight_date_gives_null_stale_flag():
    base = raw_flat("members_20240115.txt")[0].iloc[[0]].copy()
    base["last_flight_date"] = None
    assert pd.isna(staging.stage(base, AS_OF).stale_member.iloc[0])


def test_country_alias_normalisation_and_warning():
    raw, _ = raw_flat("members_20240115.txt")
    s = staging.stage(raw, AS_OF).set_index("member_id")
    assert s.loc["223459", "country_code"] == "PHL" and s.loc["2256", "country_code"] == "AUS"
    assert "COUNTRY_ALIAS_MAPPED:AU->AUS" in s.loc["2256", "dq_warnings"]


def test_sample_data_issues_are_detected():
    raw, _ = raw_flat("members_20240115.txt")
    s = staging.stage(raw, AS_OF).set_index("member_id")
    assert any(w.startswith("MEMBER_ID_LENGTH_OUTLIER") for w in s.loc["2256", "dq_warnings"])
    assert any(w.startswith("MEMBER_ID_LENGTH_OUTLIER") for w in s.loc["22345", "dq_warnings"])
    assert not any(w.startswith("MEMBER_ID_LENGTH_OUTLIER") for w in s.loc["223457", "dq_warnings"])
    assert "SUSPECT_CONSTANT_COLUMN:dob" in s.loc["223457", "dq_warnings"]


def test_mandatory_and_invalid_dates_are_quarantined_not_dropped():
    raw, rej = raw_flat("members_20240116.txt")
    s = staging.stage(raw, AS_OF)
    bad = s[~s.is_valid].set_index("member_id")
    assert "MISSING_MANDATORY:member_name" in bad.loc["223460", "dq_errors"]
    assert "INVALID_DATE:20151332" in bad.loc["223461", "dq_errors"]
    assert len(s) == len(raw)                                     # nothing silently lost
    assert [r["rule"] for r in rej] == ["BAD_FIELD_COUNT"]        # short row -> parse-level reject


def test_unroutable_country_is_error():
    raw, _ = raw_flat("members_20240115.txt")
    raw.loc[0, "country"] = "ATLANTIS"
    assert "UNROUTABLE_COUNTRY:ATLANTIS" in staging.stage(raw, AS_OF).dq_errors.iloc[0]


def test_length_overflow_is_error():
    raw, _ = raw_flat("members_20240115.txt")
    raw.loc[0, "member_id"] = "1" * 19
    assert "LENGTH_EXCEEDED:member_id>18" in staging.stage(raw, AS_OF).dq_errors.iloc[0]


def test_optional_bad_date_is_nulled_with_warning_and_member_still_loads():
    raw, _ = raw_flat("members_20240115.txt")
    raw.loc[0, "dob"] = "99999999"
    s = staging.stage(raw, AS_OF).iloc[0]
    assert s.is_valid and pd.isna(s.dob) and pd.isna(s.age)
    assert any("INVALID_DATE:dob" in w for w in s.dq_warnings)


def test_reconciliation_flags_dropped_column():
    raw, _ = raw_flat("members_20240115.txt")
    s = staging.stage(raw, AS_OF)
    assert all(r["passed"] for r in staging.reconcile(raw, s))
    s.loc[1:, "agent_name"] = None                                # what the sample staging table did
    failed = [r["check"] for r in staging.reconcile(raw, s) if not r["passed"]]
    assert failed == ["non_null:agent_name"]


# ---------- xlsx sources ----------
def test_xlsx_country_extracts_map_to_canonical_and_avoid_id_collision():
    frames = [readers.read_country_xlsx(f"{S}{c}.xlsx", c, AS_OF)[0] for c in ("AUS", "USA", "IND")]
    raw = pd.concat(frames, ignore_index=True)
    assert len(raw) == 9                                          # blank "used range" rows skipped
    s = staging.stage(raw, AS_OF)
    assert s.member_id.is_unique                                  # 1,2,3 exist in every file
    usa = s[s.country_code == "USA"].set_index("member_id")
    assert usa.loc["USA-2", "enrollment_date"] == dt.date(2022, 1, 5)
    assert usa.loc["USA-1", "last_flight_date"] == dt.date(2022, 8, 20)
    assert list(s[~s.is_valid].member_id) == ["AUS-2"]            # 2021-13-13
    assert s[s.member_id == "AUS-1"].dob.isna().iloc[0]           # literal 'NULL' string -> NULL


# ---------- latest wins / country moves ----------
def _run(files):
    targets = {}
    for f in files:
        raw, _ = raw_flat(f)
        s = staging.stage(raw, AS_OF)
        targets, log = pipeline.merge_into_targets(targets, pipeline.latest_wins(s[s.is_valid]))
    return targets, log


def test_duplicate_in_same_file_last_row_wins():
    raw, _ = raw_flat("members_20240116.txt")
    s = staging.stage(raw, AS_OF)
    latest = pipeline.latest_wins(s[s.is_valid])
    ravi = latest[latest.member_id == "223458"]
    assert len(ravi) == 1 and ravi.iloc[0].tier_code == "PLT"


def test_member_who_moves_country_lives_only_in_new_country():
    targets, log = _run(["members_20240115.txt", "members_20240116.txt"])
    assert "223457" not in set(targets["USA"].member_id) if "USA" in targets else True
    assert "223457" in set(targets["CAN"].member_id)
    assert {"member_id": "223457", "action": "MOVED", "from": "USA", "to": "CAN"} in log
    pipeline.assert_unique_across_targets(targets)


def test_late_arriving_older_file_never_overwrites_newer():
    targets, _ = _run(["members_20240116.txt"])
    old, _ = raw_flat("members_20240115.txt")
    s = staging.stage(old, AS_OF)
    targets2, log = pipeline.merge_into_targets(targets, pipeline.latest_wins(s[s.is_valid]))
    assert "223457" in set(targets2["CAN"].member_id)
    assert "223457" not in set(targets2.get("USA", pd.DataFrame({"member_id": []})).member_id)
    assert any(l["action"] == "SKIPPED_STALE" and l["member_id"] == "223457" for l in log)


def test_merge_is_idempotent():
    t1, _ = _run(["members_20240115.txt", "members_20240116.txt"])
    raw, _ = raw_flat("members_20240116.txt")
    s = staging.stage(raw, AS_OF)
    t2, _ = pipeline.merge_into_targets(t1, pipeline.latest_wins(s[s.is_valid]))
    assert {k: len(v) for k, v in t1.items()} == {k: len(v) for k, v in t2.items()}


# ---------- redemptions ----------
def test_flatten_nested_json_and_reject_bad_rows():
    good, bad = redemptions.flatten(S + "redemptions_20240115.ndjson")
    assert list(good.txn_id) == ["RX10091", "RX10092"]
    assert good.miles_redeemed.tolist() == [12000, 5000]
    assert list(bad.txn_id) == ["RX10093"] and "INVALID_MILES:-50" in bad.reason.iloc[0]


def test_empty_redemptions_array_is_not_an_error():
    good, bad = redemptions.flatten(S + "redemptions_20240115.ndjson")
    assert "223458" not in set(good.member_id) and "223458" not in set(bad.member_id.dropna())


def test_txn_status_update_latest_feed_wins():
    frames = [redemptions.flatten(S + f)[0] for f in ("redemptions_20240115.ndjson", "redemptions_20240116.ndjson")]
    red = redemptions.latest_txn_wins(frames).set_index("txn_id")
    assert len(red) == 2 and red.loc["RX10092", "status"] == "COMPLETED"


def test_join_follows_member_to_new_country_and_reports_orphans():
    targets, _ = _run(["members_20240115.txt", "members_20240116.txt"])
    frames = [redemptions.flatten(S + f)[0] for f in ("redemptions_20240115.ndjson", "redemptions_20240116.ndjson")]
    red = redemptions.latest_txn_wins(frames)
    joined, orphans = redemptions.join_members(red, targets)
    assert set(joined.country_code) == {"CAN"} and orphans.empty
    ghost = red.iloc[[0]].assign(member_id="000000")
    _, orphans = redemptions.join_members(ghost, targets)
    assert len(orphans) == 1


def test_malformed_json_line_is_rejected_not_fatal(tmp_path):
    p = tmp_path / "r_20240101.ndjson"
    p.write_text('{"member_id":"1","feed_date":"20240101","redemptions":[]}\n{oops\n')
    good, bad = redemptions.flatten(str(p))
    assert len(good) == 0 and bad.reason.iloc[0].startswith("INVALID_JSON")

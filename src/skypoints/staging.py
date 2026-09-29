"""RAW -> STG: typing, normalisation, derived columns and row-level validation.

Python mirror of sql/02_staging_load.sql. Policy:
  * mandatory field missing/invalid, unroutable country, length overflow, future dates -> ERROR (quarantine)
  * bad value in an OPTIONAL field -> value nulled + WARN (member still loads)
"""
from __future__ import annotations

import datetime as dt
from collections import Counter

import pandas as pd

from . import config
from .dates import age_in_years, clean, parse_date

STG_COLS = ["member_id", "member_name", "enrollment_date", "last_flight_date", "tier_code",
            "agent_name", "state", "country_code", "country_raw", "post_code", "dob", "is_active",
            "member_type", "age", "stale_member", "source_system", "source_file", "source_file_row",
            "feed_date", "run_date", "dq_errors", "dq_warnings", "is_valid"]


def _stage_row(r: dict, as_of: dt.date) -> dict:
    errs, warns = [], []
    hints = r.get("_hints") or {}
    o = {c: clean(r.get(c)) for c in ("member_id", "member_name", "tier_code", "agent_name", "state",
                                       "post_code", "is_active", "member_type")}
    o["country_raw"] = clean(r.get("country"))
    for c in ("member_id", "member_name", "tier_code", "state", "is_active"):
        if o[c] and c != "member_name":
            o[c] = o[c].upper() if c in ("tier_code", "state", "is_active") else o[c]

    # mandatory fields
    for c in ("member_id", "member_name"):
        if not o[c]:
            errs.append(f"MISSING_MANDATORY:{c}")
    enr, e = parse_date(r.get("enrollment_date"), hints.get("enrollment_date", "YMD"))
    if enr is None:
        errs.append(e or "MISSING_MANDATORY:enrollment_date")
    # optional dates: null + warn on junk
    flight, e = parse_date(r.get("last_flight_date"), hints.get("last_flight_date", "YMD"))
    if e:
        warns.append(e.replace("INVALID_DATE", "INVALID_DATE:last_flight_date"))
    dob, e = parse_date(r.get("dob"), hints.get("dob", "DMY"))
    if e:
        warns.append(e.replace("INVALID_DATE", "INVALID_DATE:dob"))
    o.update(enrollment_date=enr, last_flight_date=flight, dob=dob)

    # country routing
    raw_c = (o["country_raw"] or "").upper()
    o["country_code"] = config.COUNTRY_ALIASES.get(raw_c)
    if not raw_c:
        errs.append("UNROUTABLE_COUNTRY:missing")
    elif o["country_code"] is None:
        errs.append(f"UNROUTABLE_COUNTRY:{raw_c}")
    elif raw_c != o["country_code"]:
        warns.append(f"COUNTRY_ALIAS_MAPPED:{raw_c}->{o['country_code']}")

    # lengths (DDL would truncate/fail)
    for c, n in config.MAX_LEN.items():
        if o.get(c) and len(o[c]) > n:
            errs.append(f"LENGTH_EXCEEDED:{c}>{n}")

    # domain checks
    if o["tier_code"] and o["tier_code"] not in config.KNOWN_TIERS:
        warns.append(f"UNKNOWN_TIER:{o['tier_code']}")
    if o["is_active"] and o["is_active"] not in config.VALID_ACTIVE:
        warns.append(f"UNKNOWN_ACTIVE_FLAG:{o['is_active']}")
    if o["post_code"] and not o["post_code"].isdigit():
        warns.append(f"NON_NUMERIC_POST_CODE:{o['post_code']}")

    # cross-field / temporal checks
    if enr and enr > as_of:
        errs.append("ENROLLMENT_IN_FUTURE")
    if dob and dob > as_of:
        errs.append("DOB_IN_FUTURE")
    if flight and enr and flight < enr:
        warns.append("FLIGHT_BEFORE_ENROLLMENT")
    if flight and flight > as_of:
        warns.append("FLIGHT_IN_FUTURE")
    if dob and enr and dob >= enr:
        warns.append("DOB_NOT_BEFORE_ENROLLMENT")

    # derived columns
    o["age"] = age_in_years(dob, as_of) if dob and dob <= as_of else None
    if o["age"] is not None and o["age"] > 120:
        warns.append("AGE_OVER_120")
    o["stale_member"] = ((as_of - flight).days > config.STALE_DAYS) if flight else None

    o.update(source_system=r["source_system"], source_file=r["source_file"],
             source_file_row=r["source_file_row"], feed_date=r["feed_date"], run_date=as_of)
    return o, errs, warns


def stage(raw: pd.DataFrame, as_of: dt.date) -> pd.DataFrame:
    """Type, derive and validate. Returns one row per input row with dq_errors / dq_warnings."""
    recs = []
    for r in raw.to_dict("records"):
        o, errs, warns = _stage_row(r, as_of)
        o["dq_errors"], o["dq_warnings"] = errs, warns
        recs.append(o)
    df = pd.DataFrame(recs, columns=STG_COLS)
    if df.empty:
        return df
    df = _batch_checks(df)
    df["is_valid"] = df["dq_errors"].map(len) == 0
    return df


def _batch_checks(df: pd.DataFrame) -> pd.DataFrame:
    """Checks that need to look at the whole batch (per source file)."""
    for _, idx in df.groupby("source_file").groups.items():
        sub = df.loc[idx]
        # ID-length outliers vs. the dominant length (sample: 6,6,6,5,4)
        lens = sub["member_id"].dropna().map(len)
        if len(lens) >= 3:
            mode, cnt = Counter(lens).most_common(1)[0]
            if cnt / len(lens) >= 0.5:
                for i in sub.index[sub["member_id"].notna() & (sub["member_id"].map(lambda x: len(x) if x else mode) != mode)]:
                    df.at[i, "dq_warnings"] = df.at[i, "dq_warnings"] + [f"MEMBER_ID_LENGTH_OUTLIER:{len(df.at[i,'member_id'])}vs{mode}"]
        # identical values everywhere = placeholder / defaulted column
        if len(sub) >= 3:
            for c in ("dob", "enrollment_date", "last_flight_date"):
                vals = sub[c].dropna()
                if len(vals) >= 3 and vals.nunique() == 1:
                    for i in sub.index:
                        df.at[i, "dq_warnings"] = df.at[i, "dq_warnings"] + [f"SUSPECT_CONSTANT_COLUMN:{c}"]
        # duplicate key inside one file (resolved later by latest-wins, but reported)
        dup = sub[sub["member_id"].notna() & sub.duplicated("member_id", keep=False)]
        for i in dup.index:
            df.at[i, "dq_warnings"] = df.at[i, "dq_warnings"] + ["DUPLICATE_KEY_IN_FILE"]
    return df


def reconcile(raw: pd.DataFrame, staged: pd.DataFrame) -> list[dict]:
    """Source-vs-staging reconciliation: catches a load that silently drops a column
    (the sample staging table lost Agent_Name for 4 of 5 rows)."""
    out = [{"check": "row_count", "raw": len(raw), "staged": len(staged), "passed": len(raw) == len(staged)}]
    for c in ("member_name", "enrollment_date", "last_flight_date", "tier_code", "agent_name", "state", "dob"):
        rc = int(raw[c].map(lambda v: clean(v) is not None).sum())
        sc = int(staged[c].notna().sum())
        # sc < rc is fine only if those values were invalid (they carry a warning/error)
        lost = rc - sc
        explained = int(staged["dq_warnings"].map(lambda w: any(x.startswith("INVALID_DATE") for x in w)).sum() +
                        staged["dq_errors"].map(lambda w: any(x.startswith("INVALID_DATE") for x in w)).sum()) if c.endswith("date") or c == "dob" else 0
        out.append({"check": f"non_null:{c}", "raw": rc, "staged": sc, "passed": lost <= explained})
    return out

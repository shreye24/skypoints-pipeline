"""Flatten the nested JSON redemption feed and join it to member profiles.

Python mirror of sql/04_redemptions.sql.
"""
from __future__ import annotations

import datetime as dt
import os

import pandas as pd

from . import config
from .dates import clean, parse_date
from .readers import read_redemption_docs

COLS = ["txn_id", "member_id", "txn_date", "partner", "miles_redeemed", "status", "feed_date", "source_file"]


def flatten(path: str):
    """One output row per redemption. Returns (good, rejected) DataFrames.

    A member document with an empty `redemptions` array yields no rows (and is not an error).
    """
    good, bad = [], []
    fname = os.path.basename(path)

    def rej(txn, mid, fd, reason, payload):
        bad.append({"txn_id": txn, "member_id": mid, "feed_date": fd, "reason": reason,
                    "payload": payload, "source_file": fname})

    for n, doc, err in read_redemption_docs(path):
        if err:
            rej(None, None, None, err, f"line {n}")
            continue
        mid = clean(doc.get("member_id"))
        fd, e = parse_date(doc.get("feed_date"), "YMD")
        if not mid:
            rej(None, None, fd, "MISSING_MANDATORY:member_id", str(doc)); continue
        if fd is None:
            rej(None, mid, None, e or "MISSING_MANDATORY:feed_date", str(doc)); continue
        items = doc.get("redemptions")
        if items is None or not isinstance(items, list):
            rej(None, mid, fd, "REDEMPTIONS_NOT_AN_ARRAY", str(doc)); continue
        for t in items:
            txn = clean(t.get("txn_id"))
            reasons = []
            if not txn:
                reasons.append("MISSING_MANDATORY:txn_id")
            td, e = parse_date(t.get("txn_date"), "YMD")
            if td is None:
                reasons.append(e or "MISSING_MANDATORY:txn_date")
            elif td > fd:
                reasons.append("TXN_DATE_AFTER_FEED_DATE")
            miles = t.get("miles_redeemed")
            if not isinstance(miles, (int, float)) or isinstance(miles, bool) or miles <= 0 or miles != int(miles):
                reasons.append(f"INVALID_MILES:{miles}")
            status = (clean(t.get("status")) or "").upper()
            if status not in config.VALID_REDEMPTION_STATUS:
                reasons.append(f"INVALID_STATUS:{status or 'missing'}")
            if reasons:
                rej(txn, mid, fd, ";".join(reasons), str(t))
                continue
            good.append({"txn_id": txn, "member_id": mid, "txn_date": td, "partner": clean(t.get("partner")),
                         "miles_redeemed": int(miles), "status": status, "feed_date": fd, "source_file": fname})
    return (pd.DataFrame(good, columns=COLS),
            pd.DataFrame(bad, columns=["txn_id", "member_id", "feed_date", "reason", "payload", "source_file"]))


def latest_txn_wins(frames: list[pd.DataFrame]) -> pd.DataFrame:
    """A txn re-appears in later feeds as its status changes (PENDING -> COMPLETED): newest feed wins."""
    df = pd.concat([f for f in frames if len(f)], ignore_index=True) if frames else pd.DataFrame(columns=COLS)
    if df.empty:
        return df
    return df.sort_values(["txn_id", "feed_date"]).drop_duplicates("txn_id", keep="last").reset_index(drop=True)


def join_members(red: pd.DataFrame, targets: dict[str, pd.DataFrame]):
    """Join redemptions to whichever country table holds the member.

    Returns (joined, orphans). Orphans = redemptions whose member is unknown (not loaded, quarantined,
    or arriving before the profile) - kept, reported, and re-joined on the next run rather than dropped.
    """
    members = pd.concat([t[["member_id", "member_name", "country_code", "tier_code"]] for t in targets.values()],
                        ignore_index=True) if targets else pd.DataFrame(columns=["member_id"])
    joined = red.merge(members, on="member_id", how="left", indicator=True)
    orphans = joined[joined["_merge"] == "left_only"].drop(columns="_merge")
    return joined.drop(columns="_merge"), orphans

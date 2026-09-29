"""Latest-record-wins dedupe, per-country split and country-move handling.

Python mirror of sql/03_country_split.sql, used for local runs and as an executable spec in tests.
"""
from __future__ import annotations

import pandas as pd

from . import config

TARGET_COLS = ["member_id", "member_name", "enrollment_date", "last_flight_date", "tier_code", "agent_name",
               "state", "country_code", "post_code", "dob", "is_active", "member_type", "age", "stale_member",
               "feed_date", "source_file"]


def latest_wins(staged_valid: pd.DataFrame) -> pd.DataFrame:
    """One row per member_id: newest feed_date wins; ties broken by later source file row.

    (SQL: QUALIFY ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY feed_date DESC, source_file DESC,
    source_file_row DESC) = 1)
    """
    if staged_valid.empty:
        return staged_valid
    ordered = staged_valid.sort_values(["member_id", "feed_date", "source_file", "source_file_row"])
    return ordered.drop_duplicates("member_id", keep="last")


def merge_into_targets(targets: dict[str, pd.DataFrame], batch: pd.DataFrame):
    """Apply a de-duplicated batch to the country tables.

    * new member            -> insert into its country table
    * existing, same country -> update, but only if the batch is not older than what we hold
    * existing, new country  -> delete from old country table, insert into new one (a "move")
    * older than what we hold (late-arriving file) -> skipped, never overwrites newer data
    Returns (new_targets, log) where log lists every non-trivial action.
    """
    targets = {k: v.copy() for k, v in targets.items()}
    routing = {}
    for cc, t in targets.items():
        for mid, fd in zip(t["member_id"], t["feed_date"]):
            routing[mid] = (cc, fd)
    log, inserts = [], {}
    for r in batch.to_dict("records"):
        mid, cc, fd = r["member_id"], r["country_code"], r["feed_date"]
        if mid in routing:
            old_cc, old_fd = routing[mid]
            if fd < old_fd:
                log.append({"member_id": mid, "action": "SKIPPED_STALE", "from": old_cc, "to": cc})
                continue
            if old_cc != cc:
                log.append({"member_id": mid, "action": "MOVED", "from": old_cc, "to": cc})
            t = targets[old_cc]
            targets[old_cc] = t[t["member_id"] != mid]
        inserts.setdefault(cc, []).append({c: r[c] for c in TARGET_COLS})
        routing[mid] = (cc, fd)
    for cc, rows in inserts.items():
        new = pd.DataFrame(rows, columns=TARGET_COLS)
        base = targets.get(cc, pd.DataFrame(columns=TARGET_COLS))
        targets[cc] = pd.concat([base, new], ignore_index=True) if len(base) else new
    return targets, log


def assert_unique_across_targets(targets: dict[str, pd.DataFrame]) -> None:
    """Invariant: a member lives in exactly one country table."""
    ids = pd.concat([t["member_id"] for t in targets.values()]) if targets else pd.Series(dtype=str)
    dups = ids[ids.duplicated()].unique().tolist()
    if dups:
        raise AssertionError(f"member_id present in more than one country table: {dups[:10]}")

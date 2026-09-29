"""Local runner:  python -m skypoints.cli --members f1 f2 --xlsx AUS=path ... --redemptions r1 r2 --as-of 2024-01-16"""
from __future__ import annotations

import argparse
import datetime as dt
import os

import pandas as pd

from . import config, pipeline, readers, redemptions, staging


def run(members, xlsx, reds, as_of, out):
    os.makedirs(out, exist_ok=True)
    raws, parse_issues = [], []
    for p in sorted(members, key=readers.feed_date_from_name):        # oldest feed first
        df, rej = readers.read_flat_file(p)
        raws.append(df); parse_issues += rej
    for spec in xlsx:
        cc, p = spec.split("=", 1)
        df, rej = readers.read_country_xlsx(p, cc, as_of)
        raws.append(df); parse_issues += rej
    raw = pd.concat([r for r in raws if len(r)], ignore_index=True)
    stg = staging.stage(raw, as_of)
    recon = staging.reconcile(raw, stg)

    valid = stg[stg["is_valid"]]
    targets, log = pipeline.merge_into_targets({}, pipeline.latest_wins(valid))
    pipeline.assert_unique_across_targets(targets)

    quarantine = stg[~stg["is_valid"]]
    stg.assign(dq_errors=stg.dq_errors.map("; ".join), dq_warnings=stg.dq_warnings.map("; ".join)) \
        .to_csv(f"{out}/stg_member.csv", index=False)
    quarantine.assign(dq_errors=quarantine.dq_errors.map("; ".join), dq_warnings=quarantine.dq_warnings.map("; ".join)) \
        .to_csv(f"{out}/member_quarantine.csv", index=False)
    pd.DataFrame(parse_issues).to_csv(f"{out}/parse_rejects.csv", index=False)
    for cc, t in targets.items():
        t.to_csv(f"{out}/{config.COUNTRY_TABLES.get(cc, 'TABLE_' + cc)}.csv", index=False)

    good, bad = [], []
    for p in sorted(reds, key=readers.feed_date_from_name):
        g, b = redemptions.flatten(p); good.append(g); bad.append(b)
    if reds:
        red = redemptions.latest_txn_wins(good)
        joined, orphans = redemptions.join_members(red, targets)
        joined.to_csv(f"{out}/redemption_joined.csv", index=False)
        orphans.to_csv(f"{out}/redemption_orphans.csv", index=False)
        pd.concat(bad).to_csv(f"{out}/redemption_rejects.csv", index=False)

    print(f"raw rows={len(raw)}  valid={len(valid)}  quarantined={len(quarantine)}  parse-rejects={len(parse_issues)}")
    for cc, t in sorted(targets.items()):
        print(f"  {config.COUNTRY_TABLES.get(cc, cc):18s} {len(t)} rows")
    for l in log:
        print("  move/skip:", l)
    for r in recon:
        if not r["passed"]:
            print("  RECONCILIATION FAILED:", r)
    return targets, stg


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--members", nargs="*", default=[])
    ap.add_argument("--xlsx", nargs="*", default=[], help="COUNTRY=path.xlsx")
    ap.add_argument("--redemptions", nargs="*", default=[])
    ap.add_argument("--as-of", default=dt.date.today().isoformat())
    ap.add_argument("--out", default="out")
    a = ap.parse_args()
    run(a.members, a.xlsx, a.redemptions, dt.date.fromisoformat(a.as_of), a.out)

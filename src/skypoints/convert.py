"""Convert a country Excel extract into the canonical pipe-delimited flat file.

Gives the Excel sources the same path as everything else (stage -> COPY -> staging), so Snowflake
needs one loader, not one per country layout. Dates that parse are normalised (enrollment/flight
YYYYMMDD, DOB DDMMYYYY); values that do NOT parse are written through unchanged so staging
quarantines them instead of the converter silently "fixing" or dropping them.

    python -m skypoints.convert AUS=data/sample/AUS.xlsx USA=... IND=... --feed-date 2024-01-16 --out data/sample/converted
"""
from __future__ import annotations

import argparse
import datetime as dt
import os

from . import readers
from .dates import clean, parse_date

HEADER = ["Member_Name", "Member_Id", "Enrollment_Date", "Last_Flight_Date", "Tier_Code", "Agent_Name",
          "State", "Country", "DOB", "Is_Active", "Member_Type"]


def _date(value, hint, out_fmt):
    d, err = parse_date(value, hint)
    if d:
        return d.strftime(out_fmt)
    return (clean(value) or "") if err else ""


def _txt(v):
    return (clean(v) or "").replace("|", "/")


def xlsx_to_flat(path: str, country: str, feed_date: dt.date, out_dir: str) -> str:
    raw, _ = readers.read_country_xlsx(path, country, feed_date)
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"members_{country}_{feed_date:%Y%m%d}.txt")
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("|H|" + "|".join(HEADER) + "\n")
        for r in raw.to_dict("records"):
            h = r["_hints"] or {}
            fields = [_txt(r["member_name"]), _txt(r["member_id"]),
                      _date(r["enrollment_date"], h.get("enrollment_date", "YMD"), "%Y%m%d"),
                      _date(r["last_flight_date"], h.get("last_flight_date", "YMD"), "%Y%m%d"),
                      _txt(r["tier_code"]), _txt(r["agent_name"]), _txt(r["state"]), country,
                      _date(r["dob"], h.get("dob", "DMY"), "%d%m%Y"), _txt(r["is_active"]), _txt(r["member_type"])]
            fh.write("|D|" + "|".join(fields) + "\n")
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("sources", nargs="+", help="COUNTRY=path.xlsx")
    ap.add_argument("--feed-date", required=True)
    ap.add_argument("--out", default="converted")
    a = ap.parse_args()
    for spec in a.sources:
        cc, p = spec.split("=", 1)
        print(xlsx_to_flat(p, cc, dt.date.fromisoformat(a.feed_date), a.out))

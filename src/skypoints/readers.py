"""Readers that turn each source into one canonical raw (string) DataFrame + parse-level rejects."""
from __future__ import annotations

import datetime as dt
import json
import os
import re
from typing import Iterable

import openpyxl
import pandas as pd

from . import config

RAW_COLS = ["member_id", "member_name", "enrollment_date", "last_flight_date", "tier_code",
            "agent_name", "state", "country", "post_code", "dob", "is_active", "member_type"]
LINEAGE = ["source_system", "source_file", "source_file_row", "feed_date"]


def feed_date_from_name(path: str) -> dt.date:
    m = re.search(r"(\d{8})", os.path.basename(path))
    if not m:
        raise ValueError(f"cannot find YYYYMMDD in file name {path!r}")
    return dt.datetime.strptime(m.group(1), "%Y%m%d").date()


def _reject(path, row, rule, detail, raw=""):
    return {"source_file": os.path.basename(path), "source_file_row": row, "rule": rule,
            "severity": "ERROR", "detail": detail, "raw": raw}


def read_flat_file(path: str, feed_date: dt.date | None = None):
    """Header-driven parser for |H|...| / |D|...| files.

    Column order comes from the H record, not from hard-coded positions, because the design
    doc (11 columns incl. Post Code) and the sample file (10 columns) disagree.
    """
    feed_date = feed_date or feed_date_from_name(path)
    header, rows, rejects = None, [], []
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, start=1):
            line = line.rstrip("\r\n")
            if not line.strip():
                continue
            parts = line.split("|")
            rec, fields = (parts[1] if len(parts) > 1 else ""), parts[2:]
            if rec == "H":
                header = [config.FLAT_HEADER_MAP.get(h.strip().lower()) for h in fields]
                unknown = [h for h, m in zip(fields, header) if m is None]
                if unknown:
                    rejects.append({**_reject(path, n, "UNKNOWN_HEADER_COLUMN", ",".join(unknown), line),
                                    "severity": "WARN"})
                continue
            if rec != "D":
                rejects.append(_reject(path, n, "BAD_RECORD_TYPE", f"type={rec!r}", line))
                continue
            if header is None:
                rejects.append(_reject(path, n, "DETAIL_BEFORE_HEADER", "no H record seen", line))
                continue
            if len(fields) == len(header) + 1 and fields[-1] == "":  # trailing pipe
                fields = fields[:-1]
            if len(fields) != len(header):
                rejects.append(_reject(path, n, "BAD_FIELD_COUNT",
                                       f"expected {len(header)} fields, got {len(fields)}", line))
                continue
            rec_dict = {c: None for c in RAW_COLS}
            for col, val in zip(header, fields):
                if col:
                    rec_dict[col] = val
            rows.append({**rec_dict, "source_system": "FLAT", "source_file": os.path.basename(path),
                         "source_file_row": n, "feed_date": feed_date,
                         "_hints": config.FLAT_DATE_HINTS})
    return pd.DataFrame(rows, columns=RAW_COLS + LINEAGE + ["_hints"]), rejects


def read_country_xlsx(path: str, country: str, feed_date: dt.date, id_prefix: bool = True):
    """Country-specific Excel extract. Each country has its own headers and date format.

    IDs in these files are per-country sequences (1,2,3 in every file), so they are prefixed
    with the country to avoid colliding on member_id (e.g. 'AUS-1').
    """
    prof = config.XLSX_PROFILES[country]
    ws = openpyxl.load_workbook(path, data_only=True).active
    it = ws.iter_rows(values_only=True)
    headers = [str(h).strip() if h is not None else None for h in next(it)]
    unmapped = [h for h in headers if h and h not in prof["columns"]]
    rows, rejects = [], []
    if unmapped:
        rejects.append({**_reject(path, 1, "UNMAPPED_COLUMN", ",".join(unmapped)), "severity": "WARN"})
    for n, vals in enumerate(it, start=2):
        if all(v is None for v in vals):      # Excel "used range" often includes blank rows
            continue
        rec = {c: None for c in RAW_COLS}
        for h, v in zip(headers, vals):
            col = prof["columns"].get(h)
            if col:
                rec[col] = v
        if id_prefix and rec["member_id"] is not None:
            rec["member_id"] = f"{country}-{str(rec['member_id']).strip()}"
        rec["country"] = country               # not in the file: implied by which extract it is
        rows.append({**rec, "source_system": f"{country}_XLSX", "source_file": os.path.basename(path),
                     "source_file_row": n, "feed_date": feed_date, "_hints": prof["date_hints"]})
    return pd.DataFrame(rows, columns=RAW_COLS + LINEAGE + ["_hints"]), rejects


def read_redemption_docs(path: str) -> Iterable[tuple[int, dict | None, str | None]]:
    """Yield (line_no, doc, error). Accepts NDJSON (preferred) or a single JSON object/array."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    stripped = text.lstrip()
    if stripped.startswith("["):
        try:
            for i, d in enumerate(json.loads(text), start=1):
                yield i, d, None
        except json.JSONDecodeError as e:
            yield 1, None, f"INVALID_JSON:{e}"
        return
    for n, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            yield n, json.loads(line), None
        except json.JSONDecodeError as e:
            yield n, None, f"INVALID_JSON:{e.msg}"

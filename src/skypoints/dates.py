"""Tolerant date parsing. Returns (value, error) - never raises, so one bad cell can't kill a batch."""
from __future__ import annotations

import datetime as dt
import re

NULL_TOKENS = {"", "NULL", "NONE", "NAN", "N/A", "NA"}
_FMT = {"YMD": "%Y%m%d", "DMY": "%d%m%Y", "MDY": "%m%d%Y"}


def clean(value):
    """Trim and turn null-ish tokens into None. Ints/floats from Excel become str."""
    if value is None:
        return None
    if isinstance(value, float) and value != value:  # NaN
        return None
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    s = str(value).strip()
    return None if s.upper() in NULL_TOKENS else s


def parse_date(value, hint: str = "YMD"):
    """Parse a date.

    Compact numeric forms (DDMMYYYY / MMDDYYYY) are left-padded to 8 digits because
    Excel / int casts drop the leading zero (3051985 -> 03051985). That makes 7-digit
    values unambiguous *provided the source is a zero-padded fixed-width field*.
    """
    if isinstance(value, dt.datetime):
        return value.date(), None
    if isinstance(value, dt.date):
        return value, None
    s = clean(value)
    if s is None:
        return None, None
    try:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}([ T].*)?", s):
            return dt.datetime.strptime(s[:10], "%Y-%m-%d").date(), None
        if re.fullmatch(r"\d{7,8}", s):
            if hint == "YMD" and len(s) != 8:
                raise ValueError("YMD needs 8 digits")
            return dt.datetime.strptime(s.zfill(8), _FMT[hint]).date(), None
    except ValueError:
        pass
    return None, f"INVALID_DATE:{s}"


def age_in_years(dob: dt.date, as_of: dt.date) -> int:
    return as_of.year - dob.year - ((as_of.month, as_of.day) < (dob.month, dob.day))

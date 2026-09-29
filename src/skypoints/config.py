"""Reference data and per-source parsing profiles. Mirrors OPS.REF_* tables in sql/01_ddl.sql."""
from __future__ import annotations

COUNTRY_ALIASES = {
    "IND": "IND", "IN": "IND", "USA": "USA", "US": "USA",
    "AUS": "AUS", "AU": "AUS", "CAN": "CAN", "PHL": "PHL", "PHIL": "PHL", "PH": "PHL",
}
COUNTRY_TABLES = {
    "IND": "TABLE_INDIA", "USA": "TABLE_USA", "AUS": "TABLE_AUSTRALIA",
    "CAN": "TABLE_CANADA", "PHL": "TABLE_PHILIPPINES",
}
KNOWN_TIERS = {"GLD", "SLV", "PLT"}
VALID_ACTIVE = {"A", "I"}
VALID_REDEMPTION_STATUS = {"COMPLETED", "PENDING", "CANCELLED", "REVERSED"}
STALE_DAYS = 90

# max lengths from the design-document column spec
MAX_LEN = {
    "member_name": 255, "member_id": 18, "tier_code": 5, "agent_name": 255,
    "state": 5, "post_code": 5, "is_active": 1,
}

# Flat-file header names -> canonical columns
FLAT_HEADER_MAP = {
    "member_name": "member_name", "member_id": "member_id",
    "enrollment_date": "enrollment_date", "last_flight_date": "last_flight_date",
    "tier_code": "tier_code", "agent_name": "agent_name", "state": "state",
    "country": "country", "post_code": "post_code", "dob": "dob", "is_active": "is_active",
}

# Date-format hints per canonical column, per source. Compact numeric dates only
# (ISO strings / real Excel dates are self-describing and ignore the hint).
FLAT_DATE_HINTS = {"enrollment_date": "YMD", "last_flight_date": "YMD", "dob": "DMY"}
USA_XLSX_DATE_HINTS = {"enrollment_date": "MDY", "last_flight_date": "MDY", "dob": "MDY"}

# Per-country Excel extracts: different header names and columns in each file.
XLSX_PROFILES = {
    "AUS": {
        "columns": {"Unique ID": "member_id", "Member Name": "member_name", "Tier Type": "tier_code",
                    "Date of Birth": "dob", "Date of Enrollment": "enrollment_date",
                    "Date of Flight": "last_flight_date"},
        "date_hints": {},
    },
    "USA": {
        "columns": {"ID": "member_id", "Name": "member_name", "TierCode": "tier_code",
                    "EnrollmentDate": "enrollment_date", "FlightDate": "last_flight_date"},
        "date_hints": USA_XLSX_DATE_HINTS,
    },
    "IND": {
        "columns": {"ID": "member_id", "Name": "member_name", "DOB": "dob", "TierCode": "tier_code",
                    "EnrollmentDate": "enrollment_date", "Individual or Corporate": "member_type",
                    "Flight Date": "last_flight_date"},
        "date_hints": {},
    },
}

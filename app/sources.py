"""Reads completed appointments from Supabase (REST) so the model can
(a) rebuild itself after a restart and (b) catch any webhook that was missed.

Needs the *service-role* key, which bypasses Row Level Security. It lives only in
the Render environment and is never shipped in the app.
"""
from __future__ import annotations

import logging
from datetime import date, datetime, timezone
from typing import Optional

import httpx

log = logging.getLogger("ml.sources")

# Reject durations that are almost certainly data-entry slips (e.g. the doctor forgot
# to press "End" and it was closed hours later). One 600-minute row would poison the fit.
MIN_VALID_MINUTES = 2.0
MAX_VALID_MINUTES = 90.0


def parse_ts(value: str) -> datetime:
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def duration_minutes(start: str, end: str) -> Optional[float]:
    """Minutes between two timestamps, or None if not a plausible consultation."""
    try:
        mins = (parse_ts(end) - parse_ts(start)).total_seconds() / 60.0
    except (ValueError, TypeError, AttributeError):
        return None
    return round(mins, 2) if MIN_VALID_MINUTES <= mins <= MAX_VALID_MINUTES else None


def age_on(dob: Optional[str], when: str) -> Optional[int]:
    if not dob:
        return None
    try:
        born = date.fromisoformat(dob[:10])
        d = parse_ts(when).date()
    except (ValueError, TypeError):
        return None
    age = d.year - born.year - ((d.month, d.day) < (born.month, born.day))
    return age if 0 <= age <= 120 else None


class SupabaseSource:
    def __init__(self, url: str, service_key: str):
        self.base = url.rstrip("/") + "/rest/v1"
        self.headers = {"apikey": service_key, "Authorization": f"Bearer {service_key}"}

    async def fetch_completed(self, since_iso: Optional[str] = None, page: int = 1000) -> list[dict]:
        """All Completed appointments with a start+end time (optionally ended since `since_iso`)."""
        params = {
            "select": "id,initial_symptom,queue_serial,consultation_start,consultation_end,patients(date_of_birth)",
            "status": "eq.Completed",
            "consultation_start": "not.is.null",
            "consultation_end": "not.is.null",
            "order": "consultation_end.asc",
        }
        if since_iso:
            params["consultation_end"] = f"gte.{since_iso}"
        rows: list[dict] = []
        async with httpx.AsyncClient(timeout=30) as client:
            offset = 0
            while True:
                hdr = {**self.headers, "Range-Unit": "items", "Range": f"{offset}-{offset + page - 1}"}
                r = await client.get(f"{self.base}/appointments", params=params, headers=hdr)
                r.raise_for_status()
                chunk = r.json()
                rows.extend(chunk)
                if len(chunk) < page:
                    break
                offset += page
        log.info("fetched %d completed appointments from Supabase", len(rows))
        return rows

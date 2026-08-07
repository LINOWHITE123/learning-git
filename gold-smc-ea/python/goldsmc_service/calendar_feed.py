"""Economic calendar ingestion.

The weekly JSON published by the free ForexFactory mirror is used by default.
Events are written to a CSV the EA can read directly (so the strategy tester,
which has no access to the terminal calendar, still respects blackouts).
"""

from __future__ import annotations

import csv
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests

from .config import Settings

log = logging.getLogger(__name__)

IMPACT_MAP = {"high": 3, "medium": 2, "moderate": 2, "low": 1, "holiday": 0, "non-economic": 0}


@dataclass
class CalendarEvent:
    time: datetime
    currency: str
    title: str
    impact: int

    def csv_row(self) -> list[str]:
        return [
            self.time.strftime("%Y.%m.%d %H:%M"),
            self.currency,
            str(self.impact),
            self.title.replace(",", " "),
        ]


class CalendarFeed:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._session = requests.Session()
        self._session.headers.update({"User-Agent": settings.user_agent})
        self._events: list[CalendarEvent] = []
        self._fetched_at: datetime | None = None

    @property
    def events(self) -> list[CalendarEvent]:
        return list(self._events)

    def refresh(self) -> list[CalendarEvent]:
        try:
            response = self._session.get(
                self._settings.calendar_url, timeout=self._settings.request_timeout
            )
            response.raise_for_status()
            payload = response.json()
        except (requests.RequestException, ValueError) as exc:
            log.warning("calendar unavailable: %s", exc)
            return self._events

        events: list[CalendarEvent] = []
        for row in payload:
            currency = str(row.get("country") or row.get("currency") or "").upper()
            if self._settings.calendar_currencies and currency not in self._settings.calendar_currencies:
                continue
            impact = IMPACT_MAP.get(str(row.get("impact", "")).lower(), 0)
            if impact == 0:
                continue
            stamp = row.get("date")
            if not stamp:
                continue
            try:
                when = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
            except ValueError:
                log.debug("unparsable calendar timestamp: %s", stamp)
                continue
            if when.tzinfo is None:
                when = when.replace(tzinfo=timezone.utc)
            events.append(
                CalendarEvent(
                    time=when.astimezone(timezone.utc),
                    currency=currency,
                    title=str(row.get("title", "")),
                    impact=impact,
                )
            )

        events.sort(key=lambda e: e.time)
        self._events = events
        self._fetched_at = datetime.now(timezone.utc)
        log.info("calendar refreshed: %d events", len(events))
        return events

    def in_blackout(self, now: datetime | None = None, min_impact: int = 3) -> tuple[bool, str]:
        now = now or datetime.now(timezone.utc)
        window = timedelta(minutes=self._settings.news_blackout_minutes)
        for event in self._events:
            if event.impact < min_impact:
                continue
            if event.time - window <= now <= event.time + window:
                return True, f"{event.currency} {event.title} at {event.time:%Y-%m-%d %H:%M} UTC"
        return False, ""

    def next_event(self, now: datetime | None = None, min_impact: int = 3) -> CalendarEvent | None:
        now = now or datetime.now(timezone.utc)
        upcoming = [e for e in self._events if e.time > now and e.impact >= min_impact]
        return upcoming[0] if upcoming else None

    def write_csv(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", newline="", encoding="ascii", errors="replace") as handle:
            writer = csv.writer(handle)
            writer.writerow(["time", "currency", "importance", "name"])
            for event in self._events:
                writer.writerow(event.csv_row())
        log.info("wrote %d calendar rows to %s", len(self._events), path)

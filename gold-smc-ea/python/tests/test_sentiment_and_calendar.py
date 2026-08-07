from __future__ import annotations

from datetime import datetime, timedelta, timezone

from goldsmc_service.calendar_feed import CalendarEvent, CalendarFeed
from goldsmc_service.config import Settings
from goldsmc_service.sentiment import SentimentEngine


def test_gold_lexicon_flips_headline_polarity():
    engine = SentimentEngine(Settings())
    hawkish = engine._score_headline("Fed signals another rate hike as dollar strengthens")
    dovish = engine._score_headline("Fed hints at a rate cut, safe haven demand lifts bullion")
    assert hawkish < 0.0
    assert dovish > 0.0
    assert dovish > hawkish


def test_relevance_filter_drops_unrelated_headlines():
    engine = SentimentEngine(Settings())
    assert engine._is_relevant("Gold climbs as inflation data cools")
    assert not engine._is_relevant("Local team wins the championship")


def test_calendar_blackout_window():
    settings = Settings()
    settings.news_blackout_minutes = 30
    feed = CalendarFeed(settings)

    now = datetime(2025, 3, 12, 12, 30, tzinfo=timezone.utc)
    feed._events = [
        CalendarEvent(time=now + timedelta(minutes=10), currency="USD", title="CPI m/m", impact=3),
        CalendarEvent(time=now + timedelta(hours=6), currency="USD", title="FOMC", impact=3),
    ]

    blocked, description = feed.in_blackout(now=now)
    assert blocked
    assert "CPI" in description

    clear, _ = feed.in_blackout(now=now + timedelta(hours=2))
    assert not clear


def test_calendar_ignores_low_impact_events():
    settings = Settings()
    feed = CalendarFeed(settings)
    now = datetime(2025, 3, 12, 12, 30, tzinfo=timezone.utc)
    feed._events = [CalendarEvent(time=now, currency="USD", title="Minor survey", impact=1)]
    blocked, _ = feed.in_blackout(now=now)
    assert not blocked


def test_calendar_csv_matches_the_format_the_ea_parses(tmp_path):
    settings = Settings()
    feed = CalendarFeed(settings)
    feed._events = [
        CalendarEvent(
            time=datetime(2025, 3, 12, 12, 30, tzinfo=timezone.utc),
            currency="USD",
            title="Core CPI, m/m",
            impact=3,
        )
    ]
    path = tmp_path / "GoldSMC_calendar.csv"
    feed.write_csv(path)

    rows = path.read_text(encoding="ascii").strip().splitlines()
    assert rows[0] == "time,currency,importance,name"
    assert rows[1] == "2025.03.12 12:30,USD,3,Core CPI  m/m"

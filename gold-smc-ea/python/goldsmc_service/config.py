"""Configuration for the GoldSMC intelligence service.

Every value can be overridden with an environment variable so the service can be
deployed next to the terminal without editing code.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


DEFAULT_NEWS_FEEDS = [
    # Public RSS feeds, no API key required.
    "https://www.investing.com/rss/news_1.rss",
    "https://www.investing.com/rss/commodities_Gold.rss",
    "https://feeds.marketwatch.com/marketwatch/marketpulse/",
    "https://www.federalreserve.gov/feeds/press_all.xml",
]


@dataclass
class Settings:
    """Runtime settings for the service."""

    symbol: str = os.getenv("GOLDSMC_SYMBOL", "XAUUSD")

    # Where the EA reads the snapshot from. Point this at the terminal's
    # MQL5/Files (or Common/Files) directory to use the file transport.
    output_dir: Path = Path(os.getenv("GOLDSMC_OUTPUT_DIR", "./out")).expanduser()
    intel_filename: str = os.getenv("GOLDSMC_INTEL_FILE", "GoldSMC_intel.json")
    calendar_filename: str = os.getenv("GOLDSMC_CALENDAR_FILE", "GoldSMC_calendar.csv")

    host: str = os.getenv("GOLDSMC_HOST", "127.0.0.1")
    port: int = _env_int("GOLDSMC_PORT", 8711)
    refresh_seconds: int = _env_int("GOLDSMC_REFRESH_SECONDS", 300)

    # News / sentiment
    news_feeds: list[str] = field(default_factory=lambda: [
        url.strip()
        for url in os.getenv("GOLDSMC_NEWS_FEEDS", ",".join(DEFAULT_NEWS_FEEDS)).split(",")
        if url.strip()
    ])
    news_lookback_hours: int = _env_int("GOLDSMC_NEWS_LOOKBACK_HOURS", 12)
    news_max_items: int = _env_int("GOLDSMC_NEWS_MAX_ITEMS", 120)

    # Economic calendar (free ForexFactory mirror, weekly JSON)
    calendar_url: str = os.getenv(
        "GOLDSMC_CALENDAR_URL",
        "https://nfs.faireconomy.media/ff_calendar_thisweek.json",
    )
    calendar_currencies: list[str] = field(default_factory=lambda: [
        c.strip().upper()
        for c in os.getenv("GOLDSMC_CALENDAR_CURRENCIES", "USD,XAU,EUR").split(",")
        if c.strip()
    ])
    news_blackout_minutes: int = _env_int("GOLDSMC_BLACKOUT_MINUTES", 30)

    # Model
    model_path: Path = Path(os.getenv("GOLDSMC_MODEL_PATH", "./models/goldsmc_mlp.joblib")).expanduser()
    price_csv: Path = Path(os.getenv("GOLDSMC_PRICE_CSV", "./data/XAUUSD_H1.csv")).expanduser()
    use_model: bool = _env_bool("GOLDSMC_USE_MODEL", True)

    # Blending
    sentiment_weight: float = _env_float("GOLDSMC_SENTIMENT_WEIGHT", 0.4)

    request_timeout: float = _env_float("GOLDSMC_HTTP_TIMEOUT", 10.0)
    user_agent: str = os.getenv(
        "GOLDSMC_USER_AGENT",
        "GoldSMC/1.0 (+https://github.com) python-requests",
    )

    def intel_path(self) -> Path:
        return self.output_dir / self.intel_filename

    def calendar_path(self) -> Path:
        return self.output_dir / self.calendar_filename


settings = Settings()

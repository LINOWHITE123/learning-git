"""News and social sentiment for gold.

Headlines are pulled from public RSS feeds, scored with VADER and re-weighted
with a small gold specific lexicon (a hawkish Fed or a strong dollar is bearish
for gold, risk-off flows are bullish). The result is a single score in -1..+1.
"""

from __future__ import annotations

import logging
import re
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import feedparser
import requests
from vaderSentiment.vaderSentiment import SentimentIntensityAnalyzer

from .config import Settings

log = logging.getLogger(__name__)

# Terms that flip or amplify the meaning of a headline for gold specifically.
GOLD_BULLISH_TERMS = {
    "rate cut": 1.0,
    "dovish": 0.8,
    "inflation surge": 0.6,
    "safe haven": 0.9,
    "geopolitical": 0.6,
    "war": 0.7,
    "recession": 0.6,
    "dollar weakens": 0.9,
    "weaker dollar": 0.9,
    "central bank buying": 0.8,
    "escalation": 0.6,
    "banking crisis": 0.8,
}

GOLD_BEARISH_TERMS = {
    "rate hike": -1.0,
    "hawkish": -0.8,
    "dollar strengthens": -0.9,
    "stronger dollar": -0.9,
    "yields rise": -0.7,
    "risk appetite": -0.5,
    "ceasefire": -0.6,
    "peace deal": -0.6,
    "tapering": -0.5,
    "etf outflows": -0.6,
}

GOLD_KEYWORDS = (
    "gold",
    "xau",
    "bullion",
    "precious metal",
    "fed",
    "fomc",
    "inflation",
    "cpi",
    "dollar",
    "treasury",
    "yield",
)


@dataclass
class Headline:
    title: str
    published: datetime
    source: str
    score: float


@dataclass
class SentimentResult:
    score: float          # -1..+1
    confidence: float     # 0..1, grows with the number of relevant headlines
    sample: int
    headlines: list[Headline]

    def summary(self, limit: int = 3) -> str:
        top = sorted(self.headlines, key=lambda h: abs(h.score), reverse=True)[:limit]
        return " | ".join(f"{h.title[:70]} ({h.score:+.2f})" for h in top)


class SentimentEngine:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._analyzer = SentimentIntensityAnalyzer()
        self._session = requests.Session()
        self._session.headers.update({"User-Agent": settings.user_agent})

    def _fetch_feed(self, url: str) -> Iterable[dict]:
        try:
            response = self._session.get(url, timeout=self._settings.request_timeout)
            response.raise_for_status()
        except requests.RequestException as exc:
            log.warning("feed %s unavailable: %s", url, exc)
            return []
        parsed = feedparser.parse(response.content)
        return parsed.entries or []

    @staticmethod
    def _entry_time(entry: dict) -> datetime:
        for key in ("published_parsed", "updated_parsed"):
            value = entry.get(key)
            if value:
                return datetime(*value[:6], tzinfo=timezone.utc)
        return datetime.now(timezone.utc)

    @staticmethod
    def _is_relevant(title: str) -> bool:
        lowered = title.lower()
        return any(keyword in lowered for keyword in GOLD_KEYWORDS)

    def _lexicon_adjustment(self, title: str) -> float:
        lowered = re.sub(r"\s+", " ", title.lower())
        adjustment = 0.0
        for term, weight in GOLD_BULLISH_TERMS.items():
            if term in lowered:
                adjustment += weight
        for term, weight in GOLD_BEARISH_TERMS.items():
            if term in lowered:
                adjustment += weight
        return max(-1.0, min(1.0, adjustment))

    def _score_headline(self, title: str) -> float:
        vader = self._analyzer.polarity_scores(title)["compound"]
        lexicon = self._lexicon_adjustment(title)
        # The gold specific lexicon dominates when it fires, VADER carries the
        # rest of the tone.
        if lexicon != 0.0:
            return max(-1.0, min(1.0, 0.7 * lexicon + 0.3 * vader))
        return vader

    def analyse(self) -> SentimentResult:
        cutoff = datetime.now(timezone.utc) - timedelta(hours=self._settings.news_lookback_hours)
        headlines: list[Headline] = []

        for url in self._settings.news_feeds:
            for entry in self._fetch_feed(url):
                title = (entry.get("title") or "").strip()
                if not title or not self._is_relevant(title):
                    continue
                published = self._entry_time(entry)
                if published < cutoff:
                    continue
                headlines.append(
                    Headline(
                        title=title,
                        published=published,
                        source=url,
                        score=self._score_headline(title),
                    )
                )
                if len(headlines) >= self._settings.news_max_items:
                    break

        if not headlines:
            return SentimentResult(score=0.0, confidence=0.0, sample=0, headlines=[])

        # Recent headlines matter more: linear decay across the lookback window.
        now = datetime.now(timezone.utc)
        window = max(1.0, self._settings.news_lookback_hours * 3600.0)
        weighted_sum = 0.0
        weight_total = 0.0
        for headline in headlines:
            age = (now - headline.published).total_seconds()
            weight = max(0.15, 1.0 - age / window)
            weighted_sum += headline.score * weight
            weight_total += weight

        score = weighted_sum / weight_total if weight_total else 0.0
        confidence = min(1.0, len(headlines) / 15.0)
        return SentimentResult(
            score=max(-1.0, min(1.0, score)),
            confidence=confidence,
            sample=len(headlines),
            headlines=headlines,
        )

"""FastAPI service that feeds the EA.

It publishes one snapshot combining sentiment, the neural model score and the
economic calendar blackout flag. The EA can either poll ``GET /signal`` over
HTTP or read the JSON file the service keeps refreshed in the terminal's
``MQL5/Files`` directory.
"""

from __future__ import annotations

import asyncio
import json
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any

from fastapi import FastAPI

from .calendar_feed import CalendarFeed
from .config import Settings, settings
from .model import DirectionalModel
from .prices import PriceSource
from .sentiment import SentimentEngine

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("goldsmc")


class IntelligenceService:
    def __init__(self, config: Settings) -> None:
        self._config = config
        self._sentiment = SentimentEngine(config)
        self._calendar = CalendarFeed(config)
        self._model = DirectionalModel(config.model_path)
        self._prices = PriceSource(config.price_csv)
        self._snapshot: dict[str, Any] = self._neutral_snapshot("service starting")

    @staticmethod
    def _neutral_snapshot(note: str) -> dict[str, Any]:
        return {
            "symbol": settings.symbol,
            "sentiment": 0.0,
            "model_score": 0.0,
            "confidence": 0.0,
            "news_blackout": False,
            "note": note,
            "timestamp": int(datetime.now(timezone.utc).timestamp()),
        }

    @property
    def snapshot(self) -> dict[str, Any]:
        return dict(self._snapshot)

    def refresh(self) -> dict[str, Any]:
        notes: list[str] = []

        sentiment = self._sentiment.analyse()
        notes.append(f"news={sentiment.sample}")

        model_score, model_confidence = 0.0, 0.0
        if self._config.use_model:
            prices = self._prices.load()
            if prices is None:
                notes.append("prices=unavailable")
            else:
                model_score, model_confidence = self._model.score(prices)
                notes.append(f"bars={len(prices)}")
                if not self._model.available:
                    notes.append("model=untrained")

        self._calendar.refresh()
        blackout, event = self._calendar.in_blackout()
        if blackout:
            notes.append(f"blackout={event}")

        # Confidence combines how much evidence each side had.
        weight = self._config.sentiment_weight
        confidence = weight * sentiment.confidence + (1.0 - weight) * model_confidence

        snapshot = {
            "symbol": self._config.symbol,
            "sentiment": round(sentiment.score, 4),
            "model_score": round(model_score, 4),
            "confidence": round(confidence, 4),
            "news_blackout": blackout,
            "note": "; ".join(notes)[:240],
            "timestamp": int(datetime.now(timezone.utc).timestamp()),
        }
        self._snapshot = snapshot
        self._publish(snapshot)
        log.info("snapshot: %s", snapshot)
        return snapshot

    def _publish(self, snapshot: dict[str, Any]) -> None:
        path = self._config.intel_path()
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_suffix(path.suffix + ".tmp")
            temporary.write_text(json.dumps(snapshot), encoding="ascii")
            temporary.replace(path)
        except OSError as exc:
            log.error("could not write %s: %s", path, exc)

        try:
            self._calendar.write_csv(self._config.calendar_path())
        except OSError as exc:
            log.error("could not write the calendar CSV: %s", exc)

    def details(self) -> dict[str, Any]:
        sentiment = self._sentiment.analyse()
        upcoming = self._calendar.next_event()
        return {
            "snapshot": self.snapshot,
            "model": self._model.report,
            "model_loaded": self._model.available,
            "headline_sample": sentiment.summary(),
            "headline_count": sentiment.sample,
            "next_event": (
                {
                    "time": upcoming.time.isoformat(),
                    "currency": upcoming.currency,
                    "title": upcoming.title,
                    "impact": upcoming.impact,
                }
                if upcoming
                else None
            ),
        }


service = IntelligenceService(settings)


async def _refresh_loop() -> None:
    while True:
        try:
            await asyncio.to_thread(service.refresh)
        except Exception as exc:  # noqa: BLE001 - the loop must survive any provider failure
            log.exception("refresh failed: %s", exc)
        await asyncio.sleep(settings.refresh_seconds)


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(_refresh_loop())
    try:
        yield
    finally:
        task.cancel()


app = FastAPI(title="GoldSMC intelligence service", version="1.0.0", lifespan=lifespan)


@app.get("/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "symbol": settings.symbol, "output": str(settings.intel_path())}


@app.get("/signal")
def signal(symbol: str | None = None) -> dict[str, Any]:
    payload = service.snapshot
    if symbol:
        payload["symbol"] = symbol
    return payload


@app.post("/refresh")
def refresh_now() -> dict[str, Any]:
    return service.refresh()


@app.get("/details")
def details() -> dict[str, Any]:
    return service.details()


def main() -> None:
    import uvicorn

    uvicorn.run(app, host=settings.host, port=settings.port, log_level="info")


if __name__ == "__main__":
    main()

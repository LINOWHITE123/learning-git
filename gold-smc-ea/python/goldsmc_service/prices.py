"""Price sources for live inference.

Two transports are supported, in priority order:

1. a CSV exported from MetaTrader (the ``ExportBars`` script in ``tools/``
   refreshes it, and the terminal is the same data the EA trades on);
2. ``yfinance`` (``GC=F`` gold futures) as a convenience fallback when the
   service runs on a machine without a terminal.
"""

from __future__ import annotations

import logging
from pathlib import Path

import pandas as pd

from .features import load_price_csv

log = logging.getLogger(__name__)


class PriceSource:
    def __init__(self, csv_path: Path, yahoo_symbol: str = "GC=F") -> None:
        self._csv_path = csv_path
        self._yahoo_symbol = yahoo_symbol

    def load(self, min_rows: int = 200) -> pd.DataFrame | None:
        frame = self._from_csv()
        if frame is not None and len(frame) >= min_rows:
            return frame

        frame = self._from_yahoo()
        if frame is not None and len(frame) >= min_rows:
            return frame

        log.warning("no usable price history available")
        return None

    def _from_csv(self) -> pd.DataFrame | None:
        if not self._csv_path.exists():
            return None
        try:
            return load_price_csv(self._csv_path)
        except Exception as exc:  # noqa: BLE001 - a malformed export must not kill the service
            log.error("could not read %s: %s", self._csv_path, exc)
            return None

    def _from_yahoo(self) -> pd.DataFrame | None:
        try:
            import yfinance  # noqa: PLC0415 - optional dependency
        except ImportError:
            return None
        try:
            raw = yfinance.download(
                self._yahoo_symbol,
                period="60d",
                interval="1h",
                progress=False,
                auto_adjust=False,
            )
        except Exception as exc:  # noqa: BLE001
            log.error("yfinance download failed: %s", exc)
            return None
        if raw is None or raw.empty:
            return None

        if isinstance(raw.columns, pd.MultiIndex):
            raw.columns = raw.columns.get_level_values(0)
        raw = raw.rename(columns=str.lower)
        raw.index = pd.to_datetime(raw.index, utc=True)
        keep = [c for c in ("open", "high", "low", "close", "volume") if c in raw.columns]
        return raw[keep].astype(float)

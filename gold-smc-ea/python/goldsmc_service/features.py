"""Feature engineering shared by training and live inference.

The input is an OHLC frame (H1 by default) with a UTC ``time`` index. Features
are deliberately stationary — returns, normalised distances and oscillators —
so a model trained on one gold regime still means something in the next.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

FEATURE_COLUMNS = [
    "ret_1",
    "ret_4",
    "ret_24",
    "atr_norm",
    "range_ratio",
    "body_ratio",
    "ema_fast_dist",
    "ema_slow_dist",
    "ema_spread",
    "rsi",
    "stoch",
    "bb_position",
    "volatility_ratio",
    "hour_sin",
    "hour_cos",
    "dow_sin",
    "dow_cos",
]


def _rsi(close: pd.Series, period: int = 14) -> pd.Series:
    delta = close.diff()
    gain = delta.clip(lower=0.0)
    loss = -delta.clip(upper=0.0)
    avg_gain = gain.ewm(alpha=1.0 / period, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1.0 / period, adjust=False).mean()
    rs = avg_gain / avg_loss.replace(0.0, np.nan)
    return (100.0 - 100.0 / (1.0 + rs)).fillna(50.0)


def _atr(frame: pd.DataFrame, period: int = 14) -> pd.Series:
    high, low, close = frame["high"], frame["low"], frame["close"]
    prev_close = close.shift(1)
    true_range = pd.concat(
        [high - low, (high - prev_close).abs(), (low - prev_close).abs()], axis=1
    ).max(axis=1)
    return true_range.ewm(alpha=1.0 / period, adjust=False).mean()


def build_features(frame: pd.DataFrame) -> pd.DataFrame:
    """Return a frame of model features aligned to ``frame``'s index."""

    required = {"open", "high", "low", "close"}
    missing = required - set(frame.columns)
    if missing:
        raise ValueError(f"price frame is missing columns: {sorted(missing)}")

    data = frame.sort_index().copy()
    close = data["close"]

    atr = _atr(data)
    ema_fast = close.ewm(span=20, adjust=False).mean()
    ema_slow = close.ewm(span=100, adjust=False).mean()
    rolling_mean = close.rolling(20).mean()
    rolling_std = close.rolling(20).std()

    highest = data["high"].rolling(14).max()
    lowest = data["low"].rolling(14).min()

    out = pd.DataFrame(index=data.index)
    out["ret_1"] = close.pct_change(1)
    out["ret_4"] = close.pct_change(4)
    out["ret_24"] = close.pct_change(24)
    out["atr_norm"] = atr / close
    out["range_ratio"] = (data["high"] - data["low"]) / atr.replace(0.0, np.nan)
    out["body_ratio"] = (close - data["open"]) / (data["high"] - data["low"]).replace(0.0, np.nan)
    out["ema_fast_dist"] = (close - ema_fast) / atr.replace(0.0, np.nan)
    out["ema_slow_dist"] = (close - ema_slow) / atr.replace(0.0, np.nan)
    out["ema_spread"] = (ema_fast - ema_slow) / atr.replace(0.0, np.nan)
    out["rsi"] = _rsi(close) / 100.0
    out["stoch"] = ((close - lowest) / (highest - lowest).replace(0.0, np.nan)).clip(0.0, 1.0)
    out["bb_position"] = ((close - rolling_mean) / rolling_std.replace(0.0, np.nan)).clip(-4.0, 4.0)
    out["volatility_ratio"] = atr / atr.rolling(100).mean().replace(0.0, np.nan)

    is_datetime = isinstance(data.index, pd.DatetimeIndex)
    hours = data.index.hour if is_datetime else pd.Series(0, index=data.index)
    dows = data.index.dayofweek if is_datetime else pd.Series(0, index=data.index)
    out["hour_sin"] = np.sin(2 * np.pi * np.asarray(hours) / 24.0)
    out["hour_cos"] = np.cos(2 * np.pi * np.asarray(hours) / 24.0)
    out["dow_sin"] = np.sin(2 * np.pi * np.asarray(dows) / 7.0)
    out["dow_cos"] = np.cos(2 * np.pi * np.asarray(dows) / 7.0)

    return out[FEATURE_COLUMNS].replace([np.inf, -np.inf], np.nan)


def build_labels(frame: pd.DataFrame, horizon: int = 4, threshold_atr: float = 0.5) -> pd.Series:
    """1 when price advances by ``threshold_atr`` ATR within ``horizon`` bars, else 0.

    Bars that resolve neither way are labelled NaN and dropped, which keeps the
    model focused on moves large enough to be tradable.
    """

    data = frame.sort_index()
    atr = _atr(data)
    close = data["close"]

    future_high = data["high"].shift(-1).rolling(horizon, min_periods=1).max().shift(-(horizon - 1))
    future_low = data["low"].shift(-1).rolling(horizon, min_periods=1).min().shift(-(horizon - 1))

    up_hit = (future_high - close) >= threshold_atr * atr
    down_hit = (close - future_low) >= threshold_atr * atr

    labels = pd.Series(np.nan, index=data.index, dtype="float64")
    labels[up_hit & ~down_hit] = 1.0
    labels[down_hit & ~up_hit] = 0.0
    return labels


def load_price_csv(path) -> pd.DataFrame:
    """Load an MT5 exported CSV into a normalised OHLC frame."""

    frame = pd.read_csv(path)
    frame.columns = [c.strip().lower().lstrip("<").rstrip(">") for c in frame.columns]

    if "time" not in frame.columns:
        if {"date", "time"}.issubset(frame.columns):
            frame["time"] = frame["date"] + " " + frame["time"]
        elif "date" in frame.columns:
            frame["time"] = frame["date"]
        else:
            raise ValueError("price CSV needs a time or date column")

    frame["time"] = pd.to_datetime(frame["time"], utc=True, errors="coerce", format="mixed")
    frame = frame.dropna(subset=["time"]).set_index("time").sort_index()

    rename = {"tickvol": "volume", "vol": "volume", "tick_volume": "volume"}
    frame = frame.rename(columns=rename)
    keep = [c for c in ("open", "high", "low", "close", "volume") if c in frame.columns]
    return frame[keep].astype(float)

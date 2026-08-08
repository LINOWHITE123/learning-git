"""Tolerant coercion of model output.

Vision models paraphrase enums ("BULLISH" for a trend, "no_trade" for a signal), write prices as "4,238",
answer "Not visible in screenshot." where a number was asked for, and sometimes drop a whole object
(`"setup": "wait"`). None of that should fail the request, so every field is normalised here before
validation and anything unusable becomes `None` / `unknown` / an empty list.
"""

import re
from enum import Enum
from typing import Any, TypeVar

NOT_AVAILABLE = {
    "", "n_a", "na", "none", "null", "unknown", "unclear", "not_visible", "not_visible_in_screenshot",
    "not_available", "not_determined", "not_applicable", "not_specified", "tbd",
}

SIGNAL_SYNONYMS = {
    "buy": "long", "bullish": "long", "buy_limit": "long", "sell": "short", "bearish": "short",
    "sell_limit": "short", "no_trade": "wait", "no_setup": "wait", "hold": "wait", "flat": "wait",
    "neutral": "wait", "stand_aside": "wait", "avoid": "wait",
}

BIAS_SYNONYMS = {
    "up": "bullish", "uptrend": "bullish", "bull": "bullish", "long": "bullish",
    "down": "bearish", "downtrend": "bearish", "bear": "bearish", "short": "bearish",
    "sideways": "ranging", "range": "ranging", "range_bound": "ranging", "rangebound": "ranging",
    "neutral": "ranging", "consolidation": "ranging", "consolidating": "ranging", "mixed": "ranging",
    "choppy": "ranging", "flat": "ranging",
}

TREND_SYNONYMS = {
    "bullish": "up", "bull": "up", "uptrend": "up", "rising": "up", "higher": "up",
    "bearish": "down", "bear": "down", "downtrend": "down", "falling": "down", "lower": "down",
    "ranging": "sideways", "range": "sideways", "range_bound": "sideways", "rangebound": "sideways",
    "neutral": "sideways", "flat": "sideways", "consolidating": "sideways", "consolidation": "sideways",
    "choppy": "sideways", "mixed": "sideways",
}

LEVEL_SYNONYMS = {
    "moderate": "medium", "normal": "medium", "average": "medium", "mid": "medium", "neutral": "medium",
    "very_high": "high", "elevated": "high", "strong": "high", "very_low": "low", "weak": "low",
    "quiet": "low", "muted": "low",
}

LIQUIDITY_SYNONYMS = {
    "sell_side": "sell_side_sweep", "sellside": "sell_side_sweep", "sellside_sweep": "sell_side_sweep",
    "sell_side_liquidity_sweep": "sell_side_sweep", "sell_side_liquidity": "sell_side_sweep",
    "sweep_of_sell_side_liquidity": "sell_side_sweep", "sell_stops_swept": "sell_side_sweep",
    "buy_side": "buy_side_sweep", "buyside": "buy_side_sweep", "buyside_sweep": "buy_side_sweep",
    "buy_side_liquidity_sweep": "buy_side_sweep", "buy_side_liquidity": "buy_side_sweep",
    "sweep_of_buy_side_liquidity": "buy_side_sweep", "buy_stops_swept": "buy_side_sweep",
    "no_sweep": "none", "not_detected": "none", "no_liquidity_sweep": "none", "neither": "none",
}

ZONE_PRICE_KEYS = ("low", "price", "level", "value", "from", "start", "bottom", "min")
ZONE_HIGH_KEYS = ("high", "to", "end", "top", "max")
NUMBER_PATTERN = re.compile(r"-?\d[\d,]*(?:\.\d+)?")
# In "4230-4240" the hyphen separates two levels; without this the second parses as -4240.
RANGE_SEPARATOR = re.compile(r"(?<=\d)\s*[-–—/]\s*(?=\d)")

EnumT = TypeVar("EnumT", bound=Enum)


def slug(value: Any) -> str:
    """'Sell-Side Sweep' -> 'sell_side_sweep'; 'Not visible in screenshot.' -> 'not_visible_in_screenshot'."""
    text = re.sub(r"[^a-z0-9]+", "_", str(value).strip().lower())
    return text.strip("_")


def parse_number(value: Any) -> float | None:
    """Accept 4238, '4,238.50', '~4238', '4238 (approx)'. Return None for prose or missing values."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int | float):
        return float(value)
    if not isinstance(value, str):
        return None
    match = NUMBER_PATTERN.search(value)
    if not match:
        return None
    try:
        return float(re.sub(r"[,\s]", "", match.group(0)))
    except ValueError:
        return None


def coerce_enum(value: Any, enum_cls: type[EnumT], synonyms: dict[str, str], fallback: EnumT) -> EnumT:
    if isinstance(value, enum_cls):
        return value
    if value is None:
        return fallback
    key = slug(value)
    if key in NOT_AVAILABLE:
        return fallback
    key = synonyms.get(key, key)
    try:
        return enum_cls(key)
    except ValueError:
        return fallback


def coerce_text(value: Any, fallback: str = "") -> str:
    if value is None:
        return fallback
    if isinstance(value, list | tuple):
        return ", ".join(str(item) for item in value if item)
    return str(value)


def coerce_str_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        parts = [part.strip() for part in re.split(r"[,;\n]", value)]
        return [part for part in parts if part and slug(part) not in NOT_AVAILABLE]
    if isinstance(value, dict):
        return [f"{key}: {item}" for key, item in value.items() if item is not None]
    if isinstance(value, list | tuple):
        return [coerce_text(item) for item in value if item is not None and slug(item) not in NOT_AVAILABLE]
    return [coerce_text(value)]


def coerce_float_list(value: Any) -> list[float]:
    if value is None:
        return []
    items = value if isinstance(value, list | tuple) else [value]
    numbers = (parse_number(item) for item in items)
    return [number for number in numbers if number is not None]


def coerce_zone(value: Any) -> Any:
    """Accept 4238, '4,238', {'price': ...}, {'low': ..., 'high': ...}, {'zone': '4230-4240'}."""
    if isinstance(value, int | float | str):
        low = parse_number(value)
        return None if low is None else {"label": "", "low": low, "high": None, "approximate": True}
    if not isinstance(value, dict):
        return None

    zone = dict(value)
    low = next((parse_number(zone[key]) for key in ZONE_PRICE_KEYS if zone.get(key) is not None), None)
    high = next((parse_number(zone[key]) for key in ZONE_HIGH_KEYS if zone.get(key) is not None), None)
    if low is None and high is None:
        text = coerce_text(zone.get("zone") or zone.get("range") or zone.get("label"))
        numbers = coerce_float_list(NUMBER_PATTERN.findall(RANGE_SEPARATOR.sub(" ", text)))
        if not numbers:
            return None
        low, high = numbers[0], (numbers[1] if len(numbers) > 1 else None)
    if low is None:
        low, high = high, None
    if high is not None and high < low:
        low, high = high, low
    return {
        "label": coerce_text(zone.get("label") or zone.get("name") or zone.get("note")),
        "low": low,
        "high": high,
        "approximate": bool(zone.get("approximate", True)),
    }


def coerce_zone_list(value: Any) -> list[dict]:
    if value is None:
        return []
    items = value if isinstance(value, list | tuple) else [value]
    zones = (coerce_zone(item) for item in items)
    return [zone for zone in zones if zone is not None]


def coerce_percent(value: Any) -> int:
    number = parse_number(value)
    if number is None:
        return 0
    if 0 < number <= 1:
        number *= 100
    return max(0, min(100, round(number)))


def coerce_setup(value: Any) -> dict | None:
    """Drop the setup entirely unless entry, stop loss and a first target are all readable numbers."""
    if not isinstance(value, dict):
        return None

    setup = dict(value)
    entry = parse_number(setup.get("entry") or setup.get("entry_price"))
    stop = parse_number(setup.get("stop_loss") or setup.get("stop") or setup.get("sl"))
    targets = coerce_float_list(setup.get("take_profits") or setup.get("targets"))
    tp1 = parse_number(setup.get("take_profit_1") or setup.get("tp1") or setup.get("take_profit"))
    tp2 = parse_number(setup.get("take_profit_2") or setup.get("tp2"))
    if tp1 is None and targets:
        tp1 = targets[0]
    if tp2 is None and len(targets) > 1:
        tp2 = targets[1]
    if entry is None or stop is None or tp1 is None:
        return None

    return {
        "entry": entry,
        "entry_note": coerce_text(setup.get("entry_note") or setup.get("note")),
        "stop_loss": stop,
        "take_profit_1": tp1,
        "take_profit_2": tp2,
        "risk_reward": parse_number(setup.get("risk_reward")),
        "invalidation": parse_number(setup.get("invalidation") or setup.get("invalidation_level")),
        "invalidation_note": coerce_text(setup.get("invalidation_note")),
        "levels_approximate": bool(setup.get("levels_approximate", True)),
    }


def coerce_charts(value: Any) -> list[dict]:
    """Accept a list of chart reads, or a mapping of timeframe -> chart read."""
    if isinstance(value, dict):
        return [{"timeframe": key, **item} for key, item in value.items() if isinstance(item, dict)]
    if isinstance(value, list | tuple):
        return [item for item in value if isinstance(item, dict)]
    return []


def coerce_flags(value: Any) -> dict:
    """Confidence factors may arrive as a dict of booleans or as a list of the factors that were present."""
    if isinstance(value, dict):
        return {slug(key): bool(flag) for key, flag in value.items()}
    if isinstance(value, list | tuple):
        return {slug(item): True for item in value if item}
    return {}

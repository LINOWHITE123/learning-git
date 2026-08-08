"""Real gpt-4o output shapes that the strict schema used to reject."""

import pytest

from app.analyzer import enforce_rules
from app.coerce import coerce_setup, coerce_zone, parse_number, slug
from app.models import Bias, Level, Liquidity, ScanResult, Signal, Trend


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (4238, 4238.0),
        (4238.5, 4238.5),
        ("4,238.50", 4238.5),
        ("~4238", 4238.0),
        ("4238 (approx)", 4238.0),
        ("Not visible in screenshot.", None),
        ("", None),
        (None, None),
        (True, None),
    ],
)
def test_parse_number(raw, expected):
    assert parse_number(raw) == expected


def test_slug_normalises_prose():
    assert slug("Sell-Side Sweep") == "sell_side_sweep"
    assert slug("Not visible in screenshot.") == "not_visible_in_screenshot"


@pytest.mark.parametrize(
    ("raw", "field", "expected"),
    [
        ("BULLISH", "trend", Trend.UP),
        ("Bearish", "trend", Trend.DOWN),
        ("range-bound", "trend", Trend.SIDEWAYS),
        ("Not visible in screenshot.", "trend", Trend.UNKNOWN),
        ("UP", "momentum", Bias.BULLISH),
        ("neutral", "momentum", Bias.RANGING),
        ("Moderate", "volatility", Level.MEDIUM),
        ("n/a", "volatility", Level.UNKNOWN),
        ("Sell-Side Sweep", "liquidity", Liquidity.SELL_SIDE_SWEEP),
        ("sweep of buy side liquidity", "liquidity", Liquidity.BUY_SIDE_SWEEP),
        ("no sweep", "liquidity", Liquidity.NONE),
    ],
)
def test_enum_synonyms(raw, field, expected):
    assert getattr(ScanResult.model_validate({field: raw}), field) is expected


@pytest.mark.parametrize(("raw", "expected"), [("BUY", Signal.LONG), ("sell", Signal.SHORT), ("no_trade", Signal.WAIT)])
def test_signal_synonyms(raw, expected):
    assert ScanResult.model_validate({"signal": raw}).signal is expected


@pytest.mark.parametrize(("raw", "expected"), [("78%", 78), (0.78, 78), (150, 100), ("unknown", 0)])
def test_confidence_is_clamped(raw, expected):
    assert ScanResult.model_validate({"confidence": raw}).confidence == expected


def test_setup_returned_as_a_string_is_dropped():
    """gpt-4o answers `"setup": "wait"` when it declines a trade."""
    result = ScanResult.model_validate({"signal": "wait", "setup": "wait"})
    assert result.setup is None


def test_setup_accepts_aliases_and_string_prices():
    setup = coerce_setup({"entry": "4,238", "sl": "4224", "targets": ["4,273", "4320"]})
    assert (setup["entry"], setup["stop_loss"], setup["take_profit_1"], setup["take_profit_2"]) == (
        4238.0,
        4224.0,
        4273.0,
        4320.0,
    )


def test_setup_without_readable_levels_is_dropped():
    assert coerce_setup({"entry": "Not visible in screenshot.", "stop_loss": 4224, "take_profit_1": 4273}) is None


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (4238, (4238.0, None)),
        ("4,238", (4238.0, None)),
        ({"price": "4238"}, (4238.0, None)),
        ({"low": 4240, "high": 4230}, (4230.0, 4240.0)),
        ({"zone": "4230 - 4240"}, (4230.0, 4240.0)),
        ({"label": "support", "high": 4240}, (4240.0, None)),
    ],
)
def test_coerce_zone(raw, expected):
    zone = coerce_zone(raw)
    assert (zone["low"], zone["high"]) == expected


def test_unreadable_zones_are_dropped():
    charts = ScanResult.model_validate(
        {"charts": [{"support": ["Not visible in screenshot.", 4295.5, {"zone": "4230-4240"}]}]}
    ).charts
    assert [(zone.low, zone.high) for zone in charts[0].support] == [(4295.5, None), (4230.0, 4240.0)]


def test_charts_given_as_a_timeframe_mapping():
    result = ScanResult.model_validate({"charts": {"H4": {"trend": "bullish"}, "M15": {"trend": "bearish"}}})
    assert [(chart.timeframe, chart.trend) for chart in result.charts] == [("H4", Trend.UP), ("M15", Trend.DOWN)]


def test_factors_given_as_a_list():
    factors = ScanResult.model_validate({"factors": ["htf_trend", "BOS or CHoCH"]}).factors
    assert (factors.htf_trend, factors.bos_or_choch, factors.order_block) == (True, True, False)


def test_string_lists_are_split():
    chart = ScanResult.model_validate({"charts": [{"structure_events": "HH, HL, BOS"}]}).charts[0]
    assert chart.structure_events == ["HH", "HL", "BOS"]


def test_null_lists_and_texts_are_tolerated():
    chart = ScanResult.model_validate(
        {"charts": [{"patterns": None, "price_action": None, "swing_highs": [None, "4,300"]}]}
    ).charts[0]
    assert (chart.patterns, chart.price_action, chart.swing_highs) == ([], "", [4300.0])


def test_headline_fields_are_filled_from_the_entry_chart():
    """The model fills the per-image reads but often leaves the headline fields unknown."""
    result = enforce_rules(
        ScanResult.model_validate(
            {
                "signal": "wait",
                "charts": [
                    {"timeframe": "H4", "symbol": "XAUUSD", "trend": "up", "volatility": "high"},
                    {"timeframe": "M15", "symbol": "XAUUSD", "trend": "up", "volatility": "medium", "volume": "low"},
                ],
            }
        ),
        min_rr=2.0,
    )
    assert result.symbol == "XAUUSD"
    assert result.primary_timeframe == "M15"
    assert (result.trend, result.volatility, result.sentiment) == (Trend.UP, Level.MEDIUM, Bias.BULLISH)


def test_model_warnings_are_not_duplicated():
    result = enforce_rules(
        ScanResult.model_validate(
            {
                "signal": "wait",
                "warnings": [
                    "Price levels are approximate due to chart resolution.",
                    "No news data from a screenshot.",
                ],
                "setup": {"entry": 4238, "stop_loss": 4224, "take_profit_1": 4273, "levels_approximate": True},
            }
        ),
        min_rr=2.0,
    )
    assert len([warning for warning in result.warnings if "approximate" in warning.lower()]) == 1
    assert len([warning for warning in result.warnings if "news" in warning.lower()]) == 1

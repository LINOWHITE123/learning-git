import pytest

from app.analyzer import (
    APPROXIMATE_WARNING,
    BLURRY_WARNING,
    NO_NEWS_WARNING,
    confidence_band,
    enforce_rules,
    guess_timeframe,
    normalize_timeframe,
    risk_reward,
    scan_charts,
    timeframe_minutes,
)
from app.models import Bias, ConfidenceBand, ScanResult, Signal
from app.providers import ChartImage, DemoProvider


def make_result(**overrides) -> ScanResult:
    payload = {
        "symbol": "XAUUSD",
        "primary_timeframe": "M15",
        "signal": "long",
        "confidence": 78,
        "trend": "up",
        "momentum": "bullish",
        "volatility": "medium",
        "structure": "bullish",
        "liquidity": "sell_side_sweep",
        "sentiment": "bullish",
        "alignment": {"H4": "bullish", "H1": "bullish", "M15": "bullish"},
        "setup": {
            "entry": 4238.0,
            "stop_loss": 4224.0,
            "take_profit_1": 4273.0,
            "take_profit_2": 4320.0,
            "levels_approximate": False,
        },
        "charts": [{"timeframe": "M15", "bias": "bullish"}],
    }
    payload.update(overrides)
    return ScanResult.model_validate(payload)


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("15m", "M15"), ("M15", "M15"), ("15", "M15"), ("240", "H4"), ("4h", "H4"),
        ("H1", "H1"), ("60", "H1"), ("1 hour", "H1"), ("1d", "D1"), ("", ""),
    ],
)
def test_normalize_timeframe(raw, expected):
    assert normalize_timeframe(raw) == expected


def test_timeframe_minutes_orders_high_to_low():
    labels = ["M15", "H1", "H4"]
    assert sorted(labels, key=timeframe_minutes, reverse=True) == ["H4", "H1", "M15"]


@pytest.mark.parametrize(
    ("filename", "expected"),
    [("XAUUSD-4h.png", "H4"), ("chart_15m.jpg", "M15"), ("gold-H1.webp", "H1"), ("shot.png", "")],
)
def test_guess_timeframe(filename, expected):
    assert guess_timeframe(filename) == expected


def test_risk_reward_math():
    assert risk_reward(4238, 4224, 4273) == 2.5
    assert risk_reward(100, 100, 120) is None


@pytest.mark.parametrize(
    ("score", "band"),
    [
        (90, ConfidenceBand.VERY_STRONG),
        (78, ConfidenceBand.STRONG),
        (66, ConfidenceBand.MODERATE),
        (50, ConfidenceBand.WEAK),
    ],
)
def test_confidence_bands(score, band):
    assert confidence_band(score) == band


def test_valid_aligned_setup_is_kept():
    result = enforce_rules(make_result(), min_rr=2.0)
    assert result.signal is Signal.LONG
    assert result.setup.risk_reward == 2.5
    assert result.confidence_band is ConfidenceBand.STRONG
    assert result.timeframes_analyzed == ["H4", "H1", "M15"]
    assert result.factors.risk_reward is True
    assert NO_NEWS_WARNING in result.warnings
    assert APPROXIMATE_WARNING not in result.warnings


def test_low_risk_reward_becomes_wait():
    result = enforce_rules(
        make_result(setup={"entry": 4238.0, "stop_loss": 4224.0, "take_profit_1": 4250.0}), min_rr=2.0
    )
    assert result.signal is Signal.WAIT
    assert any("Risk:reward" in warning for warning in result.warnings)


def test_inconsistent_levels_become_wait():
    result = enforce_rules(
        make_result(setup={"entry": 4238.0, "stop_loss": 4250.0, "take_profit_1": 4300.0}), min_rr=1.0
    )
    assert result.signal is Signal.WAIT


def test_conflicting_timeframes_become_wait():
    result = enforce_rules(make_result(alignment={"H4": "bearish", "H1": "bullish", "M15": "bullish"}), min_rr=2.0)
    assert result.signal is Signal.WAIT
    assert any("conflict" in warning for warning in result.warnings)


def test_low_confidence_becomes_wait():
    result = enforce_rules(make_result(confidence=60), min_rr=2.0)
    assert result.signal is Signal.WAIT
    assert result.confidence_band is ConfidenceBand.WEAK


def test_missing_setup_becomes_wait():
    result = enforce_rules(make_result(setup=None), min_rr=2.0)
    assert result.signal is Signal.WAIT


def test_single_timeframe_warns_about_missing_htf():
    result = enforce_rules(make_result(alignment={"M15": "bullish"}), min_rr=2.0)
    assert any("H4/H1 confirmation unavailable." in warning for warning in result.warnings)
    assert result.signal is Signal.LONG


def test_unusable_image_becomes_wait():
    result = enforce_rules(
        make_result(
            charts=[
                {
                    "timeframe": "M15",
                    "bias": "bullish",
                    "quality": {"usable": False, "issues": ["Image is too blurry to read the price scale."]},
                }
            ]
        ),
        min_rr=2.0,
    )
    assert result.signal is Signal.WAIT
    assert BLURRY_WARNING in result.warnings
    assert "Image is too blurry to read the price scale." in result.warnings


def test_unknown_bias_only_becomes_wait():
    result = enforce_rules(make_result(alignment={"M15": "unknown"}), min_rr=2.0)
    assert result.signal is Signal.WAIT


def test_approximate_levels_are_flagged():
    result = enforce_rules(
        make_result(
            setup={
                "entry": 4238.0,
                "stop_loss": 4224.0,
                "take_profit_1": 4273.0,
                "levels_approximate": True,
            }
        ),
        min_rr=2.0,
    )
    assert APPROXIMATE_WARNING in result.warnings


def test_demo_provider_output_passes_the_rule_engine():
    images = [
        ChartImage("gold-4h.png", "image/png", b"htf"),
        ChartImage("gold-1h.png", "image/png", b"mtf"),
        ChartImage("gold-15m.png", "image/png", b"ltf"),
    ]
    result = scan_charts(DemoProvider(), images, symbol="XAUUSD")
    assert result.provider == "demo"
    assert result.timeframes_analyzed == ["H4", "H1", "M15"]
    assert result.signal in (Signal.LONG, Signal.SHORT)
    assert result.setup.risk_reward >= 2.0
    assert all(bias is not Bias.UNKNOWN for bias in result.alignment.values())
    assert any("Demo mode" in warning for warning in result.warnings)

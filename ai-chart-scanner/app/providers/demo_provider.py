import hashlib

from .base import ChartImage, VisionProvider

DEMO_WARNING = (
    "Demo mode: no vision model is configured, so this analysis was generated locally and is NOT a read of "
    "your screenshot. Set OPENAI_API_KEY or ANTHROPIC_API_KEY to analyse charts for real."
)


class DemoProvider(VisionProvider):
    """Offline provider used when no model API key is configured.

    It cannot see the charts, so it returns a deterministic, clearly-flagged sample analysis derived from a hash of
    the uploaded bytes. Useful for exercising the UI and the rule engine without spending API credits.
    """

    name = "demo"

    def analyze(self, images: list[ChartImage], system_prompt: str, user_prompt: str) -> dict:
        digest = hashlib.sha256(b"".join(image.data for image in images) or b"empty").digest()
        long_side = digest[0] % 2 == 0
        bias = "bullish" if long_side else "bearish"
        entry = float(4200 + digest[1] % 80)
        risk = 8 + digest[2] % 10
        reward = risk * 2.5
        if long_side:
            stop, tp1, tp2 = entry - risk, entry + reward, entry + reward * 1.6
        else:
            stop, tp1, tp2 = entry + risk, entry - reward, entry - reward * 1.6

        labels = [image.timeframe or image.filename for image in images] or ["M15"]
        charts = [
            {
                "source": image.filename,
                "timeframe": image.timeframe or "M15",
                "symbol": "DEMO",
                "current_price": entry,
                "price_levels_approximate": True,
                "bias": bias,
                "trend": "up" if long_side else "down",
                "momentum": bias,
                "volatility": "medium",
                "volume": "medium",
                "volume_note": "Not visible in screenshot.",
                "structure": bias,
                "structure_events": ["BOS", "HH", "HL"] if long_side else ["BOS", "LH", "LL"],
                "structure_note": "Demo mode does not read the chart.",
                "swing_highs": [entry + risk * 2],
                "swing_lows": [entry - risk * 2],
                "support": [{"label": "demo support", "low": entry - risk, "approximate": True}],
                "resistance": [{"label": "demo resistance", "low": entry + reward, "approximate": True}],
                "liquidity": "sell_side_sweep" if long_side else "buy_side_sweep",
                "liquidity_note": "Demo mode does not read the chart.",
                "quality": {
                    "usable": True,
                    "symbol_visible": False,
                    "timeframe_visible": False,
                    "price_scale_visible": False,
                    "candles_visible": False,
                    "issues": ["Demo mode did not inspect the image."],
                },
            }
            for image in images
        ] or [{"timeframe": "M15", "bias": bias}]

        return {
            "symbol": "DEMO",
            "primary_timeframe": labels[-1],
            "signal": "long" if long_side else "short",
            "confidence": 70 + digest[3] % 15,
            "trend": "up" if long_side else "down",
            "momentum": bias,
            "volatility": "medium",
            "structure": bias,
            "liquidity": "sell_side_sweep" if long_side else "buy_side_sweep",
            "sentiment": bias,
            "alignment": {image.timeframe or "M15": bias for image in images} or {"M15": bias},
            "alignment_note": "Demo mode assumes the provided timeframes agree.",
            "setup": {
                "entry": entry,
                "entry_note": f"{'Buy' if long_side else 'Sell'} on retest of {entry:g} (demo)",
                "stop_loss": stop,
                "take_profit_1": round(tp1, 2),
                "take_profit_2": round(tp2, 2),
                "invalidation": stop,
                "invalidation_note": "Demo level.",
                "levels_approximate": True,
            },
            "charts": charts,
            "summary": DEMO_WARNING,
            "factors": {"htf_trend": True, "ltf_structure": True, "bos_or_choch": True, "risk_reward": True},
            "warnings": [DEMO_WARNING],
        }

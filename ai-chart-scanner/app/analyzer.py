import re

from .config import min_risk_reward
from .models import (
    NOT_VISIBLE,
    Bias,
    ChartRead,
    ConfidenceBand,
    ScanResult,
    Signal,
    TradeSetup,
    Trend,
)
from .prompt import build_system_prompt, build_user_prompt
from .providers import ChartImage, VisionProvider

MIN_CONFIDENCE = 65
NO_NEWS_WARNING = "News data is not available from the screenshot."
BLURRY_WARNING = "Unable to reliably analyze this screenshot. Please upload a clearer chart."
APPROXIMATE_WARNING = "Price levels are approximate because they were estimated from the screenshot."

TIMEFRAME_PATTERN = re.compile(
    r"\b(m|h|d|w)?\s*(\d{1,4})\s*(m|min|mins|minute|h|hr|hour|d|day|w|week)?\b",
    re.IGNORECASE,
)
FILENAME_PATTERN = re.compile(r"\b([mh])\s*(\d{1,3})\b|\b(\d{1,4})\s*(m|min|h|hour)\b", re.IGNORECASE)
UNIT_MINUTES = {
    "m": 1, "min": 1, "mins": 1, "minute": 1,
    "h": 60, "hr": 60, "hour": 60,
    "d": 1440, "day": 1440,
    "w": 10080, "week": 10080,
}
MT5_CODES = {"1": 1, "5": 5, "15": 15, "30": 30, "60": 60, "240": 240}
HEADLINE_FIELDS = ("trend", "momentum", "volatility", "structure", "liquidity")
TREND_TO_BIAS = {Trend.UP: Bias.BULLISH, Trend.DOWN: Bias.BEARISH, Trend.SIDEWAYS: Bias.RANGING}


def normalize_timeframe(raw: str) -> str:
    """Turn '15m', 'M15', '240', '4 hour' into a canonical label like 'M15' or 'H4'."""
    text = (raw or "").strip()
    if not text:
        return ""
    match = TIMEFRAME_PATTERN.search(text)
    if not match:
        return text
    prefix, number, suffix = match.group(1), int(match.group(2)), match.group(3)
    unit = (suffix or prefix or "").lower()
    if unit:
        minutes = number * UNIT_MINUTES.get(unit, 0)
    else:
        minutes = MT5_CODES.get(str(number), number)
    if not minutes:
        return text
    if minutes % 10080 == 0:
        return f"W{minutes // 10080}"
    if minutes % 1440 == 0:
        return f"D{minutes // 1440}"
    if minutes % 60 == 0:
        return f"H{minutes // 60}"
    return f"M{minutes}"


def timeframe_minutes(label: str) -> int:
    canonical = normalize_timeframe(label)
    match = re.fullmatch(r"([MHDW])(\d{1,4})", canonical or "")
    if not match:
        return 0
    unit, number = match.group(1), int(match.group(2))
    return number * {"M": 1, "H": 60, "D": 1440, "W": 10080}[unit]


def guess_timeframe(filename: str) -> str:
    """Best-effort timeframe hint from a filename such as 'XAUUSD-4h.png' or 'chart_15m.jpg'."""
    text = re.sub(r"[_\-.]+", " ", filename or "")
    match = FILENAME_PATTERN.search(text)
    return normalize_timeframe(match.group(0)) if match else ""


def confidence_band(score: int) -> ConfidenceBand:
    if score >= 85:
        return ConfidenceBand.VERY_STRONG
    if score >= 75:
        return ConfidenceBand.STRONG
    if score >= MIN_CONFIDENCE:
        return ConfidenceBand.MODERATE
    return ConfidenceBand.WEAK


def risk_reward(entry: float, stop_loss: float, take_profit: float) -> float | None:
    risk = abs(entry - stop_loss)
    if risk == 0:
        return None
    return round(abs(take_profit - entry) / risk, 2)


def levels_consistent(signal: Signal, setup: TradeSetup) -> bool:
    targets = [setup.take_profit_1] + ([setup.take_profit_2] if setup.take_profit_2 is not None else [])
    if signal is Signal.LONG:
        return setup.stop_loss < setup.entry < min(targets)
    if signal is Signal.SHORT:
        return setup.stop_loss > setup.entry > max(targets)
    return True


def chart_bias(chart: ChartRead) -> Bias:
    """A chart's directional read, falling back to its trend when `bias` was left unknown."""
    if chart.bias is not Bias.UNKNOWN:
        return chart.bias
    return TREND_TO_BIAS.get(chart.trend, Bias.UNKNOWN)


def entry_chart(result: ScanResult) -> ChartRead | None:
    """The lowest uploaded timeframe - the one the entry is taken on."""
    if not result.charts:
        return None
    ranked = [chart for chart in result.charts if timeframe_minutes(chart.timeframe)]
    if not ranked:
        return result.charts[-1]
    return min(ranked, key=lambda chart: timeframe_minutes(chart.timeframe))


def fill_from_charts(result: ScanResult) -> None:
    """Models routinely fill the per-image reads but leave the headline fields blank; mirror them up."""
    entry = entry_chart(result)
    if entry is None:
        return

    if not result.symbol or result.symbol == NOT_VISIBLE:
        readable = [chart.symbol for chart in result.charts if chart.symbol and chart.symbol != NOT_VISIBLE]
        if readable:
            result.symbol = readable[0]
    if not timeframe_minutes(result.primary_timeframe) and timeframe_minutes(entry.timeframe):
        result.primary_timeframe = entry.timeframe

    for field in HEADLINE_FIELDS:
        if getattr(result, field).value == "unknown":
            setattr(result, field, getattr(entry, field))
    if result.sentiment is Bias.UNKNOWN:
        result.sentiment = chart_bias(entry)


def _warns_about(result: ScanResult, keyword: str) -> bool:
    """The model usually writes its own version of these warnings; don't add a near-duplicate."""
    return any(keyword in warning.lower() for warning in result.warnings)


def _wait(result: ScanResult, reason: str) -> None:
    result.signal = Signal.WAIT
    if reason not in result.warnings:
        result.warnings.append(reason)


def check_alignment(result: ScanResult) -> None:
    """H4 -> H1 -> M15: every provided timeframe must agree with the signal direction."""
    biases = {normalize_timeframe(tf): bias for tf, bias in result.alignment.items() if normalize_timeframe(tf)}
    result.alignment = dict(sorted(biases.items(), key=lambda item: timeframe_minutes(item[0]), reverse=True))

    if result.signal is Signal.WAIT:
        return

    expected = Bias.BULLISH if result.signal is Signal.LONG else Bias.BEARISH
    directional = [bias for bias in biases.values() if bias is not Bias.UNKNOWN]
    if not directional:
        _wait(result, "No directional bias could be read from the uploaded screenshots.")
        return
    if any(bias is not expected for bias in directional):
        disagreeing = ", ".join(f"{tf} {bias.value}" for tf, bias in biases.items() if bias is not expected)
        _wait(result, f"Timeframes conflict with a {result.signal.value} ({disagreeing}).")


def check_coverage(result: ScanResult) -> None:
    provided = {tf for tf in result.alignment}
    missing = [tf for tf in ("H4", "H1") if tf not in provided]
    if missing and provided:
        result.warnings.append(
            f"Only {', '.join(sorted(provided, key=timeframe_minutes, reverse=True))} "
            f"{'was' if len(provided) == 1 else 'were'} provided. "
            f"{'/'.join(missing)} confirmation unavailable."
        )


def enforce_rules(result: ScanResult, min_rr: float | None = None) -> ScanResult:
    """Recompute the numbers and force WAIT whenever the visible evidence does not meet the criteria."""
    threshold = min_risk_reward() if min_rr is None else min_rr

    if any(not chart.quality.usable for chart in result.charts):
        _wait(result, BLURRY_WARNING)
        for chart in result.charts:
            for issue in chart.quality.issues:
                if issue not in result.warnings:
                    result.warnings.append(issue)

    setup = result.setup
    if setup is not None:
        setup.risk_reward = risk_reward(setup.entry, setup.stop_loss, setup.take_profit_1)
        if not levels_consistent(result.signal, setup):
            _wait(
                result,
                "Setup levels are inconsistent with the signal direction, so no trade is suggested.",
            )
        elif setup.risk_reward is None:
            _wait(result, "Stop loss equals entry, so risk:reward cannot be measured.")
        elif setup.risk_reward < threshold:
            _wait(
                result,
                f"Risk:reward 1:{setup.risk_reward} is below the 1:{threshold:g} minimum, so no trade is suggested.",
            )
    elif result.signal is not Signal.WAIT:
        _wait(result, "No trade setup could be calculated from the screenshot.")

    if result.confidence < MIN_CONFIDENCE and result.signal is not Signal.WAIT:
        _wait(result, f"Confidence {result.confidence}% is below the {MIN_CONFIDENCE}% minimum.")

    fill_from_charts(result)
    check_alignment(result)
    check_coverage(result)

    result.confidence_band = confidence_band(result.confidence)
    result.factors.risk_reward = bool(setup and setup.risk_reward and setup.risk_reward >= threshold)
    result.timeframes_analyzed = list(result.alignment.keys())
    if timeframe_minutes(result.primary_timeframe):
        result.primary_timeframe = normalize_timeframe(result.primary_timeframe)
    elif result.timeframes_analyzed:
        result.primary_timeframe = result.timeframes_analyzed[-1]

    if setup is not None and setup.levels_approximate and not _warns_about(result, "approximate"):
        result.warnings.append(APPROXIMATE_WARNING)
    if not _warns_about(result, "news"):
        result.warnings.append(NO_NEWS_WARNING)
    result.warnings = list(dict.fromkeys(result.warnings))
    return result


def scan_charts(
    provider: VisionProvider,
    images: list[ChartImage],
    symbol: str = "",
    entry_timeframe: str = "M15",
    notes: str = "",
) -> ScanResult:
    for image in images:
        image.timeframe = normalize_timeframe(image.timeframe) or guess_timeframe(image.filename)
    ordered = sorted(images, key=lambda image: timeframe_minutes(image.timeframe), reverse=True)

    raw = provider.analyze(
        ordered,
        build_system_prompt(min_risk_reward()),
        build_user_prompt(
            count=len(ordered),
            labels=[image.timeframe or image.filename for image in ordered],
            symbol=symbol,
            entry_timeframe=normalize_timeframe(entry_timeframe) or "M15",
            notes=notes,
        ),
    )
    raw["provider"] = provider.name
    result = ScanResult.model_validate(raw)

    for chart, image in zip(result.charts, ordered, strict=False):
        if not chart.source:
            chart.source = image.filename
        chart.timeframe = normalize_timeframe(chart.timeframe) or image.timeframe or chart.timeframe
    if not result.alignment:
        result.alignment = {chart.timeframe: chart_bias(chart) for chart in result.charts if chart.timeframe}
    return enforce_rules(result)

from enum import Enum
from typing import Annotated, Any

from pydantic import BaseModel, BeforeValidator, Field

from .coerce import (
    BIAS_SYNONYMS,
    LEVEL_SYNONYMS,
    LIQUIDITY_SYNONYMS,
    SIGNAL_SYNONYMS,
    TREND_SYNONYMS,
    coerce_charts,
    coerce_enum,
    coerce_flags,
    coerce_float_list,
    coerce_percent,
    coerce_setup,
    coerce_str_list,
    coerce_text,
    coerce_zone_list,
    parse_number,
)

NOT_VISIBLE = "Not visible in screenshot."


class Signal(str, Enum):
    LONG = "long"
    SHORT = "short"
    WAIT = "wait"


class Bias(str, Enum):
    BULLISH = "bullish"
    BEARISH = "bearish"
    RANGING = "ranging"
    UNKNOWN = "unknown"


class Trend(str, Enum):
    UP = "up"
    DOWN = "down"
    SIDEWAYS = "sideways"
    UNKNOWN = "unknown"


class Level(str, Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    UNKNOWN = "unknown"


class Liquidity(str, Enum):
    BUY_SIDE_SWEEP = "buy_side_sweep"
    SELL_SIDE_SWEEP = "sell_side_sweep"
    NONE = "none"
    UNKNOWN = "unknown"


class ConfidenceBand(str, Enum):
    VERY_STRONG = "very_strong"
    STRONG = "strong"
    MODERATE = "moderate"
    WEAK = "weak"


def _enum_field(enum_cls: type[Enum], synonyms: dict[str, str], fallback: Enum) -> Any:
    return BeforeValidator(lambda value: coerce_enum(value, enum_cls, synonyms, fallback))


SignalField = Annotated[Signal, _enum_field(Signal, SIGNAL_SYNONYMS, Signal.WAIT)]
BiasField = Annotated[Bias, _enum_field(Bias, BIAS_SYNONYMS, Bias.UNKNOWN)]
TrendField = Annotated[Trend, _enum_field(Trend, TREND_SYNONYMS, Trend.UNKNOWN)]
LevelField = Annotated[Level, _enum_field(Level, LEVEL_SYNONYMS, Level.UNKNOWN)]
LiquidityField = Annotated[Liquidity, _enum_field(Liquidity, LIQUIDITY_SYNONYMS, Liquidity.UNKNOWN)]
Text = Annotated[str, BeforeValidator(coerce_text)]
MaybePrice = Annotated[float | None, BeforeValidator(parse_number)]
Prices = Annotated[list[float], BeforeValidator(coerce_float_list)]
TextList = Annotated[list[str], BeforeValidator(coerce_str_list)]


class Zone(BaseModel):
    """A price area read off the chart. `high` is None for a single line level."""

    label: Text = ""
    low: float
    high: MaybePrice = None
    approximate: bool = True


Zones = Annotated[list[Zone], BeforeValidator(coerce_zone_list)]


class ImageQuality(BaseModel):
    usable: bool = True
    symbol_visible: bool = False
    timeframe_visible: bool = False
    price_scale_visible: bool = False
    candles_visible: bool = False
    issues: TextList = Field(default_factory=list)


class ChartRead(BaseModel):
    """Everything the model could actually see on one uploaded screenshot."""

    source: Text = Field(default="", description="uploaded filename")
    timeframe: Text = Field(default=NOT_VISIBLE, description="detected from the chart, e.g. H4, H1, M15")
    symbol: Text = NOT_VISIBLE
    current_price: MaybePrice = None
    price_levels_approximate: bool = True
    bias: BiasField = Bias.UNKNOWN
    trend: TrendField = Trend.UNKNOWN
    momentum: BiasField = Bias.UNKNOWN
    volatility: LevelField = Level.UNKNOWN
    volume: LevelField = Level.UNKNOWN
    volume_note: Text = NOT_VISIBLE
    structure: BiasField = Bias.UNKNOWN
    structure_events: TextList = Field(
        default_factory=list, description="HH, HL, LH, LL, BOS, CHoCH, MSS, continuation, reversal"
    )
    structure_note: Text = NOT_VISIBLE
    swing_highs: Prices = Field(default_factory=list)
    swing_lows: Prices = Field(default_factory=list)
    support: Zones = Field(default_factory=list)
    resistance: Zones = Field(default_factory=list)
    demand_zones: Zones = Field(default_factory=list)
    supply_zones: Zones = Field(default_factory=list)
    order_blocks: Zones = Field(default_factory=list)
    fair_value_gaps: Zones = Field(default_factory=list)
    breakout_levels: Zones = Field(default_factory=list)
    retest_levels: Zones = Field(default_factory=list)
    liquidity: LiquidityField = Liquidity.UNKNOWN
    liquidity_note: Text = NOT_VISIBLE
    indicators: TextList = Field(default_factory=list, description="only indicators visible on the chart")
    moving_averages: Text = NOT_VISIBLE
    rsi: Text = NOT_VISIBLE
    macd: Text = NOT_VISIBLE
    patterns: TextList = Field(default_factory=list)
    price_action: Text = NOT_VISIBLE
    quality: ImageQuality = Field(default_factory=ImageQuality)


class TradeSetup(BaseModel):
    entry: float
    entry_note: Text = ""
    stop_loss: float
    take_profit_1: float
    take_profit_2: MaybePrice = None
    risk_reward: MaybePrice = None
    invalidation: MaybePrice = None
    invalidation_note: Text = ""
    levels_approximate: bool = True


class ConfidenceFactors(BaseModel):
    """Which confluences the model claims to have seen."""

    htf_trend: bool = False
    ltf_structure: bool = False
    bos_or_choch: bool = False
    liquidity_sweep: bool = False
    support_resistance: bool = False
    order_block: bool = False
    fair_value_gap: bool = False
    momentum: bool = False
    chart_pattern: bool = False
    risk_reward: bool = False


class ScanResult(BaseModel):
    symbol: Text = NOT_VISIBLE
    primary_timeframe: Text = NOT_VISIBLE
    timeframes_analyzed: TextList = Field(default_factory=list)
    signal: SignalField = Signal.WAIT
    confidence: Annotated[int, BeforeValidator(coerce_percent)] = Field(default=0, ge=0, le=100)
    confidence_band: ConfidenceBand = ConfidenceBand.WEAK
    trend: TrendField = Trend.UNKNOWN
    momentum: BiasField = Bias.UNKNOWN
    volatility: LevelField = Level.UNKNOWN
    structure: BiasField = Bias.UNKNOWN
    liquidity: LiquidityField = Liquidity.UNKNOWN
    sentiment: BiasField = Bias.UNKNOWN
    alignment: dict[str, BiasField] = Field(
        default_factory=dict, description="timeframe label -> bias, e.g. {'H4': 'bullish'}"
    )
    alignment_note: Text = ""
    setup: Annotated[TradeSetup | None, BeforeValidator(coerce_setup)] = None
    charts: Annotated[list[ChartRead], BeforeValidator(coerce_charts)] = Field(default_factory=list)
    summary: Text = ""
    factors: Annotated[ConfidenceFactors, BeforeValidator(coerce_flags)] = Field(default_factory=ConfidenceFactors)
    warnings: TextList = Field(default_factory=list)
    provider: Text = "demo"
    disclaimer: str = (
        "Screenshot analysis only. No live prices, no live news, no order placement. "
        "The confidence score is an analytical score, not a probability of winning."
    )

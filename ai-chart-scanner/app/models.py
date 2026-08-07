from enum import Enum

from pydantic import BaseModel, Field

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


class Zone(BaseModel):
    """A price area read off the chart. `high` equals `low` for a single line level."""

    label: str = ""
    low: float
    high: float | None = None
    approximate: bool = True


class ImageQuality(BaseModel):
    usable: bool = True
    symbol_visible: bool = False
    timeframe_visible: bool = False
    price_scale_visible: bool = False
    candles_visible: bool = False
    issues: list[str] = Field(default_factory=list)


class ChartRead(BaseModel):
    """Everything the model could actually see on one uploaded screenshot."""

    source: str = Field(default="", description="uploaded filename")
    timeframe: str = Field(default=NOT_VISIBLE, description="detected from the chart, e.g. H4, H1, M15")
    symbol: str = NOT_VISIBLE
    current_price: float | None = None
    price_levels_approximate: bool = True
    bias: Bias = Bias.UNKNOWN
    trend: Trend = Trend.UNKNOWN
    momentum: Bias = Bias.UNKNOWN
    volatility: Level = Level.UNKNOWN
    volume: Level = Level.UNKNOWN
    volume_note: str = NOT_VISIBLE
    structure: Bias = Bias.UNKNOWN
    structure_events: list[str] = Field(
        default_factory=list, description="HH, HL, LH, LL, BOS, CHoCH, MSS, continuation, reversal"
    )
    structure_note: str = NOT_VISIBLE
    swing_highs: list[float] = Field(default_factory=list)
    swing_lows: list[float] = Field(default_factory=list)
    support: list[Zone] = Field(default_factory=list)
    resistance: list[Zone] = Field(default_factory=list)
    demand_zones: list[Zone] = Field(default_factory=list)
    supply_zones: list[Zone] = Field(default_factory=list)
    order_blocks: list[Zone] = Field(default_factory=list)
    fair_value_gaps: list[Zone] = Field(default_factory=list)
    breakout_levels: list[Zone] = Field(default_factory=list)
    retest_levels: list[Zone] = Field(default_factory=list)
    liquidity: Liquidity = Liquidity.UNKNOWN
    liquidity_note: str = NOT_VISIBLE
    indicators: list[str] = Field(default_factory=list, description="only indicators actually visible on the chart")
    moving_averages: str = NOT_VISIBLE
    rsi: str = NOT_VISIBLE
    macd: str = NOT_VISIBLE
    patterns: list[str] = Field(default_factory=list)
    price_action: str = NOT_VISIBLE
    quality: ImageQuality = Field(default_factory=ImageQuality)


class TradeSetup(BaseModel):
    entry: float
    entry_note: str = ""
    stop_loss: float
    take_profit_1: float
    take_profit_2: float | None = None
    risk_reward: float | None = None
    invalidation: float | None = None
    invalidation_note: str = ""
    levels_approximate: bool = True


class ConfidenceFactors(BaseModel):
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
    symbol: str = NOT_VISIBLE
    primary_timeframe: str = NOT_VISIBLE
    timeframes_analyzed: list[str] = Field(default_factory=list)
    signal: Signal = Signal.WAIT
    confidence: int = Field(default=0, ge=0, le=100)
    confidence_band: ConfidenceBand = ConfidenceBand.WEAK
    trend: Trend = Trend.UNKNOWN
    momentum: Bias = Bias.UNKNOWN
    volatility: Level = Level.UNKNOWN
    structure: Bias = Bias.UNKNOWN
    liquidity: Liquidity = Liquidity.UNKNOWN
    sentiment: Bias = Bias.UNKNOWN
    alignment: dict[str, Bias] = Field(
        default_factory=dict, description="timeframe label -> bias, e.g. {'H4': 'bullish'}"
    )
    alignment_note: str = ""
    setup: TradeSetup | None = None
    charts: list[ChartRead] = Field(default_factory=list)
    summary: str = ""
    factors: ConfidenceFactors = Field(default_factory=ConfidenceFactors)
    warnings: list[str] = Field(default_factory=list)
    provider: str = "demo"
    disclaimer: str = (
        "Screenshot analysis only. No live prices, no live news, no order placement. "
        "The confidence score is an analytical score, not a probability of winning."
    )

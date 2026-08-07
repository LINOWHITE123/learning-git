# How GoldSMC decides

Every decision is taken **once per closed M15 bar**. Open positions are managed
on every tick.

## 1. Higher timeframe bias (H4)

`CMarketStructure` rebuilds the swing points from the last `InpHtfBars` closed
bars using a fractal of `InpFractalSize` bars on each side, then scores:

| Evidence | Weight |
| --- | --- |
| higher highs **and** higher lows (or the bearish mirror) | 2 |
| last close broke the most recent swing high / low (BOS) | 1 |
| close above / below the `InpBiasEmaPeriod` EMA | 1 |

The side with the larger score wins and `strength = score / 4`. A setup is
rejected when `strength < InpMinHtfStrength` (default 0.5).

## 2. Alignment timeframe (H1)

The same scoring runs on H1. With `InpRequireMtfAlign = true` (default) H1 must
produce the same direction as H4, otherwise the bar is skipped.

## 3. Areas of interest (M15)

`CZoneEngine` scans the entry timeframe for:

* **Demand / supply order blocks** — the last opposite-colour candle before an
  impulse of at least `InpImpulseAtr` × ATR that closes beyond the base candle's
  high (or low). The zone is the base candle's high–low range.
* **Fair value gaps** — a three candle imbalance of at least 0.25 × ATR
  (`InpUseFvg`).

Each zone is then walked forward in time:

* every bar that trades inside it counts as a **touch**; more than
  `InpMaxZoneTouches` (default 1) and the zone is dropped;
* a close beyond the far side **mitigates** the zone and removes it entirely.

## 4. Entry trigger

All of these must be true:

1. price is within `InpZoneProximityAtr` × ATR of an unmitigated zone on the
   correct side of the bias;
2. the last closed M15 bar actually traded into the zone;
3. `InpConfirm`:
   * `CONFIRM_NONE` — trade the touch;
   * `CONFIRM_CANDLE` (default) — engulfing, a ≥50 % rejection wick, or a ≥60 %
     body in the trade direction;
   * `CONFIRM_STRUCTURE` — the above **plus** a micro break of structure or a
     liquidity sweep that closed back inside.

## 5. Stop, target and size

```
stop      = far side of the zone ± InpStopBufferAtr × ATR
            (widened to the last M15 swing when that sits further out)
clamped   to [InpMinStopAtr × ATR, InpMaxStopAtr × ATR]  (wider -> setup skipped)
target    = entry ± InpRewardRatio × stop distance        (default 1:4)
lots      = balance × risk% × quality / money-value-of-the-stop
```

`quality` (0.1 – 1.0) combines HTF strength, H1 agreement, whether the zone is
untouched, order block vs FVG, micro structure confirmation and the intelligence
score. With `InpScaleRiskByQuality` the best setups get the full risk and weaker
ones get proportionally less.

The sizing function refuses to trade at all when the broker's minimum lot would
exceed `InpMaxRiskPercent`, or when the margin required is more than half of the
free margin.

## 6. Trade management

| Stage | Default |
| --- | --- |
| partial close | 30 % of the position at +1R |
| break even | stop to entry +0.1R at +1R |
| trail | ATR × 1.5 once past +2R |
| target | 1:4, left on the remainder |

## 7. Gates that block new entries

* daily loss ≥ `InpDailyLossPercent` (resets next session);
* equity drawdown ≥ `InpMaxDrawdownPercent` (halts until the EA is restarted);
* `InpMaxPositions`, `InpMaxTradesPerDay`, `InpMaxLossesPerDay`;
* spread above `InpMaxSpreadPoints`;
* outside `InpSessionStartHour`–`InpSessionEndHour`, weekends, optional Monday /
  Friday exclusions, Friday flatten before the weekend gap;
* an economic calendar blackout;
* the intelligence layer, per `InpIntelMode`.

## 8. What the intelligence layer can and cannot do

It can **veto** (`FILTER_STRICT`), **halve the size** (`FILTER_SOFT`) or be
**ignored** (`FILTER_OFF`). It never creates a trade on its own, and a stale or
unreachable service simply leaves the EA trading on structure alone.

# How GoldSMC decides

The EA reads the market top down and splits the work over four timeframes:

```
H4  -> primary trend        (swings, BOS, CHoCH, EMA)
H1  -> confirmation         (same direction + premium/discount + liquidity)
M15 -> setup detection      (sweep, BOS/CHoCH, order block / FVG) -> zone stored
M5  -> execution only       (retrace into the stored zone, fresh BOS/CHoCH,
                             momentum, spread and volatility)
```

Structure is rebuilt **once per closed setup bar (M15)** and execution is checked
**once per closed execution bar (M5)**. Open positions are managed on every tick.
No decision ever reads bar 0, so there is no repainting and no look-ahead bias:
the tester and a live account see exactly the same inputs.

An entry requires **every** stage below to pass. There is at most one open
position and there is no averaging, martingale or grid logic in the code.

---

## 1. H4 — primary trend

`CMarketStructure` rebuilds swing highs and lows from the last `InpHtfBars`
closed bars using a fractal of `InpFractalSize` bars each side, replays the
structural events in order and scores the result:

| Evidence | Weight |
| --- | --- |
| higher highs **and** higher lows (or the bearish mirror) | 2 |
| the most recent event is a BOS in that direction | 1 |
| the most recent event is a CHoCH in that direction | 2 |
| close above / below the `InpBiasEmaPeriod` EMA | 1 |

`strength = score / 6`. Below `InpMinTrendStrength` (default 0.5) nothing is
armed. Trades are only ever taken in the H4 direction.

**BOS vs CHoCH.** Walking forward through the bars, a close beyond the last
*protected* swing high is a break of structure when the running trend is already
bullish, and a change of character when it was bearish (mirrored for lows). The
"protected" level is the newest swing that finished forming at least
`InpFractalSize` bars before the bar being tested, which is what keeps the
detection causal.

## 2. H1 — confirmation

The same engine runs on H1 and three things are checked:

* **Direction** — H1 must produce the same bias as H4, otherwise stand aside.
* **Premium / discount** — the H1 dealing range (last swing high to last swing
  low) is split at its equilibrium. With `InpRequireDiscount` (default on) longs
  are only armed while price sits in the discount half and shorts only in the
  premium half, so the EA never buys at the top of the range.
* **Liquidity** — a sweep of the protected H1 level (wick through, close back
  inside) is recorded in the bias snapshot and raises setup quality.

## 3. M15 — setup detection, no entries

When H4 and H1 agree, the setup timeframe has to produce:

1. a **liquidity sweep** in the trade direction within `InpSweepLookback` bars
   (required when `InpRequireSweep`, otherwise it only adds quality);
2. a **BOS or CHoCH** in the trade direction no older than
   `InpStructureLookback` bars;
3. an **area of interest** within `InpZoneProximityAtr` × ATR of price:
   * **order block** — the last opposite-colour candle before an impulse of at
     least `InpImpulseAtr` × ATR that closes beyond the base candle;
   * **fair value gap** — a three candle imbalance of at least 0.25 × ATR
     (`InpUseFvg`);
   * **mitigation block** — a zone that has already been tapped once; allowed
     only while `InpUseMitigationBlock` is on.

Every zone is walked forward: each bar trading inside it counts as a touch
(`InpMaxZoneTouches`) and a close beyond the far side removes it entirely.

The surviving zone is **stored and armed** — the EA does *not* trade here. An
armed setup is discarded after `InpSetupExpiryBars` M15 bars if price never
returns to it, or as soon as H4/H1 stop agreeing.

## 4. M5 — execution

With a setup armed, each closed M5 bar is tested against, in order:

| # | Gate |
| --- | --- |
| 1 | risk manager allows a new trade (limits, streaks, target, drawdown) |
| 2 | inside an enabled session (London / New York, server time) |
| 3 | spread ≤ `InpMaxSpreadPoints` |
| 4 | no economic calendar blackout |
| 5 | execution ATR inside `InpMinAtrPoints` … `InpMaxAtrPoints` |
| 6 | last M5 candle range inside `InpMinCandleAtr` … `InpMaxCandleAtr` × ATR |
| 7 | tick volume ≥ `InpMinVolumeRatio` × its average (`InpUseLiquidityFilter`) |
| 8 | **price traded back inside the stored M15 zone** |
| 9 | **a fresh M5 BOS/CHoCH** no older than `InpExecEventBars` bars |
| 10 | **momentum confirms**: ≥40 % body on the right side of the M5 EMA |

Only then is an order sent, and the setup is disarmed immediately afterwards, so
one armed zone can produce at most one trade.

## 5. Stop, target and size

```
stop      = far side of the zone ± InpStopBufferAtr × ATR
            (widened to the last M5 swing when that sits further out)
clamped   to [InpMinStopAtr × ATR, InpMaxStopAtr × ATR]  (wider -> setup skipped)
target    = entry ± InpRewardRatio × stop distance        (default 1:4)
lots      = account base × risk% × quality / money-value-of-the-stop
```

The stop always sits behind real structure — there is no fixed pip stop anywhere
in the code. Broker minimum stop distances and volume steps are enforced.

`quality` (0.1 – 1.0) combines H4 strength, the sweep, the type of zone (order
block over FVG), whether it is untouched, and the intelligence score. With
`InpScaleRiskByQuality` the best setups get the full tier risk and weaker ones
proportionally less.

Sizing refuses to trade when the broker's minimum lot would breach
`InpMaxRiskPercent`, or when the margin needed is more than half of the free
margin. See [`RISK.md`](RISK.md) for the balance tiers.

## 6. Trade management

| Stage | Input | Default |
| --- | --- | --- |
| partial close | `InpUsePartial`, `InpPartialAtR`, `InpPartialPercent` | 50 % at +1R |
| break even | `InpUseBreakEven`, `InpBreakEvenAtR`, `InpBreakEvenOffsetR` | stop to entry +0.1R at +1R |
| trailing | `InpTrailMode` = `TRAIL_ATR` / `TRAIL_STRUCTURE` / `TRAIL_OFF` | ATR × 1.5 once past +2R |
| target | `InpRewardRatio` | 1:4 on the remainder |

`TRAIL_STRUCTURE` follows the last M5 swing low (long) or swing high (short)
with an `InpTrailStructBuffer` × ATR buffer instead of a pure ATR distance.

## 7. Gates that stop trading entirely

* **daily profit target** (`InpDailyProfitTarget`, default 500 in account
  currency, 0 disables): closes open positions, cancels pending orders and
  stands down until the next trading day;
* **daily loss** ≥ `InpDailyLossPercent`, **daily losers** ≥
  `InpMaxLossesPerDay`, **consecutive losers** ≥ `InpMaxConsecutiveLoss` — all
  reset on the next trading day;
* **equity drawdown** ≥ `InpMaxDrawdownPercent` — a hard halt until the EA is
  restarted;
* `InpMaxPositions`, `InpMaxTradesPerDay`;
* weekends, optional Monday / Friday exclusions and the Friday flatten;
* the intelligence layer, per `InpIntelMode`.

## 8. What the intelligence layer can and cannot do

It can **veto** (`FILTER_STRICT`), **halve the size** (`FILTER_SOFT`) or be
**ignored** (`FILTER_OFF`). It never creates a trade on its own, and a stale or
unreachable service simply leaves the EA trading on structure alone.

## 9. Dashboard, notifications and logs

The on-chart dashboard shows trend, session, balance, equity, risk % and
profile, lot size, daily P/L, target and remaining target, open trades, win
rate, drawdown, EA status and the current setup / execution state.

Alerts, push notifications and email (`InpAlerts`, `InpPushNotifications`,
`InpEmailNotifications`) fire on trade open, trade close, daily target, daily
loss, halts and errors — they are suppressed in the strategy tester and written
to the journal instead. The journal logs entry and exit reasons, BOS/CHoCH and
sweep detections, and every risk and lot calculation.

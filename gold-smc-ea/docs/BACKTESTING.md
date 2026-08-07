# Backtesting and going live

## 1. Get real gold data

Gold spreads and swaps vary a lot between brokers, and a backtest on the wrong
symbol is worthless. In the terminal you will actually trade on:

1. open **XAUUSD M5, M15, H1 and H4** charts and scroll back several years so the
   terminal downloads every timeframe the EA reads;
2. **Tools → Options → Charts → Max bars in chart:** `Unlimited`.

If the M5 history is missing the EA simply never executes, and if H4/H1/M15 are
missing it never arms a setup — the dashboard status line says which one.

## 2. Strategy Tester settings

| Setting | Value |
| --- | --- |
| Symbol | your broker's XAUUSD |
| Period | **M5** (the execution timeframe) |
| Model | **Every tick based on real ticks** (falls back to *Every tick* if real ticks are unavailable) |
| Deposit | the size you will actually trade |
| Leverage | your live leverage |
| Dates | at least 3 years, and always include 2020 and 2022 (gold's violent regimes) |

## 3. First run: sanity, not profit

Run once with the defaults. What you are checking:

* trades are actually taken (if not, the on-chart status line says why);
* stop distances look like real structural stops, not a fixed number;
* the take profit sits at 4× the stop;
* the equity curve has no single catastrophic day.

`OnTester` returns `profit / drawdown% × min(profit factor, 5)` and gives zero
for runs with fewer than 30 trades, so the optimiser cannot win by taking three
lucky trades.

## 4. Parameters worth optimising

Optimise a few at a time, never all at once:

| Group | Inputs |
| --- | --- |
| Structure | `InpFractalSize`, `InpMinTrendStrength`, `InpBiasEmaPeriod` |
| Zones | `InpImpulseAtr`, `InpZoneProximityAtr`, `InpMaxZoneTouches`, `InpUseFvg` |
| Setup | `InpSweepLookback`, `InpStructureLookback`, `InpSetupExpiryBars`, `InpRequireDiscount` |
| Execution | `InpExecEventBars`, `InpRequireExecMomentum`, `InpMinCandleAtr` |
| Stops | `InpStopBufferAtr`, `InpMinStopAtr`, `InpMaxStopAtr` |
| Targets | `InpRewardRatio` (try 2, 3, 4, 5) |

Leave the risk inputs alone during optimisation — optimise the *edge* with
`InpRiskProfile = RISK_CONSERVATIVE`, then decide the size afterwards. Comparing
Balanced against Aggressive is a separate run on the *same* settings: the trade
list should be identical and only the equity curve should differ.

Relaxing the entry chain is the right lever when a run takes too few trades:
`InpRequireSweep = false`, a larger `InpStructureLookback` / `InpExecEventBars`,
or `InpRequireDiscount = false` — in roughly that order of harmlessness.

Set `InpDailyProfitTarget = 0` for research runs: the default 500 stands the EA
down for the rest of the day as soon as it is hit, which is correct live but
truncates a backtest's sample.

## 5. Reading the result honestly

At 1:4 the break-even hit rate is 20 %. A realistic good result is:

* win rate 30–40 %;
* profit factor 1.3–1.8;
* max equity drawdown under 15 %;
* at least 150 trades in the sample.

If a run shows a 90 % win rate, something is wrong — usually too few trades, or
a `InpRewardRatio` below 1. Also compare against the same period with
`InpUseIntel = false` so you can see whether the intelligence layer helps at all.

## 6. Forward test before live

1. Demo account, defaults, **at least one month**. Gold moves enough that a month
   is a real sample.
2. Compare the demo trade list against the backtest expectation. Slippage and
   spread widening around news are the usual reasons live results decay.
3. Only then go live, and start at a fraction of the size you intend to trade.

## 7. Position sizing across account sizes

Sizing is fully automatic: risk is a percentage, so the same settings work on a
$500 account and a $50,000 one. Two practical limits:

* on a small account the broker's minimum lot (usually 0.01) can already exceed
  the tier risk on a wide gold stop — the EA then **skips** the trade rather than
  over-risking. Move up a risk profile or trade a cent account;
* `InpMaxRiskPercent` is a hard ceiling the sizing code will not cross, whatever
  the tiers say.

## 8. Other symbols

The logic is symbol agnostic, but the defaults are tuned for gold's volatility.
For FX majors start with `InpImpulseAtr = 1.0`, `InpMaxSpreadPoints = 30`, and
re-run step 3 before trusting anything.

# Backtesting and going live

## 1. Get real gold data

Gold spreads and swaps vary a lot between brokers, and a backtest on the wrong
symbol is worthless. In the terminal you will actually trade on:

1. open an **XAUUSD M15** chart and scroll back several years so the terminal
   downloads history;
2. **Tools → Options → Charts → Max bars in chart:** `Unlimited`.

## 2. Strategy Tester settings

| Setting | Value |
| --- | --- |
| Symbol | your broker's XAUUSD |
| Period | M15 |
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
| Structure | `InpFractalSize`, `InpMinHtfStrength`, `InpBiasEmaPeriod` |
| Zones | `InpImpulseAtr`, `InpZoneProximityAtr`, `InpMaxZoneTouches`, `InpUseFvg` |
| Entry | `InpConfirm` |
| Stops | `InpStopBufferAtr`, `InpMinStopAtr`, `InpMaxStopAtr` |
| Targets | `InpRewardRatio` (try 2, 3, 4, 5) |

Leave the risk inputs alone during optimisation — optimise the *edge* at a fixed
1 % risk, then decide the size afterwards.

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
  1 % risk on a wide gold stop — the EA then **skips** the trade rather than
  over-risking. Raise `InpRiskPercent` slightly or trade a cent account;
* `InpMaxRiskPercent` is a hard ceiling the sizing code will not cross, whatever
  `InpRiskPercent` says.

## 8. Other symbols

The logic is symbol agnostic, but the defaults are tuned for gold's volatility.
For FX majors start with `InpImpulseAtr = 1.0`, `InpMaxSpreadPoints = 30`, and
re-run step 3 before trusting anything.

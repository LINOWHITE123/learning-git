# Risk: the numbers behind the defaults

## Why 30 % per trade is not survivable

Probability of `n` consecutive losses at win rate `w`, and what it does to the
account at 30 % risk per loss:

| Win rate | P(3 losses in a row) | Account after 3 losses | P(5 in a row) | After 5 |
| --- | --- | --- | --- | --- |
| 90 % | 1 in 1,000 | 34 % | 1 in 100,000 | 17 % |
| 70 % | 1 in 37 | 34 % | 1 in 412 | 17 % |
| 50 % | 1 in 8 | 34 % | 1 in 32 | 17 % |
| 35 % (realistic at 1:4) | 1 in 3.6 | 34 % | 1 in 8.6 | 17 % |

A 66 % drawdown needs a 194 % gain to recover. At 1 % risk, ten consecutive
losses cost about 10 % — recoverable inside a normal week.

## Why the hit rate is the wrong target

At a reward-to-risk of 1:R the break-even win rate is `1 / (1 + R)`:

| R | Break-even win rate | Expectancy at a 35 % win rate |
| --- | --- | --- |
| 1:1 | 50 % | −0.30 R |
| 1:2 | 33 % | +0.05 R |
| 1:3 | 25 % | +0.40 R |
| **1:4** | **20 %** | **+0.75 R** |
| 1:5 | 17 % | +1.10 R |

At 1:4 the EA is profitable losing two out of three trades. Chasing a 90 % hit
rate means small targets and huge stops, which is the classic way accounts die.

## The layered protection in the code

| Layer | Input | Default | Effect |
| --- | --- | --- | --- |
| Per-trade risk | `InpRiskPercent` | 1 % | position size derived from the stop |
| Hard ceiling | `InpMaxRiskPercent` | 5 % | sizing refuses to exceed it, even if the minimum lot would |
| Quality scaling | `InpScaleRiskByQuality` | on | weak setups get a fraction of the risk |
| Concurrency | `InpMaxPositions` | 1 | no stacked correlated exposure |
| Daily activity | `InpMaxTradesPerDay` | 3 | stops revenge trading |
| Daily damage | `InpDailyLossPercent` | 3 % | closes the day, resets tomorrow |
| Losing streak | `InpMaxLossesPerDay` | 2 | stops after two stop-outs |
| Account | `InpMaxDrawdownPercent` | 15 % | halts the EA until you restart it |
| Margin | built in | — | rejects a trade needing more than 50 % of free margin |
| Gap risk | `InpCloseBeforeWeekend` | on | flat before the weekend |
| Event risk | `InpUseNewsFilter` | on | no entries around high impact news |

## Sizing worked example

```
Balance          $10,000
Risk             1 %              -> $100
Entry            2,412.50
Stop             2,406.10          -> 6.40 stop distance
XAUUSD tick value $1 per 0.01 move per 1.00 lot -> $640 risk per lot
Lots             100 / 640 = 0.15  (rounded down to the lot step)
Actual risk      $96
Take profit      2,412.50 + 4 × 6.40 = 2,438.10  -> $384 target
```

## If you still want more risk

Raise it gradually and only after a forward test: 1 % → 2 % → 3 %. Anything
above 5 % requires raising `InpMaxRiskPercent` first, which is deliberate
friction. Beyond about 3 % per trade, drawdown grows much faster than return —
the same edge with worse odds of ever seeing it pay.

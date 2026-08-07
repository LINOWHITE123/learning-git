# Risk: the numbers behind the defaults

## Risk profiles

`InpRiskProfile` selects a ladder of risk percentages that steps **down** as the
account grows, so a small account can compound and a grown one protects itself.
The balance bands (`InpTier1Balance`, `InpTier2Balance`, `InpTier3Balance`) and
every percentage are inputs; `RISK_CUSTOM` uses `InpRiskTier1..4` directly.

| Balance band | Conservative | **Balanced (default)** | Aggressive |
| --- | --- | --- | --- |
| up to $250 | 2.0 % | **10 %** | 25 % |
| $250 – $500 | 1.5 % | **7 %** | 15 % |
| $500 – $1,000 | 1.0 % | **5 %** | 10 % |
| above $1,000 | 0.75 % | **2.5 %** | 5 % |

Risk is taken from `min(balance, equity)`, so it compounds up with profit and
shrinks immediately in a drawdown. `InpMaxRiskPercent` (default 12 %) is a hard
ceiling the sizing code will not cross whatever the tiers say, and setups below
full quality get proportionally less when `InpScaleRiskByQuality` is on.

## What the Aggressive preset actually costs

Probability of `n` consecutive losses at win rate `w`, and what it does to the
account at 25 % risk per loss:

| Win rate | P(3 in a row) | Account after 3 | P(5 in a row) | After 5 |
| --- | --- | --- | --- | --- |
| 90 % | 1 in 1,000 | 42 % | 1 in 100,000 | 24 % |
| 70 % | 1 in 37 | 42 % | 1 in 412 | 24 % |
| 50 % | 1 in 8 | 42 % | 1 in 32 | 24 % |
| 35 % (realistic at 1:4) | 1 in 3.6 | 42 % | 1 in 8.6 | 24 % |

A 58 % drawdown needs a 138 % gain to recover, and `InpMaxDrawdownPercent`
(default 25 %) will halt the EA long before the compounding has a chance to
work. That is why Balanced, not Aggressive, is the shipped default — the
Aggressive table is exactly the one requested and is one dropdown away.

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
| Per-trade risk | `InpRiskProfile` tiers | Balanced | position size derived from the structural stop |
| Hard ceiling | `InpMaxRiskPercent` | 12 % | sizing refuses to exceed it, even at the minimum lot |
| Quality scaling | `InpScaleRiskByQuality` | on | weak setups get a fraction of the risk |
| Concurrency | `InpMaxPositions` | 1 | one position, no averaging / martingale / grid |
| Daily activity | `InpMaxTradesPerDay` | 5 | stops revenge trading |
| Daily damage | `InpDailyLossPercent` | 10 % | closes the day, resets tomorrow |
| Daily losers | `InpMaxLossesPerDay` | 3 | ends the day after three stop-outs |
| Losing streak | `InpMaxConsecutiveLoss` | 3 | ends the day after three in a row |
| Daily target | `InpDailyProfitTarget` | 500 | flattens, cancels pendings, stands down until tomorrow |
| Account | `InpMaxDrawdownPercent` | 25 % | halts the EA until you restart it |
| Margin | built in | — | rejects a trade needing more than 50 % of free margin |
| Gap risk | `InpCloseBeforeWeekend` | on | flat before the weekend |
| Event risk | `InpUseNewsFilter` | on | no entries around high impact news |

The daily target, daily loss, daily-loser and streak halts all clear
automatically at the start of the next trading day. The drawdown halt does not —
it is deliberate friction that forces you to look at why it fired.

## Sizing worked example

```
Balance          $10,000       -> Balanced tier 4 = 2.5 %
Risk                            -> $250
Entry            2,412.50
Stop             2,406.10        -> 6.40 stop distance
XAUUSD tick value $1 per 0.01 move per 1.00 lot -> $640 risk per lot
Lots             250 / 640 = 0.39 (rounded down to the lot step)
Actual risk      $249.60
Take profit      2,412.50 + 4 × 6.40 = 2,438.10  -> $998 target
```

## If you want more risk

Move one step at a time — Conservative → Balanced → Aggressive — and only after
a forward test on demo. Beyond roughly 5 % per trade, drawdown grows much faster
than return: the same edge, with far worse odds of ever living long enough to
see it pay.

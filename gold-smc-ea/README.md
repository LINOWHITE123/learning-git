# GoldSMC — multi timeframe gold expert advisor for MetaTrader 5

An institutional-style MT5 expert advisor for XAUUSD. It reads the market top
down and only trades when the trend, the confirmation timeframe, a fresh area of
interest and the execution trigger all agree:

```
H4  -> primary trend: market structure, swings, BOS, CHoCH
H1  -> confirms H4 + liquidity + premium / discount
M15 -> setup detection: liquidity sweep, BOS/CHoCH, order block / FVG /
        mitigation block -> the zone is stored and armed
M5  -> execution only: price must retrace into the stored zone, print a fresh
        BOS/CHoCH, confirm momentum and pass the spread / volatility gates
        -> structural stop, fixed 1:4 take profit, tiered risk lot size
```

Entries are **never** taken directly from H1 or M15. Every gate has to pass,
there is at most one open position, and there is no averaging, martingale or
grid logic anywhere in the code. All structural decisions are taken on closed
bars, so there is no repainting and no look-ahead bias.

An optional Python service supplies the "market intelligence" layer: a neural
directional model, news / social sentiment and an economic calendar blackout.
The EA runs perfectly well without it — the service can only reduce or veto
trades, never invent them.

---

## Repository layout

| Path | Purpose |
| --- | --- |
| `MQL5/Experts/GoldSMC/GoldSMC_EA.mq5` | The expert advisor |
| `MQL5/Include/GoldSMC/*.mqh` | Structure, zones, risk, news, intel and trade modules |
| `MQL5/Scripts/GoldSMC/ExportBars.mq5` | Exports history to CSV for model training |
| `python/goldsmc_service/` | Sentiment + calendar + neural model service |
| `docs/` | Installation, strategy, risk and backtesting notes |

---

## Install the EA

1. In MetaTrader 5 open **File → Open Data Folder**.
2. Copy `MQL5/Experts/GoldSMC` into `MQL5/Experts/`.
3. Copy `MQL5/Include/GoldSMC` into `MQL5/Include/`.
4. Copy `MQL5/Scripts/GoldSMC` into `MQL5/Scripts/` (optional, for exporting history).
5. In MetaEditor press **F7** on `GoldSMC_EA.mq5` — it must compile with 0 errors.
6. Attach the EA to an **XAUUSD M5** chart (the execution timeframe) and enable
   **Algo Trading**. The EA pulls H4, H1 and M15 data itself.

The EA finds your broker's gold symbol automatically even when it carries a
suffix (`XAUUSD.m`, `XAUUSDpro`, `GOLD#`, …). Set `InpSymbolOverride` if you
want to force one.

Connecting to your broker is the normal MT5 login — the EA trades whatever
account the terminal is logged into. Test on a demo account first.

---

## Risk profiles and account protection

`InpRiskProfile` picks a ladder of per-trade risk that steps **down** as the
balance grows; every band and percentage is configurable, and risk compounds off
`min(balance, equity)`.

| Balance band | Conservative | **Balanced (default)** | Aggressive |
| --- | --- | --- | --- |
| up to $250 | 2.0 % | **10 %** | 25 % |
| $250 – $500 | 1.5 % | **7 %** | 15 % |
| $500 – $1,000 | 1.0 % | **5 %** | 10 % |
| above $1,000 | 0.75 % | **2.5 %** | 5 % |

| Protection | Default |
| --- | --- |
| `InpMaxRiskPercent` (hard ceiling) | 12 % |
| `InpDailyProfitTarget` | 500 — flattens, cancels pendings, resumes next day |
| `InpDailyLossPercent` | 10 % |
| `InpMaxDrawdownPercent` | 25 % (hard halt until restart) |
| `InpMaxPositions` | 1 |
| `InpMaxTradesPerDay` / `InpMaxLossesPerDay` / `InpMaxConsecutiveLoss` | 5 / 3 / 3 |

**About the Aggressive preset.** It is exactly the requested 25/15/10/5 table
and it is one dropdown away, but three consecutive losers at 25 % leave 42 % of
the account — and `InpMaxDrawdownPercent` will halt the EA before compounding
ever gets going. At 1:4 the system only needs to win about **1 trade in 4** to
break even, so the edge comes from the payoff, not from the size of the bet.
See [`docs/RISK.md`](docs/RISK.md) for the full arithmetic.

**About "profitable 9/10 trades".** No code can promise that, and any product
that does is lying. What the EA does instead: it refuses low quality setups
(bias disagreement, mitigated zones, wide stops, high spread, news windows), and
it scales position size with setup quality.

---

## The intelligence service (optional)

```bash
cd python
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

export GOLDSMC_OUTPUT_DIR="/path/to/MetaQuotes/Terminal/Common/Files"
python -m goldsmc_service.service      # serves http://127.0.0.1:8711
```

It publishes one snapshot every 5 minutes:

```json
{"symbol":"XAUUSD","sentiment":0.21,"model_score":-0.08,"confidence":0.44,
 "news_blackout":false,"note":"news=37; bars=1440","timestamp":1754519400}
```

Two transports, pick one in the EA inputs:

* **File** (default, works in the strategy tester): the service writes
  `GoldSMC_intel.json` into `GOLDSMC_OUTPUT_DIR`; set `InpIntelUseHttp=false`.
* **HTTP**: set `InpIntelUseHttp=true` and add `http://127.0.0.1:8711` to
  *Tools → Options → Expert Advisors → Allow WebRequest for listed URL*.

`InpIntelMode` decides what a disagreement means: `FILTER_OFF` ignores the
service, `FILTER_SOFT` halves the position size, `FILTER_STRICT` skips the trade.

### Train the neural model

```bash
# 1. run MQL5/Scripts/GoldSMC/ExportBars.mq5 on an XAUUSD H1 chart
# 2. train on the exported file
python -m goldsmc_service.train --csv data/XAUUSD_H1.csv --out models/goldsmc_mlp.joblib
```

The trainer prints out-of-sample accuracy and AUC from a walk forward split
(never shuffled). If accuracy is below ~0.55 the model has no edge — keep it on
`FILTER_SOFT`, or leave `InpUseIntel=false`.

---

## Economic calendar

`InpUseNewsFilter` blocks new entries in a window around high impact events. The
EA reads the terminal's own calendar when it is available and falls back to
`MQL5/Files/GoldSMC_calendar.csv`, which the Python service keeps up to date —
that fallback is what makes news filtering work in the strategy tester too.

---

## Development

```bash
cd python
pip install -r requirements-dev.txt
pytest -q
ruff check .
```

See [`docs/BACKTESTING.md`](docs/BACKTESTING.md) before going live, and
[`docs/STRATEGY.md`](docs/STRATEGY.md) for exactly how each decision is made.

---

## Disclaimer

Trading leveraged instruments carries a substantial risk of loss. This software
is provided as-is, with no guarantee of profit. Run it on a demo account until
you have your own evidence that it behaves the way you expect.

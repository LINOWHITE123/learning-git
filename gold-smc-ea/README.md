# GoldSMC — multi timeframe gold expert advisor for MetaTrader 5

An MT5 expert advisor for XAUUSD that reads the market top down and only trades
where the higher timeframe, the intermediate timeframe and a fresh area of
interest all agree:

```
H4  -> structural bias (swings, break of structure, EMA)
H1  -> must agree with the H4 bias, otherwise stand aside
M15 -> entry at an unmitigated demand / supply zone or fair value gap
        + candle or micro structure confirmation
        + structural stop, fixed 1:4 take profit, risk based lot size
```

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
6. Attach the EA to an **XAUUSD M15** chart and enable **Algo Trading**.

The EA finds your broker's gold symbol automatically even when it carries a
suffix (`XAUUSD.m`, `XAUUSDpro`, `GOLD#`, …). Set `InpSymbolOverride` if you
want to force one.

Connecting to your broker is the normal MT5 login — the EA trades whatever
account the terminal is logged into. Test on a demo account first.

---

## Risk defaults, and the honest version of the brief

The defaults ship conservative on purpose:

| Setting | Default | Why |
| --- | --- | --- |
| `InpRiskPercent` | 1.0 % | survives a normal losing streak |
| `InpMaxRiskPercent` | 5.0 % | hard ceiling; the sizing code refuses anything above it |
| `InpDailyLossPercent` | 3 % | stops for the rest of the day |
| `InpMaxDrawdownPercent` | 15 % | halts the EA until you restart it |
| `InpMaxTradesPerDay` | 3 | keeps the EA selective |
| `InpMaxLossesPerDay` | 2 | ends the day after two stop-outs |

**About 30 % risk per trade.** The input allows it (raise `InpMaxRiskPercent`
first), but three consecutive losers at 30 % leave 34 % of the account. Even a
system that truly won 90 % of the time hits three losses in a row roughly once
every thousand trades — and no gold strategy wins 90 % of the time. At a 1:4
reward ratio this system only needs to win about **1 trade in 4** to break even,
so the edge comes from the payoff, not from the hit rate.

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

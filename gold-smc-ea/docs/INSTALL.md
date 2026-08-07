# Installation

## A. The expert advisor

1. MetaTrader 5 → **File → Open Data Folder**.
2. Copy from this repository:

```
MQL5/Experts/GoldSMC   ->  <data folder>/MQL5/Experts/GoldSMC
MQL5/Include/GoldSMC   ->  <data folder>/MQL5/Include/GoldSMC
MQL5/Scripts/GoldSMC   ->  <data folder>/MQL5/Scripts/GoldSMC
```

3. Restart MetaEditor, open `GoldSMC_EA.mq5`, press **F7**.
   Expected: `0 errors, 0 warnings`.
4. In the terminal press **Ctrl+N** → *Expert Advisors* → drag **GoldSMC_EA**
   onto an **XAUUSD M15** chart.
5. On the *Common* tab tick **Allow Algo Trading**, and enable the global
   **Algo Trading** button in the toolbar.

The dashboard in the top-left of the chart shows the current bias, live zone
count, risk state and — importantly — the reason the EA is *not* trading.

## B. Connecting to your broker

Nothing EA-specific: **File → Login to Trade Account**, enter the account,
password and the broker's server. The EA trades whichever account the terminal
is connected to, and reads the account balance for sizing.

If your broker's gold symbol is not `XAUUSD`, the EA finds it by prefix
automatically. If it cannot, set `InpSymbolOverride` to the exact Market Watch
name (right click Market Watch → *Symbols* to find it).

## C. The intelligence service (optional)

```bash
cd python
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

Point the service at the terminal's **common** files folder so both the live
terminal and the strategy tester can read it:

```
Windows:  %APPDATA%\MetaQuotes\Terminal\Common\Files
macOS:    ~/Library/Application Support/MetaQuotes/Terminal/Common/Files
```

```bash
export GOLDSMC_OUTPUT_DIR="/full/path/to/Terminal/Common/Files"
export GOLDSMC_SYMBOL=XAUUSD
python -m goldsmc_service.service
```

Then in the EA inputs:

```
InpUseIntel      = true
InpIntelUseHttp  = false               # file transport, works in the tester
InpIntelFile     = GoldSMC_intel.json
InpIntelMode     = FILTER_SOFT
```

For the HTTP transport instead: `InpIntelUseHttp = true`, and add
`http://127.0.0.1:8711` under *Tools → Options → Expert Advisors → Allow
WebRequest for listed URL*.

### Verify it

```bash
curl http://127.0.0.1:8711/health
curl http://127.0.0.1:8711/details
```

The EA dashboard shows `Intel: sent 0.21 model -0.08 conf 0.44` when the link
works, and `Intel: unavailable (...)` with the reason when it does not.

## D. Train the model (optional)

1. Attach `MQL5/Scripts/GoldSMC/ExportBars.mq5` to an XAUUSD **H1** chart
   (`InpCommon = true` writes into the common Files folder).
2. Train:

```bash
python -m goldsmc_service.train \
  --csv "/path/to/Terminal/Common/Files/XAUUSD_PERIOD_H1.csv" \
  --out models/goldsmc_mlp.joblib
```

3. Restart the service. Without a trained model the model score stays neutral
   and only sentiment and the calendar contribute.

## Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `GOLDSMC_SYMBOL` | `XAUUSD` | symbol reported in the snapshot |
| `GOLDSMC_OUTPUT_DIR` | `./out` | where the JSON and calendar CSV are written |
| `GOLDSMC_PORT` | `8711` | HTTP port |
| `GOLDSMC_REFRESH_SECONDS` | `300` | how often the snapshot is rebuilt |
| `GOLDSMC_NEWS_FEEDS` | see `config.py` | comma separated RSS feeds |
| `GOLDSMC_CALENDAR_URL` | ForexFactory weekly JSON mirror | economic calendar source |
| `GOLDSMC_MODEL_PATH` | `./models/goldsmc_mlp.joblib` | trained model |
| `GOLDSMC_PRICE_CSV` | `./data/XAUUSD_H1.csv` | price history for inference |
| `GOLDSMC_SENTIMENT_WEIGHT` | `0.4` | sentiment vs model in the blended score |

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `no trade: higher timeframe has no clear bias` | H4 is ranging — expected, wait |
| `no trade: alignment timeframe disagrees` | H1 against H4 — expected, wait |
| `waiting: price is not at an area of interest` | normal for most bars |
| `position size rejected (risk ceiling or margin)` | minimum lot exceeds your risk; raise `InpRiskPercent` or use a cent account |
| `Intel: unavailable (WebRequest failed...)` | URL not allowed in Options, or the service is not running |
| No trades at all in the tester | check the model is *Every tick*, and that `InpUseSessionFilter` hours match your broker's server time |

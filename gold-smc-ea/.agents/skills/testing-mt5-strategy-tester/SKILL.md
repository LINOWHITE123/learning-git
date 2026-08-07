---
name: testing-mt5-strategy-tester
description: How to run and verify the GoldSMC MQL5 Expert Advisor end-to-end in the MetaTrader 5 Strategy Tester under Wine on Linux, including demo-account setup, XAUUSD history warm-up, tester configuration, and where to find trade-level evidence.
---

# Testing GoldSMC in the MT5 Strategy Tester (Wine / Linux)

MT5 is a Windows desktop app; there is no web UI. Drive it with the computer-use tool and
record the session. Everything below was verified on MT5 build 6099 under Wine.

## Devin Secrets Needed

None. A MetaQuotes-Demo account can be created inside the terminal without any credential.
Do not guess broker credentials — if a real broker login is ever required, escalate.

## Launching

```bash
WINEPREFIX=/home/ubuntu/.winemt5 wine "/home/ubuntu/.winemt5/drive_c/Program Files/MetaTrader 5/terminal64.exe" &
```

Maximize before recording: `wmctrl -r :ACTIVE: -b add,maximized_vert,maximized_horz`.
Do not use xdotool Super+key — it half-tiles.

## Account and data prerequisites

1. If the terminal is not connected, use **File → Open an Account** and pick
   *MetaQuotes-Demo*. The registration form's date-of-birth field is segmented
   (day/month/year sub-fields) — click each sub-field separately rather than typing a whole
   date string. Demo data is sufficient for backtesting.
2. Add the gold symbol to Market Watch and **open a chart on it at M15** before touching the
   tester. Without warming the chart, history may be missing and the tester can report poor
   history quality. On MetaQuotes-Demo the symbol is plain `XAUUSD` ("Gold vs US Dollar") —
   no suffix resolution was needed, but other brokers may use `XAUUSD.m`, `GOLD`, etc., and
   the EA resolves suffixes itself.
3. Contract terms matter for risk math. Read them from Market Watch → **Details** tab
   (Tick Size / Tick Value). On MetaQuotes-Demo XAUUSD: tick size 0.01, tick value 0.1,
   i.e. **$10 per lot per $1 of price movement**. Use this to recompute
   `lots × stop_distance × 10` and check it against the EA's logged `risk=` value.

## Tester configuration

Strategy Tester panel → **Settings** tab:
- Expert: `GoldSMC\GoldSMC_EA.ex5` (compile first with `metaeditor64.exe /compile:...`).
- Symbol `XAUUSD`, period **M15** (the EA requires M15; other timeframes are not supported).
- Date: choose *Custom period*, then set the two date fields. Each opens a month-grid date
  picker — click the `<` / `>` arrows to change month, then a day cell. Typing into the
  field is unreliable.
- Modelling: try **Every tick** first; with warmed history it works and reports 100% quality.
- Deposit 10000 USD, leverage 1:100.
- `Start` button is at the far right of the tester tab strip.

**Inputs** tab: double-click a row's Value cell, `ctrl+a`, type the new value, `Enter`.
Always zoom in on the Inputs table afterwards to prove only the intended input changed —
this is the key evidence for any single-variable isolation run.

## Where the evidence is

- **Journal** tab is the primary evidence source. The EA logs one line per fill:
  `[GoldSMC][INFO] opened BUY 0.41 lots @ 4463.36 sl=4447.00 tp=4528.79 risk=67.06 rr=4.0 | <reason> quality=0.68`
  This single line proves the R:R ratio, lot size, money risk and setup quality at once.
- The tester panel's **Backtest** tab holds the summary statistics; scrolling down leads to
  MFE/MAE/holding-time charts, **not** a per-deal grid. In this build the per-deal table was
  not reachable in the docked panel, so verify trade-level assertions (R:R, sizing,
  concurrency, per-day counts) from the Journal instead.
- **Graph** tab shows the equity curve — the fastest way to spot the EA halting early.
- Journals are also on disk, UTF-16LE encoded, which is far easier to analyse than the GUI:
  ```bash
  iconv -f UTF-16LE -t UTF-8 "/home/ubuntu/.winemt5/drive_c/Program Files/MetaTrader 5/Tester/Agent-127.0.0.1-3000/logs/<YYYYMMDD>.log" | tr -d '\r'
  ```
  All runs of a day append to the same file — split on `testing of Experts` to isolate the
  run you care about. Parse `deal performed [#N buy|sell <vol> ...]` lines and accumulate
  signed volume to prove max concurrency; group `opened` lines by date for per-day limits.
  Use the shell for this arithmetic, and the GUI for the visual demonstration.

## Gotchas

- **A flat equity curve part-way through the window usually is not a bug.** GoldSMC halts
  itself when `InpMaxDrawdownPercent` is breached (also `InpDailyLossPercent`,
  `InpMaxLossesPerDay`). Confirm by re-running with only the drawdown input raised (e.g.
  15 → 50) and checking that trading resumes; then restore the default.
- If a run produces zero trades, re-run in **visual mode** and read the dashboard's
  `Status:` line — the EA names the exact blocking gate ("no trade: higher timeframe has no
  clear bias", "waiting: no candle confirmation in the zone", "no trade: news blackout ...",
  "no trade: max concurrent positions", ...). That string identifies the gate immediately;
  do not guess from the statistics.
- The news filter (`InpUseNewsFilter=true`) did **not** block the tester run here, but the
  terminal calendar can be unavailable under Wine. If a news blackout is the reported
  blocker, set `InpUseNewsFilter=false` and report that you had to.
- Trade counts in the statistics exceed the number of entries because the EA books partial
  closes and break-even moves as separate deals. Count `opened ` journal lines for entries.
- `InpScaleRiskByQuality=true` by default, so realised risk is `balance × InpRiskPercent% ×
  quality` and will be *below* the nominal 1%. Do not flag that as a sizing bug.
- Visual mode is slow; use it only for a short window to capture the dashboard, and run the
  full multi-month test non-visually.

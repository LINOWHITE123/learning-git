# AI Chart Scanner

Upload a screenshot of a chart (MT5, TradingView, anything) and get one structured analysis back:
signal, confidence, entry / stop loss / TP1 / TP2, invalidation, risk:reward, market structure, liquidity,
support & resistance, and a summary of what is actually visible.

**This is not a trading bot.** No broker connection, no EA, no order placement, no live prices and no live news —
it only reads the images you upload.

## Flow

1. **Upload** 1-3 screenshots (PNG, JPG, JPEG, WebP, or iPhone HEIC — transcoded to PNG server-side). Typically H4 + H1 + M15; the timeframe of each image is
   detected from the chart itself (filename hints and manual labels are optional).
2. **Scan chart** — the vision model returns a per-screenshot read plus one combined plan.
3. **Result** — reference-style card with the signal, confluence factors, warnings, and a detail card per screenshot.

## Decision rules (enforced server side in `app/analyzer.py`)

- **H4 → H1 → M15.** H4 sets direction, H1 confirms, M15 holds the setup. Any provided timeframe that disagrees with
  the signal forces `WAIT`.
- **Risk:reward** is recomputed from entry/stop/TP1; below `MIN_RISK_REWARD` (default 2.0) → `WAIT`.
- **Level sanity**: long needs stop < entry < targets, short the reverse; otherwise → `WAIT`.
- **Confidence** below 65 → `WAIT`. Bands: 85-100 very strong, 75-84 strong, 65-74 moderate, <65 weak.
- **Image quality**: an unusable screenshot → `WAIT` plus "Unable to reliably analyze this screenshot."
- **Warnings** are always added for missing higher timeframes, approximate levels and the absence of news data.

Anything the model cannot see is reported as `Not visible in screenshot.` rather than guessed.

## Run

```bash
cd ai-chart-scanner
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn app.main:app --port 8000
```

Then open http://localhost:8000.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `VISION_PROVIDER` | auto | `openai`, `anthropic` or `demo` |
| `OPENAI_API_KEY` | — | enables the OpenAI vision backend |
| `OPENAI_MODEL` | `gpt-4o` | OpenAI model id |
| `ANTHROPIC_API_KEY` | — | enables the Claude vision backend |
| `ANTHROPIC_MODEL` | `claude-sonnet-4-20250514` | Anthropic model id |
| `MIN_RISK_REWARD` | `2.0` | minimum R:R before a setup is downgraded to `WAIT` |

With no key configured the app runs in **demo mode**: deterministic synthetic output, clearly flagged in the summary
and warnings, so the UI and the rule engine can be exercised without API credits. It does not read your chart in
that mode.

## API

- `POST /api/scan` — multipart: `files` (1-3 images), optional `symbol`, `entry_timeframe`, `timeframes`
  (comma-separated hints in file order), `notes`. Returns the `ScanResult` model from `app/models.py`.
- `GET /api/health` — active provider, demo-mode flag, thresholds.

## Tests

```bash
cd ai-chart-scanner
.venv/bin/ruff check .
.venv/bin/python -m pytest
```

The confidence score is an analytical confluence score, not a probability of winning. Verify every level yourself —
this is not financial advice.

## Deploy to a public URL

`render.yaml` is a Render blueprint. In Render: New → Blueprint → pick this repo,
then paste `OPENAI_API_KEY` when prompted (it is not stored in the repo).
The service starts with `uvicorn app.main:app --host 0.0.0.0 --port $PORT`.

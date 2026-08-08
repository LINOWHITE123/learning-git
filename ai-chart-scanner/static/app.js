const form = document.getElementById("scan-form");
const drop = document.getElementById("drop");
const filesInput = document.getElementById("files");
const thumbs = document.getElementById("thumbs");
const errorBox = document.getElementById("error");
const resultBox = document.getElementById("result");
const progressBox = document.getElementById("progress");
const scanButton = document.getElementById("scan");
const providerLine = document.getElementById("provider");

const STAGES = [
  "Analyzing chart...",
  "Reading market structure...",
  "Detecting liquidity...",
  "Analyzing support/resistance...",
  "Calculating setup...",
];

let selected = [];
let maxImages = 3;
let stageTimer = null;

fetch("/api/health")
  .then((response) => response.json())
  .then((health) => {
    maxImages = health.max_images || 3;
    providerLine.textContent = health.demo_mode
      ? `Demo mode (no vision model configured): results are synthetic placeholders, not a read of your screenshot. Set OPENAI_API_KEY or ANTHROPIC_API_KEY.`
      : `Model: ${health.provider} · minimum R:R 1:${health.min_risk_reward} · minimum confidence ${health.min_confidence}%`;
    providerLine.classList.toggle("warn-line", Boolean(health.demo_mode));
  })
  .catch(() => {
    providerLine.textContent = "";
  });

["dragenter", "dragover"].forEach((event) =>
  drop.addEventListener(event, (e) => {
    e.preventDefault();
    drop.classList.add("over");
  })
);
["dragleave", "drop"].forEach((event) =>
  drop.addEventListener(event, (e) => {
    e.preventDefault();
    drop.classList.remove("over");
  })
);
drop.addEventListener("drop", (e) => setFiles(Array.from(e.dataTransfer.files)));
filesInput.addEventListener("change", () => setFiles(Array.from(filesInput.files)));

function guessTimeframe(name) {
  const match = /(m|h)?\s*(\d{1,3})\s*(m|min|h|hour)?/i.exec(name || "");
  if (!match) return "";
  const unit = (match[3] || match[1] || "").toLowerCase();
  const number = Number(match[2]);
  if (unit.startsWith("h")) return `H${number}`;
  if (unit.startsWith("m")) return number % 60 === 0 ? `H${number / 60}` : `M${number}`;
  if (number === 240) return "H4";
  if (number === 60) return "H1";
  return `M${number}`;
}

const IMAGE_NAME = /\.(png|jpe?g|webp|heic|heif)$/i;

function looksLikeImage(file) {
  return file.type.startsWith("image/") || IMAGE_NAME.test(file.name || "");
}

function setFiles(files) {
  const rejected = files.filter((file) => !looksLikeImage(file));
  selected = files.filter(looksLikeImage).slice(0, maxImages);
  errorBox.hidden = true;
  if (rejected.length) {
    showError(`Skipped ${rejected.map((file) => file.name).join(", ")} — not an image file.`);
  }
  thumbs.innerHTML = "";
  selected.forEach((file) => {
    const wrapper = document.createElement("div");
    wrapper.className = "thumb";
    const img = document.createElement("img");
    img.src = URL.createObjectURL(file);
    img.alt = file.name;
    // Browsers that cannot render HEIC still upload it fine, so show the name instead of a broken image.
    img.addEventListener("error", () => {
      img.replaceWith(Object.assign(document.createElement("span"), { className: "no-preview", textContent: file.name }));
    });
    const label = document.createElement("input");
    label.type = "text";
    label.placeholder = "auto-detected";
    label.value = guessTimeframe(file.name);
    wrapper.append(img, label);
    thumbs.append(wrapper);
  });
}

function startStages() {
  progressBox.hidden = false;
  progressBox.innerHTML = "";
  let index = 0;
  const tick = () => {
    if (index >= STAGES.length) return;
    const item = document.createElement("li");
    item.textContent = STAGES[index];
    progressBox.append(item);
    index += 1;
    stageTimer = window.setTimeout(tick, 1200);
  };
  tick();
}

function stopStages() {
  window.clearTimeout(stageTimer);
  progressBox.hidden = true;
  progressBox.innerHTML = "";
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  errorBox.hidden = true;
  // Some mobile browsers never fire `change`, so fall back to whatever the input itself holds.
  const files = selected.length ? selected : Array.from(filesInput.files || []).slice(0, maxImages);
  if (files.length === 0) {
    showError("Choose at least one chart screenshot (PNG, JPG, JPEG, WebP or HEIC).");
    return;
  }

  const body = new FormData();
  files.forEach((file) => body.append("files", file));
  const labels = Array.from(thumbs.querySelectorAll("input")).map((input) => input.value.trim());
  body.append("timeframes", labels.length === files.length ? labels.join(",") : "");
  body.append("symbol", document.getElementById("symbol").value.trim());
  body.append("entry_timeframe", document.getElementById("entry-tf").value.trim() || "M15");
  body.append("notes", document.getElementById("notes").value.trim());

  scanButton.disabled = true;
  scanButton.textContent = "SCANNING…";
  resultBox.hidden = true;
  startStages();
  try {
    const response = await fetch("/api/scan", { method: "POST", body });
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.detail || "Scan failed.");
    render(payload);
  } catch (error) {
    resultBox.hidden = true;
    showError(error.message);
  } finally {
    stopStages();
    scanButton.disabled = false;
    scanButton.textContent = "SCAN CHART";
  }
});

function showError(message) {
  errorBox.textContent = message;
  errorBox.hidden = false;
}

const SIGNALS = { long: "LONG", short: "SHORT", wait: "WAIT" };
const BANDS = { very_strong: "Very Strong", strong: "Strong", moderate: "Moderate", weak: "Weak" };
const NOT_VISIBLE = "Not visible in screenshot.";

function esc(value) {
  if (value === null || value === undefined) return "";
  return String(value).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
}

function label(value) {
  if (value === null || value === undefined || value === "") return "—";
  return esc(String(value).replace(/_/g, " ").toUpperCase());
}

function num(value) {
  if (typeof value !== "number") return "—";
  return value.toLocaleString(undefined, { maximumFractionDigits: 5 });
}

function zones(list) {
  if (!list || list.length === 0) return NOT_VISIBLE;
  return list
    .map((zone) => {
      const range = zone.high && zone.high !== zone.low ? `${num(zone.low)}–${num(zone.high)}` : num(zone.low);
      const tag = zone.approximate ? "≈" : "";
      return `${tag}${range}${zone.label ? ` (${esc(zone.label)})` : ""}`;
    })
    .join(", ");
}

function chip(name, value) {
  return `<div class="insight"><span>${esc(name)}</span><strong class="${esc(value)}">${label(value)}</strong></div>`;
}

function render(result) {
  const setup = result.setup;
  const tradeable = result.signal !== "wait" && setup;
  const parts = [];

  parts.push(`<section class="card">
    <div class="head">
      <div>
        <h2>${esc(result.symbol) || NOT_VISIBLE} — ${esc(result.primary_timeframe) || "—"}</h2>
        <p class="tag">TECHNICAL · AI PLAN</p>
      </div>
      <div class="score">
        <span class="signal ${esc(result.signal)}">${SIGNALS[result.signal] || label(result.signal)}</span>
        <span class="conf">Confidence: ${result.confidence}% · ${BANDS[result.confidence_band] || ""}</span>
      </div>
    </div>`);

  if (Object.keys(result.alignment || {}).length) {
    const rows = Object.entries(result.alignment)
      .map(([tf, bias]) => `<div class="tf"><b>${esc(tf)}</b><span class="${esc(bias)}">${label(bias)}</span></div>`)
      .join("");
    parts.push(`<div class="block"><h3>Timeframe Alignment</h3><div class="tf-list">${rows}</div>
      <p class="note">${esc(result.alignment_note)}</p></div>`);
  }

  if (tradeable) {
    const approx = setup.levels_approximate ? "≈" : "";
    parts.push(`<div class="block"><h3>Trade Setup</h3><dl class="rows">
      <dt>Entry</dt><dd>${approx}${num(setup.entry)}${setup.entry_note ? ` <small>${esc(setup.entry_note)}</small>` : ""}</dd>
      <dt>Stop Loss</dt><dd class="stop">${approx}${num(setup.stop_loss)}</dd>
      <dt>Take Profit 1</dt><dd class="tp">${approx}${num(setup.take_profit_1)}</dd>
      <dt>Take Profit 2</dt><dd class="tp">${setup.take_profit_2 ? approx + num(setup.take_profit_2) : "—"}</dd>
      <dt>Risk : Reward</dt><dd>1 : ${setup.risk_reward ?? "—"}</dd>
      <dt>Invalidation</dt><dd>${setup.invalidation ? approx + num(setup.invalidation) : "—"}
        ${setup.invalidation_note ? `<small>${esc(setup.invalidation_note)}</small>` : ""}</dd>
    </dl></div>`);
  } else {
    parts.push(`<div class="block"><h3>Trade Setup</h3>
      <p class="note">No setup meets the criteria on these screenshots — signal is WAIT.</p></div>`);
  }

  parts.push(`<div class="block"><h3>Insights</h3><div class="insights">
    ${chip("Trend", result.trend)}
    ${chip("Momentum", result.momentum)}
    ${chip("Volatility", result.volatility)}
    ${chip("Structure", result.structure)}
    ${chip("Liquidity", result.liquidity)}
    ${chip("Sentiment", result.sentiment)}
  </div></div>`);

  const active = Object.entries(result.factors || {}).filter(([, on]) => on);
  if (active.length) {
    parts.push(`<div class="block"><h3>Confluence</h3><p class="factors">${active
      .map(([name]) => `<span>${esc(name.replace(/_/g, " "))}</span>`)
      .join("")}</p></div>`);
  }

  parts.push(`<div class="block"><h3>Summary</h3><p class="summary">${esc(result.summary) || NOT_VISIBLE}</p></div>`);

  if (result.warnings?.length) {
    parts.push(`<div class="block"><h3>Warnings</h3><ul class="warn">${result.warnings
      .map((warning) => `<li>${esc(warning)}</li>`)
      .join("")}</ul></div>`);
  }

  parts.push(`<p class="disclaimer">${esc(result.disclaimer)}</p></section>`);

  (result.charts || []).forEach((chart) => parts.push(chartCard(chart)));

  resultBox.innerHTML = parts.join("");
  resultBox.hidden = false;
  resultBox.scrollIntoView({ behavior: "smooth", block: "start" });
}

function chartCard(chart) {
  const quality = chart.quality || {};
  const flags = [
    ["symbol", quality.symbol_visible],
    ["timeframe", quality.timeframe_visible],
    ["price scale", quality.price_scale_visible],
    ["candles", quality.candles_visible],
  ]
    .map(([name, ok]) => `<span class="${ok ? "ok" : "no"}">${esc(name)}</span>`)
    .join("");

  return `<section class="card sub-card">
    <div class="head">
      <h2>${esc(chart.timeframe) || "—"} · ${esc(chart.symbol) || NOT_VISIBLE}</h2>
      <span class="conf">${esc(chart.source)}</span>
    </div>
    <dl class="rows">
      <dt>Current price</dt><dd>${num(chart.current_price)}</dd>
      <dt>Trend / momentum</dt><dd>${label(chart.trend)} · ${label(chart.momentum)}</dd>
      <dt>Structure</dt><dd>${label(chart.structure)} <small>${esc((chart.structure_events || []).join(", "))}</small></dd>
      <dt>Structure note</dt><dd class="plain">${esc(chart.structure_note) || NOT_VISIBLE}</dd>
      <dt>Swing highs</dt><dd>${(chart.swing_highs || []).map(num).join(", ") || NOT_VISIBLE}</dd>
      <dt>Swing lows</dt><dd>${(chart.swing_lows || []).map(num).join(", ") || NOT_VISIBLE}</dd>
      <dt>Resistance</dt><dd>${zones(chart.resistance)}</dd>
      <dt>Support</dt><dd>${zones(chart.support)}</dd>
      <dt>Supply zones</dt><dd>${zones(chart.supply_zones)}</dd>
      <dt>Demand zones</dt><dd>${zones(chart.demand_zones)}</dd>
      <dt>Order blocks</dt><dd>${zones(chart.order_blocks)}</dd>
      <dt>Fair value gaps</dt><dd>${zones(chart.fair_value_gaps)}</dd>
      <dt>Breakout / retest</dt><dd>${zones(chart.breakout_levels)} | ${zones(chart.retest_levels)}</dd>
      <dt>Liquidity</dt><dd>${label(chart.liquidity)} <small>${esc(chart.liquidity_note)}</small></dd>
      <dt>Volume</dt><dd>${label(chart.volume)} <small>${esc(chart.volume_note)}</small></dd>
      <dt>Indicators</dt><dd class="plain">${esc((chart.indicators || []).join(", ")) || NOT_VISIBLE}</dd>
      <dt>Moving averages</dt><dd class="plain">${esc(chart.moving_averages) || NOT_VISIBLE}</dd>
      <dt>RSI</dt><dd class="plain">${esc(chart.rsi) || NOT_VISIBLE}</dd>
      <dt>MACD</dt><dd class="plain">${esc(chart.macd) || NOT_VISIBLE}</dd>
      <dt>Patterns</dt><dd class="plain">${esc((chart.patterns || []).join(", ")) || NOT_VISIBLE}</dd>
      <dt>Price action</dt><dd class="plain">${esc(chart.price_action) || NOT_VISIBLE}</dd>
    </dl>
    <p class="quality">Readable: ${flags}${quality.usable === false ? '<span class="no">unusable image</span>' : ""}</p>
    ${(quality.issues || []).length ? `<ul class="warn">${quality.issues.map((i) => `<li>${esc(i)}</li>`).join("")}</ul>` : ""}
  </section>`;
}

// Dashboard entry point (ES module, loaded from <head>).
//
// Owns the small amount of client state and the refresh loop, then renders the Preact <App>.
// Data comes from GET /api/state (the server builds it; see views.build_state); the client
// holds only *UI* state that must survive data refreshes — selected range, table sort, and
// the simple/advanced view — plus the latest data snapshot and connection status.

import { App } from "./components.mjs";
import { normalizeAvgWindow, normalizeSeries, normalizeTheme } from "./logic.mjs";
import { html, render } from "./preact.mjs";

const root = document.getElementById("app");
const REFRESH_MS = 30000;
// Abort a poll that hasn't answered before the next tick would fire. Without this a hung
// connection (a dropped Tor circuit hangs rather than fails) never rejects, and the `inflight`
// guard then blocks every later tick — the page freezes on stale data with no banner (#382).
// Sized just under REFRESH_MS: far above a healthy Tor round-trip, so it only trips on dead links.
const FETCH_TIMEOUT_MS = 25000;

// A manual-zoom window {from, to} (epoch seconds) read from ?from=&to= so a zoomed URL is
// shareable and survives reload (Issue #47); null/garbage falls back to the preset range.
function windowFromUrl() {
  const p = new URL(location.href).searchParams;
  const from = parseFloat(p.get("from"));
  const to = parseFloat(p.get("to"));
  return Number.isFinite(from) && Number.isFinite(to) && from > 0 && to > from
    ? { from, to }
    : null;
}

// Which chart series are shown — persisted so a hidden series stays hidden across reloads.
function loadSeries() {
  try {
    return normalizeSeries(JSON.parse(localStorage.getItem("dashboardSeries")));
  } catch {
    return normalizeSeries(null);
  }
}

const ui = {
  range: new URL(location.href).searchParams.get("range") || "all",
  window: windowFromUrl(), // {from,to} epoch-s when zoomed, else null
  series: loadSeries(), // {p2pool, xvb, shares} booleans (Issue #47)
  // Hashrate-averaging window the chart plots (#168); persisted, default 10m (today's series).
  avg: normalizeAvgWindow(localStorage.getItem("dashboardAvgWindow")),
  sortIndex: null,
  sortAsc: true,
  view: localStorage.getItem("dashboardView") === "advanced" ? "advanced" : "simple",
  // Theme is persisted in localStorage so it survives reloads and stack restarts (Issue #43).
  // theme-init.js already applied it to <html> before first paint; we mirror it into the UI
  // state and re-apply on toggle.
  theme: normalizeTheme(localStorage.getItem("dashboardTheme")),
};

// Reflect the current theme onto <html data-theme>; the CSS palette (and the chart, which reads
// the resolved CSS variables) follow from there.
function applyTheme(theme) {
  document.documentElement.setAttribute("data-theme", theme);
}

let state = null; // latest /api/state payload, or null before the first response
let connected = true; // false after a failed fetch (we keep showing the last snapshot)
let inflight = false; // guard against overlapping fetches if one is slow

function rerender() {
  render(
    html`<${App} state=${state} connected=${connected} ui=${ui}
                     onRange=${setRange} onSort=${onSort} onView=${setView} onTheme=${setTheme}
                     onZoom=${setZoom} onResetZoom=${resetZoom} onToggleSeries=${toggleSeries}
                     onAvgWindow=${setAvgWindow} />`,
    root,
  );
}

async function tick() {
  if (inflight) return;
  inflight = true;
  try {
    // A custom zoom window overrides the preset range; the server adapts resolution to it. The
    // averaging window (#168) applies to both — the server selects which window's columns to plot.
    const base = ui.window
      ? "from=" + ui.window.from + "&to=" + ui.window.to
      : "range=" + encodeURIComponent(ui.range);
    const qs = base + "&avg=" + encodeURIComponent(ui.avg);
    const res = await fetch("/api/state?" + qs, {
      headers: { "X-Requested-With": "fetch" },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!res.ok) throw new Error("HTTP " + res.status);
    state = await res.json();
    connected = true;
    if (state.page_title) document.title = state.page_title;
  } catch (e) {
    connected = false;
    console.warn("dashboard refresh failed", e);
  } finally {
    inflight = false;
    rerender();
  }
}

function setRange(r) {
  ui.range = r;
  ui.window = null; // picking a preset exits any manual zoom
  history.replaceState(null, "", r === "all" ? location.pathname : "?range=" + r);
  tick(); // re-fetch immediately; the chart/series depend on the range
}

// Called (debounced) by the chart when a zoom/pan gesture settles: pin the visible window and
// refetch it from the server at duration-adaptive resolution (Issue #47).
function setZoom(fromS, toS) {
  ui.window = { from: fromS, to: toS };
  history.replaceState(null, "", "?from=" + Math.round(fromS) + "&to=" + Math.round(toS));
  tick();
}

function resetZoom() {
  ui.window = null;
  history.replaceState(null, "", ui.range === "all" ? location.pathname : "?range=" + ui.range);
  tick();
}

function onSort(idx) {
  ui.sortAsc = ui.sortIndex === idx ? !ui.sortAsc : true;
  ui.sortIndex = idx;
  rerender(); // client-side sort only, no fetch
}

function setView(mode) {
  ui.view = mode;
  localStorage.setItem("dashboardView", mode);
  rerender();
}

function setTheme(theme) {
  ui.theme = theme;
  localStorage.setItem("dashboardTheme", theme);
  applyTheme(theme); // updates <html data-theme>; the chart recolours on the next render
  rerender();
}

function toggleSeries(key) {
  ui.series = { ...ui.series, [key]: !ui.series[key] };
  localStorage.setItem("dashboardSeries", JSON.stringify(ui.series));
  rerender(); // visibility-only; the chart hides/shows the dataset, no refetch needed
}

// Pick the chart's hashrate-averaging window (#168). Persist it and refetch — the server returns a
// different per-window series, so (unlike series visibility) this needs a round-trip.
function setAvgWindow(w) {
  ui.avg = normalizeAvgWindow(w);
  localStorage.setItem("dashboardAvgWindow", ui.avg);
  tick();
}

applyTheme(ui.theme); // re-assert the (normalized) theme before the first paint
rerender(); // paint the loading shell immediately
tick(); // first data load
setInterval(tick, REFRESH_MS); // then live updates

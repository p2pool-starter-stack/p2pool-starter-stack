// The hashrate chart. A Preact class component wraps the Chart.js instance imperatively:
// Preact owns the card markup (range buttons + <canvas>), while Chart.js owns the canvas
// pixels. The instance is created on mount and updated in place on each data tick, so it
// survives re-renders (scroll/zoom/animation state intact). It only mounts in the operational
// view, so the canvas is never built into a hidden/zero-size element during Sync Mode.
//
// Points carry their real timestamp as the x value (epoch ms) on a linear scale, so time is to
// scale and outages render as proportional gaps (Issue #65) — a linear scale (not Chart.js's
// `time` scale) avoids vendoring a date-adapter library. The server inserts {x, y: null} break
// markers across outages so the line/fill doesn't span them.
//
// P2Pool and XvB are drawn as a STACKED area (Issue #47): at every sample the full hashrate
// goes to exactly one pool, so the two series sum to the total — stacking shows the total as the
// top edge with a clean blue/purple split, instead of two muddy overlapping fills. The Shares
// scatter is kept on its own stack group so its y stays absolute. Zoom/pan (chartjs-plugin-zoom)
// gestures hand the visible window up via onZoom, which refetches that window from the server at
// duration-adaptive resolution — so zooming in reveals finer data.

import { bandBorderWidth, clampZoomWindow, fmtHashrate, fmtTimestamp } from "./logic.mjs";
import { Component, createRef, html } from "./preact.mjs";

const RANGES = [
  ["1h", "1 Hr"],
  ["24h", "24 Hr"],
  ["1w", "1 Wk"],
  ["1m", "1 Mo"],
  ["all", "All"],
];

// Hashrate-averaging windows for the chart toggle (#168): [param key, button label]. The keys match
// the server's `avg` param; labels are spelled out so the "1m" window (1 MINUTE) isn't mistaken for
// the "1 Mo" RANGE above. Persisted in dashboard.js ui.avg (localStorage), default 10m. 12h/24h read
// low until a rig has been online that long — flagged via the button title so it doesn't look broken.
const WINDOWS = [
  ["1m", "1 Min"],
  ["10m", "10 Min"],
  ["1h", "1 Hr"],
  ["12h", "12 Hr"],
  ["24h", "24 Hr"],
];
const WINDOW_HINT = {
  "12h": "Average over the last 12 hours — needs ~12h of rig uptime to fully fill",
  "24h": "Average over the last 24 hours — needs ~24h of rig uptime to fully fill",
};

// Series the user can show/hide (Issue #47): dataset index, label and swatch colour class.
// Visibility lives in dashboard.js ui.series (persisted); applied to the chart in applyVisibility.
const SERIES = [
  { key: "p2pool", label: "P2Pool (routed)", idx: 0, dot: "dot-p2pool" },
  { key: "xvb", label: "XvB (routed)", idx: 1, dot: "dot-xvb" },
  { key: "shares", label: "Shares", idx: 2, dot: "dot-shares" },
];

// Smallest zoom window (ms) — guards against requesting a sub-sample slice (30s native cadence).
const MIN_ZOOM_MS = 60000;
// Coalesce a flurry of wheel/pan events into one refetch.
const ZOOM_DEBOUNCE_MS = 300;

// Register the zoom/pan plugin once (UMD global from chartjs-plugin-zoom.min.js; see index.html).
// Guarded so the module is harmless if the global is absent (e.g. outside the browser).
if (typeof Chart !== "undefined" && typeof window !== "undefined" && window.ChartZoom) {
  Chart.register(window.ChartZoom);
}

// Append an 8-bit alpha to a #rrggbb hex (Chart.js accepts #rrggbbaa). Non-hex values pass
// through opaque, so a future palette change can't break the fills.
export const withAlpha = (hex, aa) => (/^#[0-9a-fA-F]{6}$/.test(hex) ? hex + aa : hex);

// The chart's colours, read from the active theme's CSS variables (Issue #43) so the chart
// matches light/dark/auto. Re-read on every sync() so a theme switch recolours it in place.
function paletteColors() {
  const cs = getComputedStyle(document.documentElement);
  const v = (name, fallback) => cs.getPropertyValue(name).trim() || fallback;
  const accent = v("--accent", "#58a6ff");
  const purple = v("--purple", "#a371f7");
  return {
    accent,
    purple,
    shares: v("--bad", "#da3633"),
    evtLoss: v("--warn", "#d29922"), // degradation event marker (#99)
    evtOk: v("--ok", "#3fb950"), // recovery event marker
    raffleWin: v("--warn", "#d29922"), // XvB raffle-win star — the warn gold reads as gold here
    grid: v("--border", "#30363d"),
    ticks: v("--text-muted", "#8b949e"),
    band: withAlpha(accent, "26"), // drag-to-zoom selection band (≈ 0.15 alpha)
  };
}

// Per-point colour for the degradation event markers (#99): green for a recovery, warn/red for a
// loss. Returns one colour per point so a single dataset can show both.
export function eventColors(events, c) {
  return (events || []).map((e) => (e.kind === "hashrate_recovered" ? c.evtOk : c.evtLoss));
}

// Area-fill gradient stops (Issue #145): strong near the line, fading toward the axis, so a flat
// series reads as a solid mass instead of a thin strip. Line a touch thicker than the default so
// the top edge pops against the fill.
const FILL_TOP = "59"; // ≈ 0.35 alpha at the line
const FILL_BOTTOM = "0d"; // ≈ 0.05 alpha at the axis
const AREA_BORDER_WIDTH = 3.5;

// A vertical gradient fill for a stacked area, keyed to the live chart area (pixels, not data) so
// it spans the visible card regardless of the y-range. Scriptable: re-evaluated on resize/zoom.
// Before the first layout `chartArea` is undefined, so fall back to the flat top tint.
function areaFill(baseHex) {
  return (ctx) => {
    const area = ctx.chart.chartArea;
    if (!area) return withAlpha(baseHex, FILL_TOP);
    const g = ctx.chart.ctx.createLinearGradient(0, area.top, 0, area.bottom);
    g.addColorStop(0, withAlpha(baseHex, FILL_TOP));
    g.addColorStop(1, withAlpha(baseHex, FILL_BOTTOM));
    return g;
  };
}

// Pad the auto-fitted y-range so a near-flat line fills the card instead of hugging the bottom
// (Issue #145). Pads by a fraction of the visible span, with a floor tied to the magnitude so a
// dead-flat series isn't magnified into pure noise; never drops below zero.
export function padYAxis(scale) {
  const { min, max } = scale;
  if (!Number.isFinite(min) || !Number.isFinite(max)) return; // all series hidden / no data
  const pad = Math.max((max - min) * 0.2, max * 0.03);
  scale.min = Math.max(0, min - pad);
  scale.max = max + pad;
}

export class ChartCard extends Component {
  constructor(props) {
    super(props);
    this.canvasRef = createRef();
    this.shareCounts = [];
    this.applyingServerData = false; // suppress the gesture handler during programmatic resetZoom
    this._zoomDebounce = null;
    this._prevWindow = props.window; // track window prop to detect the zoomed -> preset transition
  }

  componentDidMount() {
    this.create();
  }
  componentDidUpdate() {
    this.sync();
  }
  componentWillUnmount() {
    clearTimeout(this._zoomDebounce);
    if (this.chart) {
      this.chart.destroy();
      this.chart = null;
    }
  }

  // Debounced: a gesture (wheel/drag-zoom/pan) settled — hand the visible window up to refetch
  // it from the server at the right resolution. Ignored while we're programmatically resetting.
  onGesture() {
    if (this.applyingServerData) return;
    clearTimeout(this._zoomDebounce);
    this._zoomDebounce = setTimeout(() => {
      if (!this.chart) return;
      const x = this.chart.scales.x;
      const w = clampZoomWindow(x.min, x.max, MIN_ZOOM_MS);
      if (w) this.props.onZoom(w.from / 1000, w.to / 1000); // epoch ms -> seconds
    }, ZOOM_DEBOUNCE_MS);
  }

  create() {
    const canvas = this.canvasRef.current;
    if (!canvas || typeof Chart === "undefined") return;
    const d = this.props.chart;
    this.shareCounts = d.shares.map((s) => s.c);
    const c = paletteColors();
    const tension = d.tension ?? 0.3;
    const vis = this.props.series || {}; // persisted show/hide state (Issue #47)
    const self = this;
    this.chart = new Chart(canvas, {
      type: "line",
      data: {
        datasets: [
          // segment.borderWidth hides each band's top border-line where the band is flat-zero,
          // so an all-to-one-pool window reads as a single solid color instead of the empty
          // series painting its edge line over the other's (#184). The upper (XvB) band fills
          // down to the series below it (fill: '-1'), NOT to origin — otherwise its
          // semi-transparent purple is painted all the way to zero over the blue P2Pool fill,
          // tinting an all-P2Pool window (XvB ≈ 0) lavender instead of leaving it blue.
          {
            label: "P2Pool (routed)",
            data: d.p2pool,
            borderColor: c.accent,
            borderWidth: AREA_BORDER_WIDTH,
            segment: { borderWidth: (ctx) => bandBorderWidth(d.p2pool, ctx, AREA_BORDER_WIDTH) },
            tension,
            fill: true,
            hidden: vis.p2pool === false,
            stack: "hr",
            backgroundColor: areaFill(c.accent),
            pointRadius: 0,
            pointHitRadius: 20,
          },
          {
            label: "XvB (routed)",
            data: d.xvb,
            borderColor: c.purple,
            borderWidth: AREA_BORDER_WIDTH,
            segment: { borderWidth: (ctx) => bandBorderWidth(d.xvb, ctx, AREA_BORDER_WIDTH) },
            tension,
            fill: "-1",
            hidden: vis.xvb === false,
            stack: "hr",
            backgroundColor: areaFill(c.purple),
            pointRadius: 0,
            pointHitRadius: 20,
          },
          // On its own hidden 0–1 axis (yAxisID) so the markers ride near the top edge and
          // never inflate the hashrate y-range (Issue #145).
          {
            label: "Shares",
            data: d.shares,
            borderColor: c.shares,
            backgroundColor: c.shares,
            hidden: vis.shares === false,
            yAxisID: "shares",
            pointStyle: "triangle",
            rotation: 180,
            pointRadius: d.shares.map((s) => s.r),
            pointHoverRadius: 15,
            pointHitRadius: 100,
            showLine: false,
          },
          // Degradation/recovery markers (#99) on their own hidden axis, just below the share rug.
          // A diamond per event, red for a loss and green for a recovery; tooltip carries the label.
          {
            label: "Events",
            data: d.events || [],
            yAxisID: "events",
            pointStyle: "rectRot",
            pointRadius: 7,
            pointHoverRadius: 10,
            pointHitRadius: 100,
            showLine: false,
            pointBackgroundColor: eventColors(d.events, c),
            pointBorderColor: eventColors(d.events, c),
          },
          // XvB raffle wins: a gold star per round this wallet won, on the same hidden 0–1 axis
          // as the event diamonds, one step below them. Tooltip carries tier + credited rate.
          {
            label: "Raffle",
            data: d.raffle || [],
            yAxisID: "events",
            pointStyle: "star",
            pointRadius: 8,
            pointBorderWidth: 2,
            pointHoverRadius: 11,
            pointHitRadius: 100,
            showLine: false,
            pointBackgroundColor: c.raffleWin,
            pointBorderColor: c.raffleWin,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        spanGaps: false, // {x, y: null} break markers split the line across outages
        interaction: { mode: "nearest", axis: "x", intersect: false },
        plugins: {
          legend: { display: false },
          tooltip: {
            callbacks: {
              title(items) {
                return items.length ? fmtTimestamp(items[0].parsed.x) : "";
              },
              label(context) {
                if (context.dataset.label === "Shares")
                  return self.shareCounts[context.dataIndex] + " Shares";
                if (context.dataset.label === "Events" || context.dataset.label === "Raffle")
                  return context.raw.label;
                let label = context.dataset.label || "";
                if (label) label += ": ";
                // Same abbreviated style as the cards/Telegram (#387), e.g. "12.35 kH/s".
                if (context.parsed.y !== null) label += fmtHashrate(context.parsed.y);
                return label;
              },
            },
          },
          // Drag = box-zoom, Ctrl-wheel = zoom, Shift-drag = pan (Issue #47, #533). Each settled
          // gesture triggers a server refetch of the visible window (onGesture).
          // modifierKey gates the wheel: a bare scroll over the canvas passes through to the page
          // (no scroll-hijack, #533); hold Ctrl to zoom. (macOS: only ctrlKey counts, not ⌘/metaKey
          // — but a trackpad pinch synthesizes a ctrl+wheel event, so pinch-to-zoom works for free.)
          zoom: {
            zoom: {
              wheel: { enabled: true, modifierKey: "ctrl" },
              drag: {
                enabled: true,
                backgroundColor: c.band,
                borderColor: c.accent,
                borderWidth: 1,
              },
              mode: "x",
              onZoomComplete: () => self.onGesture(),
            },
            pan: {
              enabled: true,
              mode: "x",
              modifierKey: "shift",
              onPanComplete: () => self.onGesture(),
            },
            limits: { x: { minRange: MIN_ZOOM_MS } },
          },
        },
        scales: {
          // Linear x positions points by real elapsed time (gaps occupy proportional
          // space); axis hidden as before. y is stacked (P2Pool+XvB = total) and
          // grid/ticks follow the theme; padYAxis keeps a flat line off the floor.
          x: { type: "linear", display: false },
          y: {
            stacked: true,
            grid: { color: c.grid },
            ticks: { color: c.ticks },
            afterDataLimits: padYAxis,
          },
          // Hidden 0–1 axis the Shares scatter rides on; markers pin near the top (0.93,
          // set server-side) so they never affect the hashrate y-range (Issue #145).
          shares: { type: "linear", display: false, min: 0, max: 1 },
          // Hidden 0–1 axis the degradation event markers ride on (#99), pinned near the top.
          events: { type: "linear", display: false, min: 0, max: 1 },
        },
      },
    });
  }

  // Apply the persisted show/hide state to the datasets (Issue #47); each defaults to visible.
  // Hiding a stacked series re-stacks the rest (Chart.js excludes hidden datasets from the sum).
  applyVisibility() {
    const vis = this.props.series || {};
    for (const s of SERIES) this.chart.setDatasetVisibility(s.idx, vis[s.key] !== false);
  }

  sync() {
    if (!this.chart) {
      this.create();
      return;
    }
    const d = this.props.chart;
    const c = paletteColors(); // re-read so a theme switch recolours in place
    const tension = d.tension ?? 0.3;
    this.shareCounts = d.shares.map((s) => s.c);
    const ds = this.chart.data.datasets;
    ds[0].data = d.p2pool;
    ds[0].borderColor = c.accent;
    ds[0].backgroundColor = areaFill(c.accent);
    ds[0].tension = tension;
    ds[1].data = d.xvb;
    ds[1].borderColor = c.purple;
    ds[1].backgroundColor = areaFill(c.purple);
    ds[1].tension = tension;
    ds[2].data = d.shares;
    ds[2].borderColor = c.shares;
    ds[2].backgroundColor = c.shares;
    ds[2].pointRadius = d.shares.map((s) => s.r);
    ds[3].data = d.events || [];
    ds[3].pointBackgroundColor = eventColors(d.events, c);
    ds[3].pointBorderColor = eventColors(d.events, c);
    ds[4].data = d.raffle || [];
    ds[4].pointBackgroundColor = c.raffleWin;
    ds[4].pointBorderColor = c.raffleWin;
    this.chart.options.scales.y.grid.color = c.grid;
    this.chart.options.scales.y.ticks.color = c.ticks;
    this.applyVisibility();

    // On the zoomed -> preset transition (Reset or picking a preset clears the window), drop
    // any stale plugin zoom transform so the axis re-fits the new preset data. Keyed to the
    // transition (not merely "window is null") so a refresh mid-gesture can't clobber an
    // in-progress zoom before its debounce fires.
    const justCleared = this._prevWindow && !this.props.window;
    this._prevWindow = this.props.window;
    if (justCleared && this.chart.isZoomedOrPanned && this.chart.isZoomedOrPanned()) {
      this.applyingServerData = true;
      this.chart.resetZoom("none");
      this.applyingServerData = false;
    }
    this.chart.update();
    this.chart.resize();
  }

  render(props) {
    const zoomed = !!props.window;
    return html`
        <div class="card">
            <div class="chart-controls">
                <span class="text-muted text-small mr-1">Range:</span>
                ${RANGES.map(
                  ([r, label]) => html`<a href=${"?range=" + r}
                    class=${"btn-range" + (!zoomed && props.range === r ? " active" : "")}
                    onClick=${(e) => {
                      e.preventDefault();
                      props.onRange(r);
                    }}>${label}</a>`,
                )}
                ${
                  zoomed
                    ? html`<button class="btn-range btn-reset" onClick=${() => props.onResetZoom()}>↺ Reset zoom</button>`
                    : html`<span class="text-muted text-xs ml-2">Drag to zoom · Shift-drag to pan · Ctrl-scroll to zoom</span>`
                }
            </div>
            <div class="chart-controls" role="group" aria-label="Hashrate averaging window">
                <span class="text-muted text-small mr-1" title="Which hashrate-averaging window the chart plots (#168)">Avg:</span>
                ${WINDOWS.map(
                  ([w, label]) => html`<button type="button"
                    class=${"btn-range" + (props.avgWindow === w ? " active" : "")}
                    aria-pressed=${props.avgWindow === w}
                    title=${WINDOW_HINT[w] || label + " average"}
                    onClick=${() => props.onAvgWindow && props.onAvgWindow(w)}>${label}</button>`,
                )}
            </div>
            <div class="chart-legend" role="group" aria-label="Toggle series">
                ${SERIES.map((s) => {
                  const on = (props.series || {})[s.key] !== false;
                  return html`<button type="button" class=${"legend-item" + (on ? "" : " off")}
                        aria-pressed=${on} title=${(on ? "Hide " : "Show ") + s.label}
                        onClick=${() => props.onToggleSeries(s.key)}>
                        <span class=${"legend-dot " + s.dot}></span>${s.label}
                    </button>`;
                })}
            </div>
            <div class="chart-wrap"><canvas ref=${this.canvasRef}></canvas></div>
        </div>`;
  }
}

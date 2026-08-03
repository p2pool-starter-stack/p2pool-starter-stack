// Pure, dependency-free client logic — no Preact, no DOM, no Chart.js. Kept separate so it can
// be unit-tested with Node's built-in runner (`node --test`; see tests/frontend/logic.test.mjs)
// without a browser or a JS toolchain. Presentation (components, the canvas) stays elsewhere and
// is covered by the browser smoke test.

// Worker table columns, each carrying the state key it sorts on. Hashrate/uptime/IP and the
// accepted/rejected share counts sort numerically (raw values the server includes alongside the
// formatted strings); name sorts as text. The order matches the rendered <th>s.
// The hashrate windows are named for what the proxy data is — 1m and 10m (#387) — matching the
// chart's averaging toggle and Telegram's "(10m avg)". The legacy h10 field isn't shown: via the
// proxy it's just a second copy of the 1m rate.
export const WORKER_COLUMNS = [
  { label: "Worker", key: "name" },
  { label: "IP", key: "ip_sort" },
  { label: "Uptime", key: "uptime" },
  { label: "1m", key: "h60" },
  { label: "10m", key: "h15" },
  { label: "Accepted", key: "accepted" },
  { label: "Rejected", key: "rejected" },
];

// Return a new array of workers sorted by the given column index. ``idx == null`` keeps the
// server's order (online first, then name). Numeric columns compare numerically (so 1000 sorts
// after 9, not before it); everything else compares as a locale string. Never mutates input.
export function sortWorkers(workers, idx, asc) {
  if (idx === null || idx === undefined) return workers;
  const key = WORKER_COLUMNS[idx].key;
  const sorted = [...workers].sort((a, b) => {
    const va = a[key],
      vb = b[key];
    if (typeof va === "number" && typeof vb === "number") return va - vb;
    return String(va).localeCompare(String(vb));
  });
  return asc ? sorted : sorted.reverse();
}

// Hero KPI band (Issue #81). The headline numbers surfaced as a prominent top strip: each entry
// is { label, value, cls } where `value` is an already-formatted display string from build_state
// and `cls` is the text-colour class applied to it ('' = default text colour). Pure selection +
// labelling is kept here so the wiring (which state field feeds which KPI, and the mode/shares
// colouring) is unit-tested; <HeroBand> in components.mjs only renders the returned list.
// Tri-state colour for the Raffle Eligible indicator (#158): muted '' when XvB is off (N/A — no
// raffle to be eligible for), green when fully eligible (donor tier on credited 1h+24h AND a PPLNS
// share), red otherwise. Kept here (not inline) so both the Hero KPI and the Simple card share it.
export function raffleCls(raffle) {
  if (!raffle || !raffle.applies) return "";
  return raffle.eligible ? "status-ok" : "status-bad";
}

export function heroKpis(state) {
  const hr = state.hashrate,
    sw = state.shares_window,
    p = state.pool,
    raffle = state.raffle_eligible || {},
    // On a box that isn't donating, two raffle KPI slots ("Raffle Eligible: N/A", "XvB Tier:
    // None") are dead weight in the most prominent strip on the page — the mode badge already
    // says XvB is off, once. Dropped entirely; they return the moment XvB is enabled.
    xvbOn = !!(state.xvb_calc && state.xvb_calc.enabled);
  return [
    { label: "Total Hashrate", value: hr.total, cls: "text-accent" },
    { label: "Shares in Window", value: sw.count, cls: sw.ok ? "status-ok" : "status-bad" },
    // Raffle Eligible (#158): Yes only when you'd WIN and COLLECT — in a donor tier AND holding a
    // PPLNS share. Red "No" when donating but a gate is unmet.
    ...(xvbOn ? [{ label: "Raffle Eligible", value: raffle.label, cls: raffleCls(raffle) }] : []),
    { label: "Blocks Found", value: p.blocks, cls: "" },
    ...(xvbOn ? [{ label: "XvB Tier", value: hr.tier, cls: "" }] : []),
    { label: "Mining Mode", value: hr.mode_name, cls: "c-" + hr.mode_variant },
  ];
}

// Format an epoch-ms x value for the chart tooltip title (Issue #65). Day + time so long ranges
// read clearly; browser locale (≈ the server's, for a localhost dashboard).
export function fmtTimestamp(ms) {
  return new Date(ms).toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

// Manual chart zoom (Issue #47). Pure window math, kept here (no DOM/Chart) so it's unit-tested;
// the chartjs-plugin-zoom gestures and the /api/state refetch wiring live in chart.mjs /
// dashboard.js.

// Normalize a dragged/zoomed pixel→time window to an ordered {from, to} (epoch ms) with at
// least `minSpanMs`. Returns null for unusable input (NaN, or a zero-width selection) so a
// degenerate gesture is treated as "no zoom". A too-narrow but valid window is widened around
// its centre to `minSpanMs` (so you can't request a sub-sample window).
export function clampZoomWindow(aMs, bMs, minSpanMs = 60000) {
  if (!Number.isFinite(aMs) || !Number.isFinite(bMs) || aMs === bMs) return null;
  let from = Math.min(aMs, bMs);
  let to = Math.max(aMs, bMs);
  if (to - from < minSpanMs) {
    const mid = (from + to) / 2;
    from = mid - minSpanMs / 2;
    to = mid + minSpanMs / 2;
  }
  return { from, to };
}

// Chart series the user can show/hide, and a normalizer for the persisted state (Issue #47).
// Kept pure so the default-visible logic is unit-tested; dashboard.js persists it in localStorage
// and chart.mjs applies it. Anything not explicitly false defaults to visible.
export const SERIES_KEYS = [
  "p2pool",
  "xvb",
  "shares",
  "events",
  "raffle",
  "payouts",
  "xvb_donation",
];
export function normalizeSeries(obj) {
  const o = obj && typeof obj === "object" ? obj : {};
  const out = {};
  for (const k of SERIES_KEYS) out[k] = o[k] !== false;
  return out;
}

// Persisted single-choice UI preferences (#658) — earnings tab, editor modes, topology mesh.
// normalizeChoice is the pure, unit-tested core; loadPref/savePref wrap localStorage guarded,
// so components stay importable under node --test (no localStorage → the fallback / a no-op).
export function normalizeChoice(value, allowed, fallback) {
  return allowed.includes(value) ? value : fallback;
}
export function loadPref(key, allowed, fallback) {
  try {
    return normalizeChoice(localStorage.getItem(key), allowed, fallback);
  } catch {
    return fallback;
  }
}
export function savePref(key, value) {
  try {
    localStorage.setItem(key, value);
  } catch {
    // Private mode or no storage: the preference just doesn't stick.
  }
}

// Workers-table sort preference (#658), stored as "index:asc|desc". A stale index (column
// removed) or garbage falls back to the server order.
export function normalizeSort(raw, colCount) {
  const m = /^(\d+):(asc|desc)$/.exec(raw || "");
  if (!m || Number(m[1]) >= colCount) return { sortIndex: null, sortAsc: true };
  return { sortIndex: Number(m[1]), sortAsc: m[2] === "asc" };
}

// Human-readable span for the "Zoomed: …" label — the two coarsest units from the first
// non-zero one (e.g. "3d 4h", "1h 20m", "45s"), trailing zero units dropped. Pure and
// locale-independent, unlike fmtTimestamp.
export function fmtWindowDuration(ms) {
  const totalSec = Math.max(0, Math.round(ms / 1000));
  if (totalSec === 0) return "0s";
  const units = [
    ["d", 86400],
    ["h", 3600],
    ["m", 60],
    ["s", 1],
  ];
  const counts = [];
  let rem = totalSec;
  for (const [label, size] of units) {
    counts.push([Math.floor(rem / size), label]);
    rem %= size;
  }
  const first = counts.findIndex(([n]) => n > 0);
  const parts = [];
  for (let i = first; i < counts.length && parts.length < 2; i++) {
    if (counts[i][0] > 0) parts.push(counts[i][0] + counts[i][1]);
    else if (parts.length > 0) break; // stop at a trailing zero unit
  }
  return parts.join(" ");
}

// Theme switching (Issue #43). Three modes; "auto" follows the browser's prefers-color-scheme.
// The valid set, display order and labels live here (pure, no DOM) so they're unit-tested; the
// localStorage + <html data-theme> wiring is in dashboard.js and the segmented control (with its
// SVG icons) in components.mjs.
export const THEMES = ["auto", "light", "dark"];
export const THEME_LABELS = { auto: "Auto", light: "Light", dark: "Dark" };
// Left→right order of the segmented control: light · auto · dark (brightness low→high with the
// system option in the middle).
export const THEME_ORDER = ["light", "auto", "dark"];

// Clamp any value (incl. a stale/garbage localStorage entry) to a valid theme; default "auto".
export function normalizeTheme(t) {
  return THEMES.includes(t) ? t : "auto";
}

// Hashrate-averaging windows for the chart toggle (#168). The valid set + default live here (pure,
// no DOM) so they're unit-tested; the localStorage wiring is in dashboard.js and the segmented
// control (spelled-out labels) in chart.mjs. Keys match the server's `avg` param and
// config.HASHRATE_WINDOWS.
export const AVG_WINDOWS = ["1m", "10m", "1h", "12h", "24h"];
export const DEFAULT_AVG_WINDOW = "10m";

// Clamp any value (incl. a stale/garbage localStorage entry) to a valid window; default 10m — the
// original headline series, so a bad or missing preference reproduces today's chart exactly.
export function normalizeAvgWindow(w) {
  return AVG_WINDOWS.includes(w) ? w : DEFAULT_AVG_WINDOW;
}

// Expected-earnings what-if (Issue #12). The server publishes the per-H/s daily XMR *rate*
// (earnings.coeff_day — authoritative, computed once in service/earnings.py) and the P2Pool
// share difficulty. Earnings are linear in hashrate, so the client only scales that one rate to
// the entered hashrate (and to month/year), and inverts the share difficulty for expected
// time-to-share — no formula is re-derived here. Kept pure so it's unit-tested (no DOM); the
// EarningsCard input wiring lives in components.mjs.
export const DAYS_PER_MONTH = 30; // estimate convention (not 30.44); a year is 365 days
export const DAYS_PER_YEAR = 365;

// Parse a what-if hashrate string into H/s, accepting an optional k/M/G suffix so users can type
// "10.5k", "1.2 MH/s", or a bare "50000". Returns null for empty/unparseable input (the card then
// shows "—"). Mirrors helper/utils.parse_hashrate on the server side.
export function parseHashrate(str) {
  if (typeof str !== "string") return null;
  const m = str.trim().match(/^([0-9]*\.?[0-9]+)\s*([kKmMgG])?/);
  if (!m) return null;
  const val = parseFloat(m[1]);
  if (!Number.isFinite(val) || val < 0) return null;
  const unit = (m[2] || "").toLowerCase();
  return val * (unit === "g" ? 1e9 : unit === "m" ? 1e6 : unit === "k" ? 1e3 : 1);
}

// Format raw H/s for display. Mirrors helper/utils.format_hashrate on the server side (same
// thresholds, 2 decimals, same unit strings — the parseHashrate precedent) so client-rendered
// figures like the chart tooltip read identically to the server-formatted cards (#387).
export function fmtHashrate(hs) {
  const val = Number(hs);
  if (!Number.isFinite(val)) return "0 H/s";
  if (val >= 1e9) return (val / 1e9).toFixed(2) + " GH/s";
  if (val >= 1e6) return (val / 1e6).toFixed(2) + " MH/s";
  if (val >= 1e3) return (val / 1e3).toFixed(2) + " kH/s";
  return val.toFixed(2) + " H/s";
}

// Scale the server's daily rate to expected XMR over day/month/year for `hashrateHs`, plus the
// expected seconds to find one P2Pool share (share difficulty / hashrate). Returns nulls when the
// estimate can't be computed (rate unavailable, or a non-positive hashrate) so the card shows "—".
export function computeEarnings(hashrateHs, earnings) {
  if (!earnings || !earnings.available || !(hashrateHs > 0)) {
    return {
      day: null,
      month: null,
      year: null,
      timeToShareSec: null,
      tariDay: null,
      tariMonth: null,
      tariYear: null,
      tariTimeToBlockSec: null,
      tariRewardPerBlock: null,
      xvbDay: null,
      xvbMonth: null,
      xvbYear: null,
    };
  }
  const day = hashrateHs * earnings.coeff_day;
  const tts = earnings.pool_difficulty > 0 ? earnings.pool_difficulty / hashrateHs : null;
  // Tari (#117): merge-mining works the aux chain with the SAME hashrate, so the one what-if
  // input scales the server's XTM rate identically. Nulls (rendered "—") while merge-mining is
  // inactive or the Tari figures aren't collected yet — the XMR estimate is unaffected.
  const tariDay = earnings.tari_available ? hashrateHs * earnings.tari_coeff_day : null;
  // Solo merge-mining is lumpy (the block reward lands all at once), so the honest headline is the
  // expected time to a Tari block — difficulty / hashrate — and the whole per-block reward. The
  // server sends difficulty as seconds-to-block-per-H/s (tari_difficulty), so divide by hashrate.
  const tariTimeToBlockSec =
    earnings.tari_available && earnings.tari_difficulty > 0
      ? earnings.tari_difficulty / hashrateHs
      : null;
  return {
    day,
    month: day * DAYS_PER_MONTH,
    year: day * DAYS_PER_YEAR,
    timeToShareSec: tts,
    tariDay,
    tariMonth: tariDay === null ? null : tariDay * DAYS_PER_MONTH,
    tariYear: tariDay === null ? null : tariDay * DAYS_PER_YEAR,
    tariTimeToBlockSec,
    tariRewardPerBlock: earnings.tari_available ? earnings.tari_reward : null,
    // Current-tier XvB expected reward, XMR/day (#712). A fixed published figure, NOT scaled by the
    // what-if hashrate (unlike day/tariDay); null unless the server sent a fresh estimate. Month/
    // year are the same day/month/year spans every other estimate gets, so the XvB tab can show
    // the standardized table.
    xvbDay: Number.isFinite(earnings.xvb_day) ? earnings.xvb_day : null,
    xvbMonth: Number.isFinite(earnings.xvb_day) ? earnings.xvb_day * DAYS_PER_MONTH : null,
    xvbYear: Number.isFinite(earnings.xvb_day) ? earnings.xvb_day * DAYS_PER_YEAR : null,
  };
}

// Highest sustainable XvB tier for a what-if hashrate (#118): the highest tier whose threshold
// clears `hashrateHs * calc.max_fraction`. A direct transcription of the AUTO path of
// helper/utils.resolve_target_threshold (get_tier_info over stable_hr × max_fraction) — a pinned
// test shares its inputs with the Python unit test so the two can't drift silently. Cost = the
// threshold itself: XvB qualifies a tier on BOTH the 1h and 24h credited averages, so holding it
// costs ~threshold H/s of continuous donation. Null when no tier is sustainable or XvB is off.
export function computeXvbTier(hashrateHs, calc) {
  if (!calc || !calc.enabled || !(hashrateHs > 0)) return null;
  let best = null;
  for (const t of calc.tiers || []) {
    if (t.threshold > 0 && hashrateHs * calc.max_fraction >= t.threshold) {
      if (!best || t.threshold > best.threshold) best = t;
    }
  }
  return best && { tier: best.name, threshold: best.threshold, cost: best.threshold };
}

// XvB per-tier payout comparison (#118, made honest by #872). Weighs XvB's expected reward for a
// tier against what donating that tier costs in foregone P2Pool earnings: cost = threshold H/s ×
// the daily P2Pool rate (`coeffDay`, same `earnings.coeff_day` the card already uses) × 365.
// TWO reward figures: `expected` is XvB's published face value (prices every bonus hash at full
// block reward — measured wallets collect a fraction), `realized` is that figure × the wallet's
// own measured win realization (server-computed, null until enough wins measure it). The
// actionable net prefers realized — the published face value once flipped the net's SIGN on a
// production box (+2.97 shown, −1.8 measured, #872). Either figure null (unavailable/stale/
// unmeasured) => its net is null: we never fabricate the reward. This is a raffle-tier
// comparison, NOT a claim that donating more within a tier helps.
export function xvbTierComparison(tier, coeffDay) {
  const cost =
    tier && tier.threshold > 0 && coeffDay > 0 ? tier.threshold * coeffDay * DAYS_PER_YEAR : null;
  const expected =
    tier && Number.isFinite(tier.expected_reward_year) ? tier.expected_reward_year : null;
  const realized =
    tier && Number.isFinite(tier.realized_reward_year) ? tier.realized_reward_year : null;
  const net = expected !== null && cost !== null ? expected - cost : null;
  const realizedNet = realized !== null && cost !== null ? realized - cost : null;
  return { expected, cost, net, realized, realizedNet };
}

// Decimal places for a coin amount: more for small amounts (a day's earnings can be a tiny
// fraction) so the figure isn't rounded to "0.0000".
function coinDp(value) {
  return value >= 1 ? 4 : value >= 0.001 ? 6 : 8;
}

// Format a client-computed coin amount; "—" for the null/invalid case.
function formatCoin(value, unit) {
  if (value === null || value === undefined || !Number.isFinite(value)) return "—";
  if (value === 0) return "0 " + unit;
  return value.toFixed(coinDp(value)) + " " + unit;
}

// Format a Day/Month/Year coin triplet with ONE shared precision, picked from the smallest
// positive value (the day figure). Per-value precision made the column ragged — "0.00092945"
// above "0.027884" above "0.339250" — so the standardized estimate tables share the dp and the
// rows align. Nulls still render "—" (the table can hold a computable day beside a null month).
export function coinTriplet(values, unit) {
  const positive = values.filter((v) => Number.isFinite(v) && v > 0);
  const dp = positive.length ? coinDp(Math.min(...positive)) : 4;
  return values.map((v) => {
    if (v === null || v === undefined || !Number.isFinite(v)) return "—";
    if (v === 0) return "0 " + unit;
    return v.toFixed(dp) + " " + unit;
  });
}

export function formatXmr(xmr) {
  return formatCoin(xmr, "XMR");
}

// Relative "N ago" for a unix-seconds timestamp — the confirmed-payout "Last payout" cell (#381).
// "Never" when unset/zero (mirrors the server's format_time_abs); reuses fmtWindowDuration for the
// span so the wording matches the "Zoomed: …" label. nowMs is injectable so it's unit-testable.
export function formatAgo(unixSec, nowMs = Date.now()) {
  if (!unixSec || !Number.isFinite(unixSec)) return "Never";
  const ms = nowMs - unixSec * 1000;
  if (ms < 0) return "just now"; // a future timestamp (clock skew) reads oddly as "N ago"
  return fmtWindowDuration(ms) + " ago";
}

// Merge-mined Tari (#117); the collector already delivers the reward in XTM (not µT).
export function formatXtm(xtm) {
  return formatCoin(xtm, "XTM");
}

// Energy & profit (#260, Tari revenue #520). Turns the server's measured fleet watts + operator
// prices into kWh / cost / net over day·month·year for a what-if hashrate. Power draw is measured
// (does NOT scale with the what-if hashrate — it's the real fleet), so only the earnings side
// scales: net = gross − cost(kWh × cost_per_kwh), where
//   gross = (what-if XMR/day × xmr_price) + (what-if Tari/day × tari_price, when priced)
//           + (current-tier XvB/day × xmr_price, when the server sent a fresh estimate).
// `est` is the already-computed earnings for this what-if hashrate (computeEarnings; `est.tariDay`
// is the same Tari/day estimate the Tari tab already shows — no separate estimate invented here).
// XvB (#712): `est.xvbDay` is the current tier's published expected reward (XMR/day), folded into
// the single net — the whole net is already probabilistic, so one number stays coherent, and the
// UI labels the XvB slice as an estimate (the raffle draw is random among qualifiers). It's a
// fixed published figure, so it does NOT scale with the what-if hashrate; null (server-gated on a
// fresh, non-stale estimate for a held donor tier) means it's simply left out — never fabricated.
// Any figure whose inputs are missing comes back null so the card shows "—" rather than a bogus
// number: cost needs cost_per_kwh > 0; net additionally needs xmr_price > 0 and a valid XMR
// estimate — Tari and XvB only ever ADD to that base (mirrors the existing xmr_price-gates-net
// contract, #520 scope: no tari-price-only net). `includesTari` / `includesXvb` tell the UI which
// figure it got, so the net-profit label is never silently partial (#520's honesty requirement).
export function computeEnergy(energy, est) {
  const blank = {
    kwhDay: null,
    kwhMonth: null,
    kwhYear: null,
    costDay: null,
    costMonth: null,
    costYear: null,
    grossDay: null,
    grossMonth: null,
    grossYear: null,
    netDay: null,
    netMonth: null,
    netYear: null,
    includesTari: false,
    includesXvb: false,
  };
  if (!energy || !energy.available || !(energy.total_watts > 0)) return blank;
  const kwhDay = (energy.total_watts / 1000) * 24;
  const price = energy.cost_per_kwh;
  const haveCost = Number.isFinite(price) && price > 0;
  const costDay = haveCost ? kwhDay * price : null;
  const xmrPrice = energy.xmr_price;
  const tariPrice = energy.tari_price;
  const haveXmr = Number.isFinite(xmrPrice) && xmrPrice > 0 && est && Number.isFinite(est.day);
  const includesTari =
    haveXmr && Number.isFinite(tariPrice) && tariPrice > 0 && Number.isFinite(est.tariDay);
  // XvB (#712): the current tier's published expected reward (XMR/day), valued at the XMR price —
  // an estimate blended into the single net, gated on a real XMR price like every other addend.
  const includesXvb = haveXmr && Number.isFinite(est.xvbDay) && est.xvbDay > 0;
  const grossDay = haveXmr
    ? est.day * xmrPrice +
      (includesTari ? est.tariDay * tariPrice : 0) +
      (includesXvb ? est.xvbDay * xmrPrice : 0)
    : null;
  const netDay = grossDay !== null && costDay !== null ? grossDay - costDay : null;
  const span = (v, mult) => (v === null ? null : v * mult);
  return {
    kwhDay,
    kwhMonth: kwhDay * DAYS_PER_MONTH,
    kwhYear: kwhDay * DAYS_PER_YEAR,
    costDay,
    costMonth: span(costDay, DAYS_PER_MONTH),
    costYear: span(costDay, DAYS_PER_YEAR),
    // Gross revenue (the sum the net starts from), surfaced so the Energy tab can show
    // Revenue → Cost → Net instead of leaving the revenue side implicit.
    grossDay,
    grossMonth: span(grossDay, DAYS_PER_MONTH),
    grossYear: span(grossDay, DAYS_PER_YEAR),
    netDay,
    netMonth: span(netDay, DAYS_PER_MONTH),
    netYear: span(netDay, DAYS_PER_YEAR),
    includesTari,
    includesXvb,
  };
}

// Format a fiat figure (energy cost / net profit, #260) in the operator's currency label. Net can be
// negative (power costs more than it earns) — keep the sign. "—" for the null/uncomputable case.
export function formatFiat(value, currency) {
  if (value === null || value === undefined || !Number.isFinite(value)) return "—";
  const sign = value < 0 ? "-" : "";
  return sign + (currency || "USD") + " " + Math.abs(value).toFixed(2);
}

// Bare fiat amount for estimate-table cells, where the column header already names the
// currency — repeating "USD" in every cell is noise. Same 2-dp + sign rules as formatFiat.
export function formatFiatAmount(value) {
  if (value === null || value === undefined || !Number.isFinite(value)) return "—";
  const sign = value < 0 ? "-" : "";
  return sign + Math.abs(value).toFixed(2);
}

// Fiat value of a coin estimate (#520 price feed): null unless both the estimate and a positive
// price exist, so the coin tabs only grow fiat rows once a price is configured or fetched.
export function coinFiat(value, price) {
  return Number.isFinite(value) && Number.isFinite(price) && price > 0 ? value * price : null;
}

// Format a fiat *price* (a per-coin exchange rate, #520). Unlike formatFiat (aggregates, 2 dp) a
// price can be tiny — XTM trades at fractions of a cent — so scale the decimals like formatCoin
// does, or the price line would read "USD 0.00". "—" when the price is unset (0/invalid).
export function formatFiatPrice(value, currency) {
  if (!Number.isFinite(value) || value <= 0) return "—";
  const dp = value >= 1 ? 2 : value >= 0.001 ? 4 : 6;
  return (currency || "USD") + " " + value.toFixed(dp);
}

// Provenance of the prices in use (#520): the calculator always says which price its fiat figures
// are valued at — live feed (with age), feed-enabled-but-waiting (static still in use), or static
// config. Null when the feed is off and no price is set: there are no fiat figures to attribute.
export function priceSourceLabel(energy) {
  if (!energy) return null;
  const src = energy.price_source || {};
  const havePrice = energy.xmr_price > 0 || energy.tari_price > 0;
  if (src.live) {
    const age = Number.isFinite(src.age_sec)
      ? ", updated " + fmtWindowDuration(src.age_sec * 1000) + " ago"
      : "";
    return "live from CoinGecko over Tor" + age;
  }
  if (src.feed) return "price feed waiting for its first fetch — static config.json values in use";
  return havePrice ? "static, set in config.json" : null;
}

// Format a power draw / energy figure with its unit (W, kWh); "—" for the null/invalid case.
// An empty unit gives the bare number — for table cells whose column header names the unit.
export function formatUnit(value, unit, dp = 1) {
  if (value === null || value === undefined || !Number.isFinite(value)) return "—";
  return value.toFixed(dp) + (unit ? " " + unit : "");
}

// Format the expected time-to-share (seconds) for display; "—" when not computable. Reuses the
// two-coarsest-units duration formatter (e.g. "3d 4h", "1h 20m").
export function formatTimeToShare(sec) {
  if (sec === null || sec === undefined || !Number.isFinite(sec) || sec <= 0) return "—";
  return fmtWindowDuration(sec * 1000);
}

// Egress posture (#170): map a connection's route token to a display glyph + label + CSS token for
// the Component Health panel. The server (service/egress.py) derives the route from live config; the
// client only maps it to presentation, no logic of its own (the #61 principle).
export const EGRESS_ROUTES = {
  tor: { icon: "🧅", label: "Tor", cls: "ok" },
  clearnet: { icon: "🌐", label: "Clearnet", cls: "bad" },
  local: { icon: "🏠", label: "Local/LAN", cls: "muted" },
  inactive: { icon: "⚪", label: "Inactive", cls: "muted" },
};

export function egressRoute(route) {
  return EGRESS_ROUTES[route] || { icon: "❔", label: route || "unknown", cls: "muted" };
}

// Topology edge routing (#170): the point on a node box's border heading toward a target point, so
// a connector starts/ends flush on the box edge (not its centre). Pure geometry — `node` is
// {x, y, w, h}; (tx, ty) the target centre. Used by the StackTopology SVG and unit-tested directly.
export function boxAnchor(node, tx, ty) {
  const cx = node.x + node.w / 2;
  const cy = node.y + node.h / 2;
  const dx = tx - cx;
  const dy = ty - cy;
  if (dx === 0 && dy === 0) return { x: cx, y: cy };
  // Scale the direction vector until it hits the nearest border (half-width / half-height).
  const sx = dx !== 0 ? node.w / 2 / Math.abs(dx) : Infinity;
  const sy = dy !== 0 ? node.h / 2 / Math.abs(dy) : Infinity;
  const s = Math.min(sx, sy);
  return { x: cx + dx * s, y: cy + dy * s };
}

// Width of a stacked hashrate band's top border-line for one chart segment. Returns 0 when the band
// has zero height across the segment (both endpoints y === 0), so a flat-zero series doesn't paint
// its colored border-line over the other series' edge — the "blue-purple at 100% P2Pool" artifact,
// and the symmetric stray-blue-line in XvB-only mode (#184). `series` is the [{x, y}] data; `ctx` is
// the Chart.js line-segment context (p0DataIndex / p1DataIndex). Partial-zero spans are handled
// per-segment, so a window that's only briefly all-one-pool still hides just the zero stretch.
export function bandBorderWidth(series, ctx, fullWidth) {
  const y0 = series[ctx.p0DataIndex]?.y;
  const y1 = series[ctx.p1DataIndex]?.y;
  return y0 === 0 && y1 === 0 ? 0 : fullWidth;
}

// What to show in a worker's "Uptime" cell. For an online worker it's the real uptime; for an
// offline one it's "DOWN" — never the raw duration, which for a disconnected worker kept climbing
// and read like uptime when it was really downtime (#169). The raw numeric `uptime` is left on the
// row for client-side column sorting; only the displayed string changes.
export function uptimeCell(worker) {
  return worker.status === "online" ? worker.uptime_str : "DOWN";
}

import { Component, html } from "./preact.mjs";

// Mine cart train (pixel art). A horizontal strip under the hero band: each cart is one
// interval of recent history, and what landed in it rides in the cart as a token coin poking
// over the rim — a Monero-orange ɱ coin for a P2Pool share, a PAIR of them for a found block,
// a purple Tari gem-coin for a confirmed Tari payout, a blue X coin for an XvB raffle win.
// The newest interval sits under the tipple chute on the right; completed carts roll left.
// Pure presentation over the same /api/state chart history the Chart.js card reads — no new
// data, no server involvement. Canvas 2D, drawn at a fixed logical pixel grid and integer-
// scaled (imageSmoothingEnabled = false) so it stays crisp pixel art at any DPR.

// ---- sprite sheets ------------------------------------------------------------------------
// Char-map sprites: each string is a row, each char a palette key, "." transparent. The
// palette maps chars to concrete colours at draw time (theme/event dependent).

const CART_W = 22; // logical px, cart body incl. wheels
const CART_H = 16;
const GAP = 4; // coupling gap between carts
const STRIP_H = 56; // logical strip height incl. sky, tipple and rail
const CAT_ZONE = 44; // left margin reserved for the sleeping cat + its grass mound

// Cart body (side view): rim, sloped hull, two wheels. "b" body, "r" rim, "w" wheel,
// "h" wheel hub, "s" shadow under hull.
const CART = [
  "rrrrrrrrrrrrrrrrrrrrrr",
  "rbbbbbbbbbbbbbbbbbbbbr",
  ".bbbbbbbbbbbbbbbbbbbb.",
  ".bbbbbbbbbbbbbbbbbbbb.",
  "..bbbbbbbbbbbbbbbbbb..",
  "..bbbbbbbbbbbbbbbbbb..",
  "...bbbbbbbbbbbbbbbb...",
  "...ssssssssssssssss...",
  "....ww..........ww....",
  "...wwww........wwww...",
  "...whhw........whhw...",
  "....ww..........ww....",
];

// Big token coin (12×11) that pokes out of a cart: dark rim, bright face, a shaded crescent on
// the lower-right for the 3D read. Drawn BEFORE the cart so the hull occludes its lower third —
// the coin sits IN the cart, sticking out. Symbols are overlaid from SYMBOLS at draw time.
const COIN = [
  "...rrrrrr...",
  "..rffffffr..",
  ".rfffffffdr.",
  "rffffffffddr",
  "rffffffffddr",
  "rffffffffddr",
  "rffffffffddr",
  "rfffffffdddr",
  ".rffffffddr.",
  "..rffffddr..",
  "...rrrrrr...",
];

// 5×5 coin symbols ("x" = symbol pixel), centred on the coin face: Monero's M, Tari's gem,
// XvB's X.
const SYMBOLS = {
  xmr: ["x...x", "xx.xx", "x.x.x", "x...x", "x...x"],
  tari: ["..x..", ".xxx.", "xxxxx", ".xxx.", "..x.."],
  xvb: ["x...x", ".x.x.", "..x..", ".x.x.", "x...x"],
};

// The tipple (coal chute) that loads the newest cart: legs, hopper, spout.
const TIPPLE = [
  "..tttttttttt..",
  ".tttttttttttt.",
  ".tttttttttttt.",
  "..tttttttttt..",
  "...tttttttt...",
  "....tttttt....",
  ".....tttt.....",
  ".....t..t.....",
  ".....t..t.....",
];

// Sleeping cat, curled up facing left: ears, closed eye, lighter muzzle/belly patch, wrapped
// tail. "m" fur, "l" light fur, "e" closed-eye line, "n" nose.
const CAT = [
  "..............",
  "...mm....mm...",
  "..mmmmmmmmmm..",
  ".mmemmmmmmmmm.",
  ".mlnlmmmmmmmm.",
  ".mllmmmmmmmmm.",
  "..mmmmmmmmmt..",
  "...ttttttttt..",
];

// Puffy cloud, drawn in a soft translucent tone; drifts slowly across the sky.
const CLOUD = ["....cccccc......", "..cccccccccc.c..", ".cccccccccccccc.", "..cccccccccccc.."];

// ---- data adapter -------------------------------------------------------------------------
// Bucket the /api/state chart payload + top-level blocks into carts. Pure and unit-tested.
// The 12 carts span whatever window the server sent (the chart's selected range), so each cart
// is 1/12 of the visible history — 5-minute carts on the 1h range, 2-hour carts on 24h — and
// the train never goes sparse under the server's per-range downsampling. Sources (three
// separate marker arrays; there is no unified event stream server-side):
//   chart.p2pool       {x: ms, y: H/s}, y:null gap markers → window bounds only
//   chart.shares       {x: ms, c: count}                   → orange ɱ coin
//   chart.raffle       {x: ms, label}                      → XvB blue X coin
//   blocks (top-level) {x: ms, height}                     → a PAIR of ɱ coins
//   payouts.tari       {x: ms, amount} confirmed payouts   → Tari purple gem coin
// A confirmed Tari coinbase payout IS a solo-found Tari block (the wallet's proof it landed),
// so the purple coin marks real Tari income, not a guess.
export function cartsFromState(chart, blocks, count = 12, payouts = null) {
  // Valid-sample timestamps bound the window; outage gap markers carry y:null and don't count.
  const ts = ((chart && chart.p2pool) || [])
    .filter((p) => Number.isFinite(p.y))
    .map((p) => p.x / 1000);
  if (!ts.length) return [];
  const events = [];
  for (const s of (chart && chart.shares) || [])
    events.push({ t: s.x / 1000, kind: "share", n: s.c || 1 });
  for (const r of (chart && chart.raffle) || []) events.push({ t: r.x / 1000, kind: "xvb", n: 1 });
  for (const b of blocks || []) events.push({ t: b.x / 1000, kind: "block", n: 1 });
  for (const p of (payouts && payouts.tari) || [])
    events.push({ t: p.x / 1000, kind: "tari", n: 1 });

  const t0all = ts[0];
  const bucketSec = Math.max(ts[ts.length - 1] - t0all, 60) / count;
  const carts = [];
  for (let i = 0; i < count; i++) {
    const t0 = t0all + i * bucketSec;
    const t1 = t0 + bucketSec;
    const evs = events.filter((e) => e.t >= t0 && (i === count - 1 ? e.t <= t1 : e.t < t1));
    carts.push({
      t0,
      t1,
      shares: evs.filter((e) => e.kind === "share").reduce((a, e) => a + e.n, 0),
      blocks: evs.filter((e) => e.kind === "block").length,
      wins: evs.filter((e) => e.kind === "xvb").length,
      tari: evs.filter((e) => e.kind === "tari").length,
      // The newest (rightmost) cart is still loading under the chute.
      loading: i === count - 1,
    });
  }
  return carts;
}

// One-line human summary for a cart (canvas tooltip). Times in the operator's locale.
export function cartTitle(cart) {
  const hm = (t) =>
    new Date(t * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  const what = [];
  if (cart.blocks) what.push(cart.blocks + " block" + (cart.blocks > 1 ? "s" : "") + " FOUND");
  if (cart.tari) what.push(cart.tari + " Tari payout" + (cart.tari > 1 ? "s" : ""));
  if (cart.wins) what.push(cart.wins + " XvB raffle win" + (cart.wins > 1 ? "s" : ""));
  if (cart.shares) what.push(cart.shares + " share" + (cart.shares > 1 ? "s" : ""));
  return (
    hm(cart.t0) +
    "–" +
    hm(cart.t1) +
    " — " +
    (what.length ? what.join(", ") : "hauling") +
    (cart.loading ? " (loading)" : "")
  );
}

// ---- renderer -----------------------------------------------------------------------------

// The tipple drip's rock colour. Fixed pigment (not a theme var): the scene should read the
// same in both themes, like the chart series colours do.
const DRIP = "#8a7a66";
const COINS = {
  // r rim (dark), f face, d depth crescent, s symbol pixels. Monero coins are Monero ORANGE
  // (the brand pigment), Tari purple, XvB blue — same fixed-pigment rule as the rest of the
  // scene. A found block shows as a PAIR of Monero coins rather than a brighter tint.
  xmr: { r: "#a63d0e", f: "#f26822", d: "#c85417", s: "#fff3ec" },
  tari: { r: "#5e2ea6", f: "#9d5cf5", d: "#7a3fd4", s: "#f4edff" },
  xvb: { r: "#1f5fa8", f: "#58a6ff", d: "#3b7fd4", s: "#eef6ff" },
};
// Scenery pigments — soft pastel greens for grass, warm grey cat with a cream belly.
const GRASS = { a: "#6aa84f", b: "#8fce6e" };
const CAT_PAL = { m: "#8d7b70", l: "#e8d8c3", e: "#4a3f38", n: "#c97f6f", t: "#7a675c" };

function themePalette() {
  const css = getComputedStyle(document.documentElement);
  const v = (name, fallback) => (css.getPropertyValue(name) || fallback).trim();
  return {
    // The physical objects use fixed pigments — a white cart hull on a white light-theme page
    // disappears (the ore/coins/cat were always fixed for the same reason). Warm iron + timber
    // keeps the Ghibli-ish warmth in both themes.
    b: "#6b625a", // cart hull — weathered iron
    r: "#494138", // rim
    s: "#00000055", // hull shadow
    w: "#4a4440", // wheels
    h: "#a89680", // hubs
    t: "#7a5c43", // tipple timber
    rail: "#8a8178",
    // Only the sky is theme-aware: clouds at the muted text tone, low alpha (vars are 6-digit
    // hex) — soft against either background.
    cloud: v("--text-muted", "#8b949e") + "40",
  };
}

function drawSprite(ctx, sprite, palette, x, y) {
  for (let row = 0; row < sprite.length; row++) {
    const line = sprite[row];
    for (let col = 0; col < line.length; col++) {
      const c = line[col];
      if (c === ".") continue;
      const color = palette[c];
      if (!color) continue;
      ctx.fillStyle = color;
      ctx.fillRect(x + col, y + row, 1, 1);
    }
  }
}

// Draw the whole scene onto a canvas at logical scale 1 (the caller scales the canvas).
// `tick` is a monotonically increasing frame counter (4 ticks/s): fast cycles drive the coin
// shine and chute drip, slow division drives the cloud drift and the cat's sleepy "z"s.
// Static (tick 0) under prefers-reduced-motion.
export function drawTrain(ctx, carts, widthPx, tick = 0) {
  const pal = themePalette();
  const phase = (tick % 4) / 4;
  ctx.clearRect(0, 0, widthPx, STRIP_H);
  const railY = STRIP_H - 4;

  // Sky: two clouds drifting slowly right-to-left, wrapping. Translucent so they sit behind
  // everything and stay soft in both themes.
  const cloudPal = { c: pal.cloud };
  const drift = Math.floor(tick / 3) % (widthPx + 40);
  drawSprite(ctx, CLOUD, cloudPal, widthPx - drift, 1);
  drawSprite(ctx, CLOUD, cloudPal, ((widthPx * 0.45 - drift * 0.6 + widthPx) % widthPx) - 8, 7);

  // Rails + ties, full width.
  ctx.fillStyle = pal.rail;
  ctx.fillRect(0, railY, widthPx, 1);
  ctx.fillRect(0, railY + 2, widthPx, 1);
  for (let x = 2; x < widthPx; x += 6) ctx.fillRect(x, railY + 1, 2, 1);

  // Grass tufts along the track — little two-blade sprouts, alternating greens.
  for (let x = 7; x < widthPx - 10; x += 23) {
    ctx.fillStyle = (x / 23) % 2 ? GRASS.a : GRASS.b;
    ctx.fillRect(x, railY - 2, 1, 2);
    ctx.fillRect(x + 2, railY - 1, 1, 1);
    ctx.fillRect(x - 1, railY - 1, 1, 1);
  }

  // The sleeping cat on its grass mound, left end of the track.
  const moundY = railY - 3;
  ctx.fillStyle = GRASS.a;
  ctx.fillRect(6, moundY + 1, 30, 2);
  ctx.fillStyle = GRASS.b;
  ctx.fillRect(9, moundY, 24, 1);
  drawSprite(ctx, CAT, CAT_PAL, 13, moundY - CAT.length + 1);
  // Sleepy z's rising every few seconds; two sizes for depth.
  const zStep = Math.floor(tick / 2) % 6;
  if (zStep < 3) {
    ctx.fillStyle = pal.r;
    ctx.fillRect(30, moundY - CAT.length - 2 - zStep, 2, 1);
    ctx.fillRect(31, moundY - CAT.length - 1 - zStep, 1, 1);
    if (zStep > 0) ctx.fillRect(34, moundY - CAT.length - 4 - zStep, 1, 1);
  }

  // Right-align the train: newest cart under the tipple at the right edge; never roll into
  // the cat's corner.
  const tippleX = widthPx - TIPPLE[0].length - 2;
  const cartY = railY - CART_H + 2;
  let x = widthPx - CART_W - 4;
  for (let i = carts.length - 1; i >= 0 && x > CAT_ZONE; i--) {
    const cart = carts[i];
    // Token coins riding IN the cart, poking out over the rim: a Monero-orange ɱ coin per
    // share interval, a PAIR of them for a found block, Tari gem-coin purple, XvB X-coin blue.
    // No pile, no sparkle — the coins bob gently instead (1px, phase-offset per cart, like
    // the track is rumbling). Drawn before the hull so the cart occludes their lower third.
    const coinKinds = [];
    if (cart.blocks || cart.shares) coinKinds.push("xmr");
    if (cart.tari) coinKinds.push("tari");
    if (cart.wins) coinKinds.push("xvb");
    // A block shows as a PAIR of ɱ coins — but only when the pair fits: two slots, and a
    // same-interval Tari/XvB coin must never be squeezed out by the second ɱ (the tooltip
    // always tells the full story either way).
    if (cart.blocks && coinKinds.length === 1) coinKinds.push("xmr");
    const two = coinKinds.length > 1;
    coinKinds.slice(0, 2).forEach((kindName, ci) => {
      const cp = COINS[kindName];
      const bob = (Math.floor(tick / 2) + i + ci) % 2;
      const cx = two ? x + ci * 9 : x + 5;
      const cy = cartY - 7 + bob;
      drawSprite(ctx, COIN, { r: cp.r, f: cp.f, d: cp.d }, cx, cy);
      drawSprite(ctx, SYMBOLS[kindName], { x: cp.s }, cx + 3, cy + 3);
    });
    drawSprite(ctx, CART, pal, x, cartY);
    x -= CART_W + GAP;
  }

  // Tipple over the newest cart, with a falling rock-drip while loading.
  drawSprite(ctx, TIPPLE, pal, tippleX, cartY - TIPPLE.length - 4);
  const last = carts[carts.length - 1];
  if (last && last.loading) {
    const dripY = cartY - 4 + Math.floor(phase * 6);
    ctx.fillStyle = DRIP;
    ctx.fillRect(tippleX + 6, dripY, 1, 2);
    ctx.fillRect(tippleX + 7, (dripY + 3) % (cartY - 1), 1, 1);
  }
}

// ---- component ----------------------------------------------------------------------------

const SCALE = 2; // css px per logical pixel — chunky enough to read as pixel art

// Decorative strip (aria-hidden: everything it shows, the chart above already shows) with a
// per-cart hover tooltip as a bonus. Redraws on every state refresh; a 250 ms four-step tick
// drives the chute drip and ore twinkle, skipped entirely under prefers-reduced-motion (the
// dashboard's first animation — keep it polite).
export class MineCartTrain extends Component {
  componentDidMount() {
    this.reduced =
      typeof window.matchMedia === "function" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    this.tick = 0;
    this.onResize = () => this.draw();
    window.addEventListener("resize", this.onResize);
    this.draw();
    if (!this.reduced) {
      this.timer = setInterval(() => {
        this.tick++;
        this.draw();
      }, 250);
    }
  }

  componentWillUnmount() {
    if (this.timer) clearInterval(this.timer);
    window.removeEventListener("resize", this.onResize);
  }

  componentDidUpdate() {
    this.draw();
  }

  draw() {
    const canvas = this.base && this.base.querySelector ? this.base.querySelector("canvas") : null;
    if (!canvas) return;
    const cssW = canvas.clientWidth;
    const cssH = STRIP_H * SCALE;
    const dpr = window.devicePixelRatio || 1;
    if (canvas.width !== Math.round(cssW * dpr)) {
      canvas.width = Math.round(cssW * dpr);
      canvas.height = Math.round(cssH * dpr);
    }
    // Cart count adapts to the width so the train fills the strip on any screen — each cart is
    // 1/count of the loaded window, and the tooltip states its exact interval. The cat's corner
    // is reserved out of the budget.
    const logicalW = cssW / SCALE;
    const count = Math.max(6, Math.min(24, Math.floor((logicalW - CAT_ZONE - 8) / (CART_W + GAP))));
    this.carts = cartsFromState(this.props.chart, this.props.blocks, count, this.props.payouts);
    if (!this.carts.length) return;
    const ctx = canvas.getContext("2d");
    ctx.setTransform(SCALE * dpr, 0, 0, SCALE * dpr, 0, 0);
    ctx.imageSmoothingEnabled = false;
    drawTrain(ctx, this.carts, logicalW, this.reduced ? 0 : this.tick);
  }

  // Map the hover position back to a cart (they're right-aligned) and surface its summary as
  // a native tooltip.
  onMove(e) {
    if (!this.carts || !this.carts.length) return;
    const canvas = e.currentTarget;
    const logicalX = (e.clientX - canvas.getBoundingClientRect().left) / SCALE;
    const w = canvas.clientWidth / SCALE;
    const fromRight = w - 4 - logicalX;
    const idx = this.carts.length - 1 - Math.floor(fromRight / (CART_W + GAP));
    const cart = this.carts[idx];
    canvas.title = cart ? cartTitle(cart) : "";
  }

  render({ chart }) {
    // Nothing to haul (fresh start, no history yet) → no strip at all, not an empty track.
    const hasData = chart && (chart.p2pool || []).some((p) => Number.isFinite(p.y));
    if (!hasData) return null;
    return html`
        <div class="minecart-strip" aria-hidden="true">
            <canvas onMouseMove=${(e) => this.onMove(e)}></canvas>
        </div>`;
  }
}

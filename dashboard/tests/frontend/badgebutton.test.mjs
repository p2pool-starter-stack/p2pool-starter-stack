// Unit tests for the badge chrome in mining_dashboard/web/static/dashboard.css (#1858).
//
// A badge renders as a <span>, an <a> or a <button>, and only the <button> arrives with UA chrome:
// Chromium paints it with the `ButtonFace` system colour (#efefef) and an outset border, neither of
// which follows our theme. In dark, `badge-outline`'s --text-muted on that fill measures 2.67:1 —
// below the 4.5:1 WCAG AA needs — so the "OS updates" badge alone was a light box in a dark header.
//
// These run with no DOM, so they prove the stylesheet's own cascade rather than a painted pixel:
// the reset is declared on `.badge`, it sits ABOVE the variants (equal specificity, so source order
// decides), and the pair the reset leaves behind clears AA in both themes.
// Run with: node --test dashboard/tests/frontend/
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";

import {
  contrastRatio,
  DARK_BLOCK,
  DASHBOARD_CSS,
  LIGHT_BLOCK,
  themeToken,
} from "./helpers/contrast.mjs";

const STATIC_DIR = new URL("../../mining_dashboard/web/static/", import.meta.url);

// The variants that carry a badge's colour. `badge-row` is a layout class, not a variant.
const VARIANTS = ["badge-outline", "badge-ok", "badge-bad", "badge-warn", "badge-accent", "badge-purple"];

test("dashboard.css: .badge clears the UA <button> fill and border (#1858)", () => {
  const rule = DASHBOARD_CSS.match(/^\.badge \{([^}]*)\}/m);
  assert.ok(rule, "expected a `.badge` rule in dashboard.css");
  assert.match(rule[1], /background:\s*transparent/, "a <button> badge would keep the UA ButtonFace fill");
  assert.match(rule[1], /border:\s*none/, "a <button> badge would keep the UA outset border");
});

test("dashboard.css: the reset sits above the variants, so their fills and border still win (#1858)", () => {
  // `.badge` and every `.badge-*` variant are single-class selectors, so specificity ties and the
  // LATER rule wins. Moving the reset below them would silently blank every coloured badge.
  const resetAt = DASHBOARD_CSS.search(/^\.badge \{/m);
  assert.ok(resetAt >= 0, "expected a `.badge` rule in dashboard.css");
  for (const variant of VARIANTS) {
    const at = DASHBOARD_CSS.search(new RegExp(`^\\.${variant} \\{`, "m"));
    assert.ok(at > resetAt, `.${variant} must be declared after .badge, or the reset overrides it`);
  }
  const outline = DASHBOARD_CSS.match(/^\.badge-outline \{([^}]*)\}/m);
  assert.match(outline[1], /border:\s*1px solid/, ".badge-outline must re-add the border .badge clears");
});

test("dashboard.css: a transparent badge button's muted text clears AA on the page background (#1858)", () => {
  // With the UA fill gone, an outline badge sits on the header, which sets no background of its own
  // — so the backdrop is --bg. Pre-fix this pair was --text-muted on #efefef: 2.67:1 in dark.
  // Not read here: the prefers-color-scheme auto block (dashboard.css:68-86), whose tokens are
  // byte-identical to the light block's today. A divergence there would pass this test unnoticed.
  for (const [theme, block] of [["dark", DARK_BLOCK], ["light", LIGHT_BLOCK]]) {
    const muted = themeToken(DASHBOARD_CSS, block, "--text-muted");
    const bg = themeToken(DASHBOARD_CSS, block, "--bg");
    const ratio = contrastRatio(muted, bg);
    assert.ok(ratio >= 4.5, `${theme} badge-outline contrast ${ratio.toFixed(2)}:1 is below AA (4.5:1)`);
  }
});

test("every element carrying a badge variant also carries the base badge class (#1858)", () => {
  // The reset keys on `.badge`, so a variant used without it silently misses the fix. Scanned from
  // the class attribute's literal text; a variant supplied by a concatenated expression (osupdate's
  // `attention`) is not visible here — that path is covered by the source-order test above.
  const files = readdirSync(STATIC_DIR).filter((f) => f.endsWith(".mjs"));
  assert.ok(files.length > 0, "expected to find static .mjs sources to scan");
  let checked = 0;
  for (const file of files) {
    const src = readFileSync(new URL(file, STATIC_DIR), "utf8");
    for (const m of src.matchAll(/class=(?:"([^"]*)"|\$\{"([^"]*)")/g)) {
      const classes = (m[1] ?? m[2]).split(/\s+/);
      if (!classes.some((c) => VARIANTS.includes(c))) continue;
      checked += 1;
      assert.ok(classes.includes("badge"), `${file}: "${m[1] ?? m[2]}" uses a variant without .badge`);
    }
  }
  assert.ok(checked > 0, "the scan matched no badge variants at all — the needle is broken");
});

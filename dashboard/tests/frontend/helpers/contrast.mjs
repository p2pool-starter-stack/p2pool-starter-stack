// WCAG contrast helpers shared by the stylesheet tests (#1232, #1858). The ratio is the
// relative-luminance formula computed directly from the theme tokens dashboard.css declares — not a
// rendered or measured colour, since these tests run with no DOM. AA for normal text is 4.5:1.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

export const DASHBOARD_CSS = readFileSync(
  new URL("../../../mining_dashboard/web/static/dashboard.css", import.meta.url),
  "utf8",
);

// Dark is the base palette (`:root`); light is the explicit override block. Pull each pair
// independently — the two blocks declare the same variable names to different values.
export const DARK_BLOCK = /:root,\s*:root\[data-theme="dark"\]\s*\{[^}]*\}/;
export const LIGHT_BLOCK = /:root\[data-theme="light"\]\s*\{[^}]*\}/;

function srgbToLinear(c) {
  const v = c / 255;
  return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
}

function relativeLuminance(hex) {
  const n = Number.parseInt(hex.replace("#", ""), 16);
  const r = srgbToLinear((n >> 16) & 0xff);
  const g = srgbToLinear((n >> 8) & 0xff);
  const b = srgbToLinear(n & 0xff);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrastRatio(hexA, hexB) {
  const [l1, l2] = [relativeLuminance(hexA), relativeLuminance(hexB)].sort((a, b) => b - a);
  return (l1 + 0.05) / (l2 + 0.05);
}

export function themeToken(css, themeBlockRe, varName) {
  const block = css.match(themeBlockRe);
  assert.ok(block, `expected to find the ${varName} theme block in dashboard.css`);
  const tok = block[0].match(new RegExp(`${varName}:\\s*(#[0-9a-fA-F]{6})`));
  assert.ok(tok, `expected ${varName} inside the matched theme block`);
  return tok[1];
}

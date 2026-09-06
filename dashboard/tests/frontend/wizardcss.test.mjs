// The wizard's stylesheet, asserted the way workerview.test.mjs asserts dashboard.css: parse the
// file and read the declarations. This proves the RULE IS DECLARED and that the markup it targets
// still exists — it does not lay the page out, so it cannot prove a glyph landed inside the card.
// The behavioural evidence for #1879 is the Chromium measurement in the issue (390 px: the card's
// content box is 332 px and documentElement.scrollWidth was 446).

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

const WIZARD_CSS = read("../../mining_dashboard/web/static/wizard.css");
const WIZARD_MJS = read("../../mining_dashboard/web/static/wizard.mjs");
const WIZARD_HTML = read("../../mining_dashboard/web/templates/wizard.html");

// The rule under test, found by its selector rather than by position, so reordering the file does
// not move the test.
function ruleFor(css, selectorRe) {
  const m = css.match(new RegExp(`(^|\\})\\s*(${selectorRe.source})\\s*\\{([^}]*)\\}`, "m"));
  return m ? { selector: m[2].trim(), body: m[3] } : null;
}

test("wizard.css: a value inside the wizard breaks rather than running past the card (#1879)", () => {
  const rule = ruleFor(WIZARD_CSS, /\.wizard-shell\s+code/);
  assert.ok(rule, "expected a `.wizard-shell code` rule in wizard.css");
  assert.match(
    rule.body,
    /overflow-wrap:\s*anywhere/,
    "the control token and the stratum URL have no break opportunity of their own; without " +
      "overflow-wrap the .config-field value column takes its width from the string itself",
  );
});

test("wizard.css: the break rule is scoped to <code>, so the JSON editor keeps its own wrapping", () => {
  // .wizard-mono is also on three <input> and on the config textarea (wizard.mjs). Breaking JSON
  // mid-token is a change to a surface nobody reported, so the rule names an element, not the class.
  const mono = ruleFor(WIZARD_CSS, /\.wizard-mono/);
  assert.ok(mono, "expected the .wizard-mono font rule to still exist");
  assert.doesNotMatch(
    mono.body,
    /overflow-wrap|word-break/,
    ".wizard-mono is shared with inputs and the JSON textarea — keep it font-only",
  );
});

// The two ways the rule above goes dead without anything failing: the mount loses the class the
// selector descends from, or the values stop being <code>. Both are one careless edit away, and
// neither shows up in a screenshot of the desktop layout.

test("wizard.html: the app mounts inside .wizard-shell, which the break rule descends from", () => {
  assert.match(WIZARD_HTML, /<main[^>]*id="app"[^>]*class="[^"]*\bwizard-shell\b/);
});

test("wizard.mjs: the handoff values the operator transcribes are still <code> elements", () => {
  // The rig card's rows (#1836) and the coordinator card's four values are the sites the issue
  // measured. Each renders its value in a <code>; a <span> here would leave the rule matching
  // nothing while every other test stayed green.
  // Same line, so `.` is enough and the callback's own parentheses do not end the match early.
  assert.match(WIZARD_MJS, /rigCardFields\(handoff\)\.map\(.*<code\b/);
  for (const label of ["Dashboard password", "Point miners at"]) {
    assert.match(
      WIZARD_MJS,
      new RegExp(`label="${label}"><code\\b`),
      `${label} renders its value outside a <code>, so the wrap rule no longer covers it`,
    );
  }
});

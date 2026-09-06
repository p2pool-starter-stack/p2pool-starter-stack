// The wizard's shell and chrome (#1868), asserted the way workerview.test.mjs asserts dashboard.css:
// parse the files and read what they declare. These are static assertions — no layout engine runs
// here, so nothing below proves a rendered button measured 32 px. What they DO hold is the property
// that broke: a control that carries no class at all falls through to the user-agent style, and a
// mount that is never cleared keeps whatever the server shipped inside it.
//
// A new file rather than wizard.test.mjs, which is at 765 against a 765 ceiling.

import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import test from "node:test";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const WIZARD_MJS = read("../../mining_dashboard/web/static/wizard.mjs");
const WIZARD_CSS = read("../../mining_dashboard/web/static/wizard.css");
const WIZARD_HTML = read("../../mining_dashboard/web/templates/wizard.html");

function ruleFor(css, selectorRe) {
  const m = css.match(new RegExp(`(^|\\})\\s*(${selectorRe.source})\\s*\\{([^}]*)\\}`, "m"));
  return m ? { selector: m[2].trim(), body: m[3] } : null;
}

// The wizard's view modules, found by the import they share rather than by a hand-kept list — a new
// view that renders a button is then covered the day it is written. The first sweep here read only
// wizard.mjs and was blind to savedrole.mjs's "Keep it", which is exactly this defect in a file the
// needle never looked at.
const STATIC = new URL("../../mining_dashboard/web/static/", import.meta.url);
const VIEWS = readdirSync(STATIC)
  .filter((f) => f.endsWith(".mjs"))
  .map((f) => [f, readFileSync(new URL(f, STATIC), "utf8")])
  .filter(([f, src]) => f === "wizard.mjs" || src.includes("./wizardparts.mjs"));

test("every wizard view: a button declares a class, so none falls through to the browser default", () => {
  // An enumeration that quietly found nothing would pass this test while proving nothing, so the
  // root is asserted before the property is.
  assert.ok(VIEWS.length >= 2, `expected the wizard's view modules, found ${VIEWS.length}`);
  assert.ok(
    VIEWS.some(([f]) => f === "savedrole.mjs"),
    "savedrole.mjs no longer matches the wizard-view marker — widen the root, do not narrow the claim",
  );
  const bare = [];
  for (const [file, src] of VIEWS) {
    // Each opening tag, taken as the text after `<button` up to a comfortable bound: the tag can
    // hold arrow functions, so scanning for the closing `>` would stop at the first `=>`.
    for (const tag of src.split("<button").slice(1).map((s) => s.slice(0, 200))) {
      if (!/class="(btn-toggle[^"]*|wizard-link)"/.test(tag)) {
        bare.push(`${file}: <button${tag.split("\n")[0].trim()}`);
      }
    }
  }
  assert.deepEqual(
    bare,
    [],
    "a button with no class renders as the user-agent control (#1868): give it the dashboard's " +
      "btn-toggle skin, or wizard-link if it is deliberately a text link",
  );
});

test("wizard.css: a standalone button gets the border and radius .btn-toggle takes from its parent", () => {
  const rule = ruleFor(WIZARD_CSS, /\.wizard-shell\s+button:not\(\.wizard-link\)/);
  assert.ok(rule, "expected a `.wizard-shell button:not(.wizard-link)` rule in wizard.css");
  assert.match(rule.body, /border:\s*1px solid var\(--border\)/);
  assert.match(rule.body, /border-radius:/);
});

test("wizard.css: the button's target size clears WCAG 2.2 SC 2.5.8 (24px) as a declared floor", () => {
  const rule = ruleFor(WIZARD_CSS, /\.wizard-shell\s+button:not\(\.wizard-link\)/);
  const mh = rule.body.match(/min-height:\s*(\d+)px/);
  assert.ok(mh, "expected an explicit min-height rather than one implied by padding + line-height");
  assert.ok(
    Number(mh[1]) >= 24,
    `min-height ${mh[1]}px is below the 24px target-size floor (SC 2.5.8)`,
  );
});

test("wizard.mjs: the mount clears #app, which the shell deliberately ships non-empty", () => {
  // The two halves are a pair: the template ships the heading and "Loading…" inside #app so a curl
  // can recognize the page, and preact's render appends. Assert both, or a later edit to either one
  // silently restores the residue.
  assert.match(WIZARD_HTML, /<main[^>]*id="app"[^>]*>\s*<h1>/, "the shell still ships markup in #app");
  const mount = WIZARD_MJS.slice(WIZARD_MJS.indexOf('typeof document !== "undefined"'));
  const clearAt = mount.indexOf("replaceChildren()");
  const renderAt = mount.indexOf("render(");
  assert.ok(clearAt !== -1, "#app is never cleared, so the shell's markup outlives every stage");
  assert.ok(clearAt < renderAt, "#app must be cleared BEFORE render, not after");
});

test("wizard.css: a section heading is spaced from the field above, but not when it opens a card", () => {
  const h3 = ruleFor(WIZARD_CSS, /\.wizard-shell\s+h3/);
  assert.ok(h3, "expected a `.wizard-shell h3` rule");
  assert.match(h3.body, /margin-top:\s*[1-9]/, "a heading with no top margin reads as the label of the field above it");
  const first = ruleFor(WIZARD_CSS, /\.wizard-shell\s+h3:first-child/);
  assert.ok(first, "expected the :first-child reset");
  assert.match(first.body, /margin-top:\s*0/);
});

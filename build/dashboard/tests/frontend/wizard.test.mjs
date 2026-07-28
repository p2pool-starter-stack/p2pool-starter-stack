// Render probes for the wizard's views (mining_dashboard/web/static/wizard.mjs) — the UX
// promises that used to be asserted against server-rendered HTML, now asserted at the layer
// that actually renders them. Uses the repo's dependency-free vnode walker; no DOM.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test build/dashboard/tests/frontend/
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  Done,
  Gate,
  Installing,
  InstallView,
} from "../../mining_dashboard/web/static/wizard.mjs";
import { html } from "../../mining_dashboard/web/static/preact.mjs";
import { renderToString } from "./helpers/render.mjs";

const DISKS = [
  { name: "nvme0n1", size: "931.5G", model: "Samsung SSD 990", serial: "S6P1NF0T", state: "empty" },
  { name: "sda", size: "3.6T", model: "WDC WD40EFRX", serial: "WD-WCC7K3", state: "pithead-with-data" },
];

test("gate: says the token is case- and prefix-forgiving", () => {
  const out = renderToString(html`<${Gate} error="" onSubmit=${() => {}} />`);
  assert.match(out, /Case doesn't matter/);
  assert.match(out, /pit-/);
});

test("picker: the consequence sits before the truncation point, per disk state", () => {
  const out = renderToString(
    html`<${InstallView} disks=${DISKS} error="" chosen="" confirm=""
      onPick=${() => {}} onConfirm=${() => {}} onSubmit=${() => {}} />`,
  );
  // A <select> truncates on the right; bench screenshots cut off exactly the erase/keep words.
  assert.ok(out.indexOf("nvme0n1 — ERASES everything on it") < out.indexOf("931.5G"));
  assert.ok(out.indexOf("sda — KEEPS existing data") < out.indexOf("3.6T"));
  // Model and serial show — a bare /dev/sda is not enough to choose safely.
  assert.match(out, /Samsung SSD 990/);
  assert.match(out, /S6P1NF0T/);
});

test("picker: restates the choice in full below the control, red when destructive", () => {
  const destructive = renderToString(
    html`<${InstallView} disks=${DISKS} error="" chosen="nvme0n1" confirm=""
      onPick=${() => {}} onConfirm=${() => {}} onSubmit=${() => {}} />`,
  );
  assert.match(destructive, /Installing to nvme0n1 — this ERASES everything on it/);
  assert.match(destructive, /c-bad/);
  const keeps = renderToString(
    html`<${InstallView} disks=${DISKS} error="" chosen="sda" confirm=""
      onPick=${() => {}} onConfirm=${() => {}} onSubmit=${() => {}} />`,
  );
  assert.match(keeps, /Installing to sda — this KEEPS existing data/);
});

test("installing: the completion is the shutdown, steps in un-swappable order", () => {
  const out = renderToString(html`<${Installing} status="Installed — the machine…" />`);
  assert.ok(out.indexOf("switch itself off") < out.indexOf("Remove the USB stick"));
  assert.ok(out.indexOf("Remove the USB stick") < out.indexOf("Switch it back on"));
});

test("done without a handoff yet: names the dark period and where the dashboard appears", () => {
  // Before the host publishes credentials (or on the fallback timeout), the page must already
  // say that going unresponsive IS the machine working — a bench session read the dark period
  // as a crash.
  const out = renderToString(html`<${Done} status="" handoff=${null} acked=${false} onAck=${() => {}} />`);
  assert.match(out, /stop responding/);
  assert.match(out, /pithead\.local/);
});

test("handoff card: credentials shown once, provisioning gated on the ack", () => {
  const handoff = {
    username: "admin",
    password: "rX6d2A4sGBHFEcQT4TVQQJRQg7xtbDMg",
    dashboard: "https://pithead.local",
    stratum: "stratum+tcp://pithead.local:3333",
  };
  const card = renderToString(html`<${Done} status="" handoff=${handoff} acked=${false} onAck=${() => {}} />`);
  assert.match(card, /Save this before anything else/);
  assert.match(card, /rX6d2A4sGBHFEcQT4TVQQJRQg7xtbDMg/);
  assert.match(card, /stratum\+tcp:\/\/pithead\.local:3333/);
  assert.match(card, /I saved these/);
  // After the ack: the dark period is NAMED, so a dead tab reads as the machine working.
  const dark = renderToString(html`<${Done} status="" handoff=${handoff} acked=${true} onAck=${() => {}} />`);
  assert.match(dark, /stop responding/);
  assert.match(dark, /pithead\.local/);
});

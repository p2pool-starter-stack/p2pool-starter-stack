// Failed-install rendering and refresh recovery through the real WizardApp seam.
import assert from "node:assert/strict";
import { test } from "node:test";

import { WizardApp } from "../../mining_dashboard/web/static/wizard.mjs";
import {
  backToSettings,
  InstallFailed,
  restoredAttempt,
} from "../../mining_dashboard/web/static/wizardfailure.mjs";
import { html } from "../../mining_dashboard/web/static/preact.mjs";
import { renderToString } from "./helpers/render.mjs";

const REF = {
  monero: { wallet_address: "", mode: "local" },
  dashboard: { auth: { password: "" } },
  xvb: { enabled: true },
};

const FAILED = {
  stage: "failed",
  config: {
    monero: { wallet_address: "4PAYOUT", mode: "local" },
    dashboard: { auth: { password: "fixture-login-password" } },
    xvb: { enabled: false },
  },
  reference: REF,
  error: "remote Tari node did not answer",
  disks: [{ name: "sda", state: "pithead-with-data" }],
  handoff: null,
  install_attempt: { disk: "sda", wipe: "data" },
  auth_mode: "set",
  config_changes: ["xmrig_proxy.enabled → xvb.enabled"],
};

function stubSetState(app) {
  app.setState = (patch) => Object.assign(app.state, patch);
}

test("failed view ends the installing warning and offers one return action", () => {
  const out = renderToString(
    html`<${InstallFailed} error=${FAILED.error} changes=${FAILED.config_changes} onBack=${() => {}} />`,
  );
  assert.match(out, /Installation failed/);
  assert.match(out, /remote Tari node did not answer/);
  assert.match(out, /Back to the settings/);
  assert.match(out, /class="btn-toggle active"/);
  assert.match(out, /xmrig_proxy\.enabled/);
  assert.doesNotMatch(out, /Do not power it off|Working…|Loading…/);
  assert.equal((out.match(/<button/g) || []).length, 1);
});

test("same-tab failure restores fields but clears the destructive confirmation", async () => {
  const app = new WizardApp({});
  stubSetState(app);
  app.poll = () => {};
  Object.assign(app.state, {
    stage: "setup",
    confirm: "sda",
    chosen: "sda",
    wipe: "data",
    cfg: FAILED.config,
  });
  const real = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, status: 200, json: async () => FAILED });
  await app.loadState();
  globalThis.fetch = real;
  assert.equal(app.state.stage, "failed");
  assert.equal(app.state.cfg.monero.wallet_address, "4PAYOUT");
  assert.equal(app.state.cfg.dashboard.auth.password, "fixture-login-password");
  assert.equal(app.state.chosen, "sda");
  assert.equal(app.state.wipe, "data");
  assert.equal(app.state.authMode, "set");
  assert.equal(app.state.confirm, "");
  assert.match(renderToString(app.render()), /Back to the settings/);
});

test("return action posts once, then follows the server back to the retained form", async () => {
  const app = new WizardApp({});
  stubSetState(app);
  Object.assign(app.state, restoredAttempt(FAILED, app.state), {
    stage: "failed",
    error: FAILED.error,
    cfg: FAILED.config,
    reference: REF,
    disks: FAILED.disks,
    installer: false,
  });
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, options = {}) => {
    calls.push([String(url), options.method || "GET"]);
    if (String(url) === "/retry") return { ok: true, status: 200 };
    return {
      ok: true,
      status: 200,
      json: async () => ({ ...FAILED, stage: "installer", error: null }),
    };
  };
  await backToSettings(app);
  globalThis.fetch = real;
  assert.deepEqual(calls, [["/retry", "POST"], ["/api/wizard-state", "GET"]]);
  assert.equal(app.state.stage, "setup");
  assert.equal(app.state.installer, true);
  assert.equal(app.state.cfg.monero.wallet_address, "4PAYOUT");
  assert.equal(app.state.chosen, "sda");
  assert.equal(app.state.confirm, "");
  const form = renderToString(app.render());
  assert.match(form, /Monero payout address/);
  assert.match(form, /4PAYOUT/);
  assert.match(form, /Adjusted for Pithead 2\.0/);
});

test("return action says to reload if the reopened state cannot be fetched", async () => {
  const app = new WizardApp({});
  stubSetState(app);
  app.loadState = async () => false;
  const real = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, status: 200 });
  assert.equal(await backToSettings(app), false);
  globalThis.fetch = real;
  assert.equal(app.state.error, "Settings reopened. Reload this page to continue.");
});

test("valid installing state still maps to the installing view", async () => {
  const app = new WizardApp({});
  stubSetState(app);
  const real = globalThis.fetch;
  globalThis.fetch = async () => ({
    ok: true,
    status: 200,
    json: async () => ({ ...FAILED, stage: "installing", error: null }),
  });
  await app.loadState();
  globalThis.fetch = real;
  assert.equal(app.state.stage, "installing");
  assert.match(renderToString(app.render()), /Installing/);
  assert.doesNotMatch(renderToString(app.render()), /Back to the settings/);
});

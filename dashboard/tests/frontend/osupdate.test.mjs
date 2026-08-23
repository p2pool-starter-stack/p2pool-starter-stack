// Appliance OS-update control: the resumable download chain (partial -> resubmit -> resume),
// the progress-aware poll, the verdict banner, and the render gates. The host makes every real
// judgment — these tests only check the client sequences the asks and renders the answers.
//
// Run with Node's built-in test runner:
//     node --test dashboard/tests/frontend/*.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  fmtMiB,
  osAction,
  OsUpdateControl,
  OsVerdictBanner,
  pollOsResult,
  releaseNotesHref,
  runOsDownload,
  verdictText,
} from "../../mining_dashboard/web/static/osupdate.mjs";
import { renderToString } from "./helpers/render.mjs";

const ID = "22222222-2222-4222-8222-222222222222";
const okResult = (body) => ({ status: 200, ok: true, json: async () => body });

async function withFastPoll(fetchStub, fn) {
  const realFetch = globalThis.fetch;
  const realTimeout = globalThis.setTimeout;
  globalThis.fetch = fetchStub;
  globalThis.setTimeout = (cb) => {
    cb();
    return 0;
  };
  try {
    return await fn();
  } finally {
    globalThis.fetch = realFetch;
    globalThis.setTimeout = realTimeout;
  }
}

test("osAction posts the typed step with the CSRF header and returns the id", async () => {
  let posted = null;
  await withFastPoll(
    async (url, opts) => {
      posted = { url, opts };
      return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
    },
    async () => {
      assert.equal(await osAction("download", "v1.19.0"), ID);
    },
  );
  assert.equal(posted.url, "/api/control/os-update");
  assert.equal(posted.opts.headers["X-Pithead-Control"], "1");
  assert.deepEqual(JSON.parse(posted.opts.body), { action: "download", version: "v1.19.0" });
});

test("pollOsResult surfaces progress and returns the terminal result", async () => {
  let polls = 0;
  const seen = [];
  const out = await withFastPoll(
    async () => {
      polls++;
      if (polls === 1) return okResult({ status: "downloading", bytes: 10, total: 100 });
      if (polls === 2) return okResult({ status: "downloading", bytes: 60, total: 100 });
      return okResult({ status: "downloaded", version: "v1.19.0" });
    },
    () => pollOsResult(ID, (p) => seen.push(p.bytes)),
  );
  assert.equal(out.status, "downloaded");
  assert.deepEqual(seen, [10, 60]); // progress reached the caller instead of being skipped
});

test("pollOsResult rides out 202 and proxy 50x while the host works", async () => {
  let polls = 0;
  const out = await withFastPoll(
    async () => {
      polls++;
      if (polls === 1) return { status: 202, ok: false, json: async () => ({}) };
      if (polls === 2) return { status: 503, ok: false, json: async () => ({}) };
      return okResult({ status: "verified" });
    },
    () => pollOsResult(ID),
  );
  assert.equal(out.status, "verified");
});

test("runOsDownload resubmits on 'partial' so the transfer resumes, then returns the terminal", async () => {
  const submitted = [];
  const results = [
    { status: "partial", bytes: 300, total: 1000 },
    { status: "partial", bytes: 700, total: 1000 },
    { status: "downloaded", version: "v1.19.0", resumed_from: 700 },
  ];
  const out = await runOsDownload(
    "v1.19.0",
    null,
    () => false,
    async (action, version) => {
      submitted.push([action, version]);
      return ID;
    },
    async () => results.shift(),
  );
  assert.equal(out.status, "downloaded");
  assert.equal(submitted.length, 3); // one intent per attempt — each resumes host-side
  assert.deepEqual(submitted[0], ["download", "v1.19.0"]);
});

test("runOsDownload stops between attempts when cancelled — the partial stays resumable", async () => {
  let stopped = false;
  const out = await runOsDownload(
    "v1.19.0",
    null,
    () => stopped,
    async () => {
      stopped = true; // cancel arrives during the first attempt
      return ID;
    },
    async () => ({ status: "partial", bytes: 300, total: 1000 }),
  );
  assert.equal(out.status, "cancelled");
  assert.equal(out.bytes, 300); // the caller can say where a later Retry resumes from
});

test("runOsDownload passes a rejection through as the outcome", async () => {
  const out = await runOsDownload(
    "v1.19.0",
    null,
    () => false,
    async () => ID,
    async () => ({ status: "rejected", error: "not enough free space" }),
  );
  assert.equal(out.status, "rejected");
  assert.match(out.error, /free space/);
});

test("verdictText covers both outcomes and stays quiet otherwise", () => {
  assert.equal(verdictText({ outcome: "updated", to: "1.19.0" }), "System updated to v1.19.0.");
  assert.match(
    verdictText({ outcome: "rolled_back", from: "1.18.1", to: "1.19.0" }),
    /v1\.19\.0 failed .* rolled back automatically — still on v1\.18\.1/,
  );
  assert.equal(verdictText(null), null);
  assert.equal(verdictText({ outcome: "weird" }), null);
});

test("fmtMiB rounds to MiB and stays empty for the unknowable", () => {
  assert.equal(fmtMiB(1048576), "1 MiB");
  assert.equal(fmtMiB(1073741824), "1024 MiB");
  assert.equal(fmtMiB(0), "");
  assert.equal(fmtMiB(undefined), "");
});

// --- render gates -------------------------------------------------------------------------

function inst(props) {
  const c = new OsUpdateControl(props);
  c.props = props;
  return c;
}

test("OsUpdateControl renders nothing off the appliance or with control off", () => {
  assert.equal(renderToString(inst({ os: null, enabled: true }).render()), "");
  assert.equal(renderToString(inst({ os: { step: "idle" }, enabled: false }).render()), "");
});

test("OsUpdateControl reads loud when an update is available, quiet otherwise", () => {
  const quiet = renderToString(inst({ os: { step: "idle" }, enabled: true }).render());
  assert.match(quiet, /OS updates/);
  assert.match(quiet, /badge-outline/);
  const loud = renderToString(
    inst({
      os: { step: "idle" },
      update: { available: true, latest: "v1.19.0" },
      enabled: true,
    }).render(),
  );
  assert.match(loud, /OS update v1\.19\.0/);
  assert.match(loud, /badge-accent/);
});

test("OsUpdateControl surfaces a host-remembered reboot-pending step on the button", () => {
  const out = renderToString(
    inst({ os: { step: "reboot-pending", version: "1.19.0" }, enabled: true }).render(),
  );
  assert.match(out, /reboot to finish/);
});

test("releaseNotesHref pins the link to the public GitHub release page", () => {
  const gh = "https://github.com/p2pool-starter-stack/pithead/releases/tag/v1.19.0";
  assert.equal(releaseNotesHref(gh), gh);
  assert.equal(releaseNotesHref("https://evil.invalid/rel"), null);
  assert.equal(releaseNotesHref("http://github.com/x"), null); // scheme matters, not just host
  assert.equal(releaseNotesHref("javascript:alert(1)"), null);
  assert.equal(releaseNotesHref(undefined), null);
});

test("a non-GitHub notes href renders no link — host-relayed data is data, not a URL", () => {
  const c = inst({
    os: { step: "idle" },
    update: { available: true, latest: "v1.19.0", url: "https://evil.invalid/rel" },
    version: { text: "v1.18.1" },
    enabled: true,
  });
  c.state.phase = "idle";
  const out = renderToString(c.render());
  assert.match(out, /v1\.19\.0 is available/);
  assert.doesNotMatch(out, /Release notes/);
});

test("the idle modal offers Download with size and notes when an update is available", () => {
  const c = inst({
    os: { step: "idle" },
    update: {
      available: true,
      latest: "v1.19.0",
      url: "https://github.com/p2pool-starter-stack/pithead/releases/tag/v1.19.0",
      raucb_size: 1048576,
    },
    version: { text: "v1.18.1" },
    enabled: true,
  });
  c.state.phase = "idle";
  const out = renderToString(c.render());
  assert.match(out, /Running v1\.18\.1/);
  assert.match(out, /v1\.19\.0 is available/);
  assert.match(out, /1 MiB download/);
  assert.match(out, /Release notes/);
  assert.match(out, /Download/);
  assert.match(out, /Check now/);
});

test("the downloading modal shows resumable progress, the Tor warning, and Cancel", () => {
  const c = inst({
    os: { step: "downloading", version: "1.19.0" },
    enabled: true,
  });
  c.state.phase = "downloading";
  c.state.progress = { bytes: 314572800, total: 1048576000 };
  const out = renderToString(c.render());
  assert.match(out, /300 MiB of 1000 MiB \(30%\)/);
  assert.match(out, /Over Tor — this can be slow/);
  assert.match(out, /resumes where it stopped/);
  assert.match(out, /Cancel/);
});

test("the reboot gate requires the typed REBOOT and says mining pauses", () => {
  const c = inst({ os: { step: "reboot-pending", version: "1.19.0" }, enabled: true });
  c.state.phase = "reboot-pending";
  const out = renderToString(c.render());
  assert.match(out, /Mining pauses/);
  assert.match(out, /Type <code>REBOOT<\/code>/);
  assert.match(out, /returns to the\s+current one on its own/);
  // The gate is only a gate if it is CLOSED before the word is typed. Asserting the armed state
  // alone passes with the whole confirmation deleted — and that gate is what stands between a
  // stray click and rebooting a mining box. Both sides, in order.
  assert.match(out, /disabled[^>]*>\s*Reboot now/);
  c.state.confirmText = "REBOO";
  assert.match(renderToString(c.render()), /disabled[^>]*>\s*Reboot now/);
  c.state.confirmText = "REBOOT";
  assert.doesNotMatch(renderToString(c.render()), /disabled.*Reboot now/);
});

test("reboot() surfaces a host rejection instead of silently reconnecting (#1050)", async () => {
  // The 24h install-authorization window can expire between the modal opening and the click.
  // The host refuses (and, since the #1050 fix, re-arms its own persisted state) — but the
  // machine never went down, so blindly reconnecting used to reload straight back into the
  // exact same "reboot-pending" modal with no explanation at all.
  // setState on an unmounted component lands in _nextState, not this.state (same caveat the
  // download tests above already work around), so this spies on fail()/reconnect() directly
  // rather than reading state back off the instance.
  const c = inst({ os: { step: "reboot-pending", version: "1.19.0" }, enabled: true });
  c.state.phase = "reboot-pending";
  let reconnectCalled = false;
  let failedWith = null;
  c.reconnect = () => {
    reconnectCalled = true;
  };
  c.fail = (e) => {
    failedWith = String((e && e.message) || e);
  };
  await withFastPoll(
    async (url, opts) => {
      if (opts && opts.method === "POST") {
        return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
      }
      return okResult({
        status: "rejected",
        error: "the installed update has been waiting more than a day and has expired — check for updates again; a fresh verify and install re-arms the reboot.",
      });
    },
    () => c.reboot(),
  );
  assert.equal(reconnectCalled, false);
  assert.match(failedWith, /re-arms the reboot/);
});

test("reboot() still reconnects when the host actually accepts the reboot", async () => {
  const c = inst({ os: { step: "reboot-pending", version: "1.19.0" }, enabled: true });
  c.state.phase = "reboot-pending";
  let reconnectCalled = false;
  c.reconnect = () => {
    reconnectCalled = true;
  };
  await withFastPoll(
    async (url, opts) => {
      if (opts && opts.method === "POST") {
        return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
      }
      return okResult({ status: "rebooting" });
    },
    () => c.reboot(),
  );
  assert.equal(reconnectCalled, true);
});

test("Download with only a passive badge asks the host to check before it downloads", async () => {
  // The first thing a fresh appliance ever does with this feature. target.json is written only by
  // os-check, so a download posted straight off the passive badge is refused by the host and the
  // error pane's Retry re-posts it forever. The client must resolve the target itself first.
  const posted = [];
  const c = inst({ os: { step: "idle" }, update: { available: true, latest: "v1.19.0" }, enabled: true });
  await withFastPoll(async (url, opts) => {
    if (opts && opts.method === "POST") {
      posted.push(JSON.parse(opts.body));
      return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
    }
    const action = posted[posted.length - 1].action;
    if (action === "check")
      return okResult({ id: ID, status: "checked", version: "v1.19.2", newer: true, size: 1 });
    return okResult({ id: ID, status: "downloaded", version: "v1.19.2" });
  }, () => c.download());
  assert.equal(posted[0].action, "check");
  // and the download that follows carries the version the HOST resolved, not the stale badge
  assert.deepEqual(posted[1], { action: "download", version: "v1.19.2" });
});

test("a stale badge whose check comes back not-newer stops, instead of posting a doomed download", async () => {
  // The other half of the same loop: the host refuses an equal version, so posting one lands in the
  // error pane whose Retry posts it again. Nothing should be downloaded at all here.
  const posted = [];
  const c = inst({ os: { step: "idle" }, update: { available: true, latest: "v1.19.0" }, enabled: true });
  await withFastPoll(async (url, opts) => {
    if (opts && opts.method === "POST") {
      posted.push(JSON.parse(opts.body));
      return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
    }
    return okResult({ id: ID, status: "checked", version: "v1.19.0", newer: false });
  }, () => c.download());
  // The whole assertion is what was NOT posted: one check, no download. (Phase is not readable
  // here — setState on an unmounted component lands in _nextState, not this.state.)
  assert.deepEqual(posted.map((p) => p.action), ["check"]);
});

test("the error state offers Retry (which resumes) and shows the host's words", () => {
  const c = inst({
    os: { step: "downloading", version: "1.19.0" },
    update: { available: true, latest: "v1.19.0" },
    enabled: true,
  });
  c.state.phase = "error";
  c.state.error = "the download failed over Tor at 300 of 1000 bytes";
  const out = renderToString(c.render());
  assert.match(out, /download failed over Tor/);
  assert.match(out, /Retry/);
});

test("OsVerdictBanner renders the outcome and nothing without one", () => {
  assert.equal(renderToString(OsVerdictBanner({ os: { step: "idle" } })), "");
  const out = renderToString(
    OsVerdictBanner({
      os: { step: "idle", verdict: { outcome: "rolled_back", from: "1.18.1", to: "1.19.0", ts: 5 } },
    }),
  );
  assert.match(out, /rolled back automatically/);
  assert.match(out, /Dismiss/);
});

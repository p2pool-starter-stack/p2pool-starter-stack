// Unit tests for Worker Inspect's writable-config editor logic (#518):
// mining_dashboard/web/static/workerlogic.mjs — flattening the writable allowlist + last-applied
// config into table rows, and folding table/JSON edits back into the `changes` diff.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  buildChartMarkers,
  buildFields,
  buildTableChanges,
  configDriftNote,
  configRevisionDriftNote,
  fieldNote,
  jsonSyntaxError,
  markerLabel,
  parseJsonChanges,
  writableSnapshot,
} from "../../mining_dashboard/web/static/workerlogic.mjs";

const KEYS = ["DONATION", "max_temp_c", "watchdog", "pools", "token"];
const APPLIED = {
  DONATION: 5,
  max_temp_c: 70,
  watchdog: true,
  pools: [{ url: "pool.example:3333" }],
  token: { __secret__: true },
};

// --- buildFields --------------------------------------------------------------------------

test("buildFields: one row per writable key, typed off the last-applied value", () => {
  const fields = Object.fromEntries(buildFields(KEYS, APPLIED).map((f) => [f.key, f]));
  assert.equal(fields.DONATION.type, "number");
  assert.equal(fields.DONATION.value, 5);
  assert.equal(fields.max_temp_c.type, "number");
  assert.equal(fields.watchdog.type, "boolean");
  assert.equal(fields.watchdog.value, true);
  assert.equal(fields.pools.type, "json");
  assert.match(fields.pools.value, /pool\.example:3333/);
});

test("buildFields: a never-applied key gets an empty JSON row, not a crash", () => {
  const fields = Object.fromEntries(buildFields(KEYS, {}).map((f) => [f.key, f]));
  assert.equal(fields.DONATION.type, "json");
  assert.equal(fields.DONATION.value, "");
});

test("buildFields: a masked token sentinel renders as a secret row, never raw JSON (#508)", () => {
  const fields = Object.fromEntries(buildFields(KEYS, APPLIED).map((f) => [f.key, f]));
  assert.equal(fields.token.type, "secret");
  assert.equal(fields.token.value, ""); // blank prefill — the sentinel itself never reaches the row
});

// --- buildTableChanges ---------------------------------------------------------------------

test("buildTableChanges: only touched rows enter the diff", () => {
  const fields = buildFields(KEYS, APPLIED);
  const changes = buildTableChanges(fields, { DONATION: "6" });
  assert.deepEqual(changes, { DONATION: 6 });
});

test("buildTableChanges: a row typed back to its original value drops out of the diff", () => {
  const fields = buildFields(KEYS, APPLIED);
  const changes = buildTableChanges(fields, { DONATION: "5", max_temp_c: "75" });
  assert.deepEqual(changes, { max_temp_c: 75 });
});

test("buildTableChanges: boolean and JSON sub-rows coerce back to real types", () => {
  const fields = buildFields(KEYS, APPLIED);
  const changes = buildTableChanges(fields, {
    watchdog: "false",
    pools: '[{"url":"pool2.example:3333"}]',
  });
  assert.deepEqual(changes, { watchdog: false, pools: [{ url: "pool2.example:3333" }] });
});

test("buildTableChanges: an unparsable JSON sub-row throws for the caller to surface", () => {
  const fields = buildFields(KEYS, APPLIED);
  assert.throws(() => buildTableChanges(fields, { pools: "{not json" }));
});

test("buildTableChanges: a blank secret row leaves the masked token alone; a typed one replaces it (#508)", () => {
  const fields = buildFields(KEYS, APPLIED);
  assert.deepEqual(buildTableChanges(fields, { token: "" }), {});
  assert.deepEqual(buildTableChanges(fields, { token: "new-token-value" }), {
    token: "new-token-value",
  });
});

// --- parseJsonChanges / jsonSyntaxError -----------------------------------------------------

test("parseJsonChanges: valid JSON builds the same shape of changes object as the table", () => {
  const out = parseJsonChanges('{"DONATION": 6}', KEYS);
  assert.deepEqual(out, { changes: { DONATION: 6 } });
});

test("parseJsonChanges: a bare sentinel never forwards as a literal value, with or without a baseline (#1548)", () => {
  // The old contract ("round trips verbatim") let a literal {__secret__:true} travel to the rig
  // as if it were a real value — safe only by accident, since nothing WROTE that value there. The
  // nested-secret scrub applies regardless of whether a baseline is available, so this holds even
  // for a caller (like this bare 2-arg call) that has none.
  const text = JSON.stringify({ token: { __secret__: true } });
  const out = parseJsonChanges(text, KEYS);
  assert.deepEqual(out.changes, {});
});

test("parseJsonChanges: an untouched sentinel is dropped from the diff against its baseline (#1548)", () => {
  const baseline = { token: { __secret__: true } };
  const text = JSON.stringify(baseline);
  const out = parseJsonChanges(text, KEYS, baseline);
  assert.deepEqual(out.changes, {}); // matches the baseline -> not a change at all
});

test("parseJsonChanges: a real replacement value for a secret field still comes through (#508)", () => {
  const baseline = { token: { __secret__: true } };
  const text = JSON.stringify({ token: "new-token-value" });
  const out = parseJsonChanges(text, KEYS, baseline);
  assert.deepEqual(out.changes, { token: "new-token-value" });
});

test("parseJsonChanges: malformed JSON surfaces a parse error", () => {
  assert.match(parseJsonChanges("{not json", KEYS).error, /Not valid JSON/);
});

test("parseJsonChanges: empty object and non-writable keys are rejected", () => {
  assert.match(parseJsonChanges("{}", KEYS).error, /non-empty/);
  assert.match(parseJsonChanges('{"nope": 1}', KEYS).error, /Not writable: nope/);
});

// --- Pool credential round-trip (#1548) ------------------------------------------------------
//
// The bug: a pool's `pass` is masked server-side (xmrig_client.mask_pool_credentials), not
// deleted, so the prefill carries a nested {__secret__: true} the operator never sees as plain
// JSON. Nothing before this fix stopped that literal marker from being resent as if it were the
// real password once the operator touched anything nearby.

const POOL_KEYS = ["DONATION", "pools"];
const POOL_SENTINEL = { __secret__: true };
const POOLS_BASELINE = {
  DONATION: 5,
  pools: [{ url: "pool.example:3333", user: "wallet.rig1", pass: POOL_SENTINEL }],
};

test("writableSnapshot: rig wins over applied, per writable key (#1235)", () => {
  const snap = writableSnapshot(POOL_KEYS, { DONATION: 1 }, { DONATION: 9 });
  assert.deepEqual(snap, { DONATION: 9 });
});

test("writableSnapshot: a key neither source knows is simply absent, not null/empty", () => {
  const snap = writableSnapshot(POOL_KEYS, {}, {});
  assert.deepEqual(snap, {});
});

test("parseJsonChanges: touching an unrelated key does not resend an untouched pools credential (#1548)", () => {
  // The issue's exact scenario: open Inspect, switch to JSON mode, change one unrelated key,
  // Apply — without the baseline diff this used to resend the whole prefilled object, `pools`
  // (and its masked credential) included.
  const text = JSON.stringify({ ...POOLS_BASELINE, DONATION: 6 });
  const out = parseJsonChanges(text, POOL_KEYS, POOLS_BASELINE);
  assert.deepEqual(out.changes, { DONATION: 6 });
});

test("parseJsonChanges: editing pools while leaving its credential as the sentinel never sends the literal marker (#1548)", () => {
  const edited = {
    DONATION: 5,
    pools: [
      { url: "pool.example:3333", user: "wallet.rig1", pass: POOL_SENTINEL },
      { url: "backup.example:3333", user: "wallet.rig1" }, // operator added a second pool
    ],
  };
  const out = parseJsonChanges(JSON.stringify(edited), POOL_KEYS, POOLS_BASELINE);
  assert.deepEqual(out.changes, {
    pools: [
      { url: "pool.example:3333", user: "wallet.rig1" }, // credential key gone, not the sentinel
      { url: "backup.example:3333", user: "wallet.rig1" },
    ],
  });
});

test("buildTableChanges: editing the pools JSON row without a real password strips the sentinel, not the pool (#1548)", () => {
  const fields = buildFields(POOL_KEYS, {}, POOLS_BASELINE);
  const edited = JSON.stringify([
    { url: "pool.example:3333", user: "wallet.rig1", pass: POOL_SENTINEL, keepalive: true },
  ]);
  const changes = buildTableChanges(fields, { pools: edited });
  assert.deepEqual(changes, {
    pools: [{ url: "pool.example:3333", user: "wallet.rig1", keepalive: true }],
  });
});

test("jsonSyntaxError: live check used for inline feedback while typing", () => {
  assert.equal(jsonSyntaxError(""), null); // still typing — not an error yet
  assert.equal(jsonSyntaxError("  "), null);
  assert.equal(jsonSyntaxError('{"a": 1}'), null);
  assert.match(jsonSyntaxError("{not json"), /Not valid JSON/);
});

// --- markerLabel / buildChartMarkers (#1015) ------------------------------------------------

test("markerLabel: an applied config change lists its changed keys", () => {
  const label = markerLabel({ type: "apply", status: "applied", changes: { DONATION: 3 } });
  assert.equal(label, "Applied: DONATION");
});

test("markerLabel: a rejected/rolled_back apply carries its reason, not the changed keys", () => {
  assert.equal(
    markerLabel({ type: "apply", status: "rejected", reason: "bad value", changes: { a: 1 } }),
    "Apply rejected — bad value",
  );
  assert.equal(
    markerLabel({ type: "apply", status: "rolled_back", reason: "miner did not return live" }),
    "Apply rolled_back — miner did not return live",
  );
});

test("markerLabel: an applied upgrade names the version it moved to", () => {
  const label = markerLabel({ type: "upgrade", status: "applied", changes: { version: "v1.12.0" } });
  assert.equal(label, "Upgraded to v1.12.0");
});

test("markerLabel: upgrade noop/throttled read calm, not as a fault", () => {
  assert.equal(
    markerLabel({ type: "upgrade", status: "noop", changes: { version: "v1.12.0" } }),
    "Upgrade to v1.12.0: rig already current",
  );
  assert.equal(
    markerLabel({
      type: "upgrade",
      status: "throttled",
      changes: { version: "v1.12.0" },
      reason: "retry after the window",
    }),
    "Upgrade to v1.12.0: throttled — retry after the window",
  );
});

test("buildChartMarkers: maps each row to a chart point, quiet only for a non-applied outcome", () => {
  const rows = [
    { x: 1000, status: "applied", type: "apply", changes: { a: 1 } },
    { x: 2000, status: "rejected", type: "apply", changes: {}, reason: "bad" },
    { x: 3000, status: "applied", type: "upgrade", changes: { version: "v2" } },
  ];
  const pts = buildChartMarkers(rows);
  assert.deepEqual(
    pts.map((p) => [p.x, p.y, p.kind, p.quiet]),
    [
      [1000, 0.5, "apply", false],
      [2000, 0.5, "apply", true],
      [3000, 0.5, "upgrade", false],
    ],
  );
  assert.equal(pts[0].label, "Applied: a");
});

test("buildChartMarkers: tolerates a missing/empty marker list", () => {
  assert.deepEqual(buildChartMarkers(undefined), []);
  assert.deepEqual(buildChartMarkers([]), []);
});

// --- buildFields prefill precedence (#1235) -------------------------------------------------

const WKEYS = ['DONATION', 'autotune', 'max_temp_c', 'pools', 'watchdog', 'watchdog_interval_min'];
const byKey = (fields) => Object.fromEntries(fields.map((f) => [f.key, f]));

test('buildFields: the rig\'s own value wins over what we last applied (#1235)', () => {
    // The whole point: the last-applied record is a record of OUR writes. A value changed directly
    // on the rig, or never set from here at all, is only in the rig's feed.
    const f = byKey(buildFields(WKEYS, { DONATION: 1 }, { DONATION: 7, autotune: 'efficiency' }));
    assert.equal(f.DONATION.value, 7);
    assert.equal(f.DONATION.source, 'rig');
    assert.equal(f.autotune.value, 'efficiency');
    assert.equal(f.autotune.source, 'rig');
});

test('buildFields: falls back to the last-applied record only when the rig sent nothing (#1235)', () => {
    const f = byKey(buildFields(WKEYS, { DONATION: 3 }, null));
    assert.equal(f.DONATION.value, 3);
    assert.equal(f.DONATION.source, 'applied');
    // A key neither source knows is UNKNOWN, never silently empty — an unlabelled empty box reads
    // as "0"/"none" and invites overwriting a good value with a guess.
    assert.equal(f.watchdog.source, 'unknown');
    assert.equal(f.watchdog.value, '');
});

test('buildFields: a null from the rig is an answer, not a failed read (#1235)', () => {
    // max_temp_c null means "no thermal cutoff set" — it must not be demoted to "could not read".
    const f = byKey(buildFields(WKEYS, {}, { max_temp_c: null }));
    assert.equal(f.max_temp_c.source, 'rig');
    assert.equal(f.max_temp_c.value, '');
});

test('buildFields -> buildTableChanges: a null-valued key still posts its real JSON type (#1235)', () => {
    // Asserting the label alone let a regression through once: a null value was typed as a TEXT
    // row, so editing a rig-reported-null max_temp_c posted the string "80" instead of 80. Nothing
    // downstream catches that — validate_worker_changes checks key membership, not value types —
    // so the round trip, not the source label, is what this key needs proven.
    const fields = buildFields(WKEYS, {}, { max_temp_c: null });
    assert.deepEqual(buildTableChanges(fields, { max_temp_c: '80' }), { max_temp_c: 80 });
});

test('buildFields: rig-sourced structured values still get the JSON sub-editor (#1235)', () => {
    const pools = [{ url: 'rig:3333', user: '48edf' }];
    const f = byKey(buildFields(WKEYS, {}, { pools }));
    assert.equal(f.pools.type, 'json');
    assert.equal(f.pools.source, 'rig');
    assert.deepEqual(JSON.parse(f.pools.value), pools);
});

test('buildFields: every field carries a source, so no box can render unlabelled (#1235)', () => {
    for (const f of buildFields(WKEYS, { DONATION: 1 }, { autotune: 'performance' })) {
        assert.ok(['rig', 'applied', 'unknown'].includes(f.source), `${f.key} -> ${f.source}`);
    }
});

// --- fieldNote ------------------------------------------------------------------------------

test('fieldNote: a rig-sourced value needs no explanation (#1235)', () => {
    assert.equal(fieldNote('rig'), null);
});

test('fieldNote: an applied value says where it came from (#1235)', () => {
    assert.equal(fieldNote('applied'), 'last applied from here');
});

test('fieldNote: an unknown source says the value could not be read (#1235)', () => {
    assert.equal(fieldNote('unknown'), 'could not read from the rig');
});

test('fieldNote: any unrecognised source falls back to could-not-read, never null (#1235)', () => {
    assert.equal(fieldNote('bogus'), 'could not read from the rig');
});

// #1367 — the value-drift note beside the provenance line.
test("configDriftNote says nothing when it could not check or found nothing", () => {
  // null (not checked) and [] (checked, agrees) both render silence, for different reasons: an
  // all-clear here would be a reassurance bounded by three narrowings a badge cannot show.
  assert.equal(configDriftNote(null), null);
  assert.equal(configDriftNote([]), null);
  assert.equal(configDriftNote(undefined), null);
  assert.equal(configDriftNote("nonsense"), null);
});

test("configDriftNote names the key on a single disagreement", () => {
  const note = configDriftNote([{ key: "max_temp_c", applied: 75, rig: 80 }]);
  assert.match(note.label, /max_temp_c/);
  assert.match(note.title, /we applied 75, the rig has 80/);
});

test("configDriftNote counts rather than lists when several keys disagree", () => {
  const note = configDriftNote([
    { key: "DONATION", applied: 1, rig: 2 },
    { key: "max_temp_c", applied: 75, rig: 80 },
  ]);
  assert.match(note.label, /2 keys/);
  assert.match(note.title, /DONATION: we applied 1, the rig has 2/);
});

test("configDriftNote renders an absent rig value as 'not set', never as empty", () => {
  // A rig with no thermal cutoff serves null. An unlabelled blank reads as "0" and invites the
  // operator to overwrite a good value — the same trap fieldNote exists to close.
  const note = configDriftNote([{ key: "max_temp_c", applied: 75, rig: null }]);
  assert.match(note.title, /the rig has not set/);
});

test("configDriftNote renders an object value readably", () => {
  const note = configDriftNote([{ key: "pools", applied: [{ url: "a" }], rig: [{ url: "b" }] }]);
  assert.match(note.title, /\{"url":"a"\}/);
});

// #1564 — the unrecorded-edit note, beside the other two on the provenance line.
test("configRevisionDriftNote says nothing unless the server sent a drift", () => {
  // There is no third state to render: the server sends this key only while the drift it
  // recorded is the one that produced the revision the rig is serving now. Nothing here may
  // invent an all-clear out of a shape it does not recognise.
  for (const v of [null, undefined, {}, { before: "aaa" }, "nonsense", []]) {
    assert.equal(configRevisionDriftNote(v), null);
  }
});

test("configRevisionDriftNote names both revisions and says nothing recorded the change", () => {
  const note = configRevisionDriftNote({ worker: "rig1", before: "aaa", after: "bbb" });
  assert.match(note.label, /nothing recording it/);
  assert.match(note.title, /aaa/);
  assert.match(note.title, /bbb/);
  // It may never name a key: the revision is a digest over the whole writable config.
  assert.doesNotMatch(note.title, /max_temp_c|DONATION/);
});

test("configRevisionDriftNote renders an absent 'before' as unknown, never as blank", () => {
  const note = configRevisionDriftNote({ worker: "rig1", after: "bbb" });
  assert.match(note.title, /unknown/);
});

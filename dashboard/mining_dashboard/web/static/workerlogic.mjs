// Pure logic for Worker Inspect's writable-config editor (#518), kept DOM-free so node --test
// covers it. Mirrors configlogic.mjs: buildFields flattens the writable allowlist + the
// last-applied config into typed table rows; buildTableChanges/parseJsonChanges fold an edit
// (table or JSON) back into the `changes` diff POSTed to /api/control/worker-apply. Both modes
// produce the exact same shape — a plain object of only the keys that actually changed.
//
// A writable value can itself be a masked token sentinel (#508/#440) — same {__secret__: true}
// shape the Configuration view already masks. buildFields turns that into a "secret" row so the
// table editor never hands the operator raw sentinel JSON to mangle; a blank secret row keeps it,
// a typed one replaces it, exactly like configlogic's secret fields.

import { isSecretSentinel } from "./configlogic.mjs";

// jsonSyntaxError is generic (no worker-specific shape) — configlogic.mjs owns it (#529, the
// Configuration view's own JSON mode uses it too); re-exported here so workerview.mjs's existing
// import keeps working unchanged.
export { jsonSyntaxError } from "./configlogic.mjs";

// One row per writable key, typed off the current (last-applied) value's JSON shape. A key never
// applied yet has no value to type off, so it falls back to an empty JSON sub-editor.
export function buildFields(writableKeys, lastApplied, rigConfig) {
  const applied = lastApplied || {};
  const rig = rigConfig || {};
  return (writableKeys || []).map((key) => {
    // Precedence: what the RIG is running, then what WE last pushed, then nothing (#1235). The
    // rig's own value is the only one that is true on a never-edited rig or one changed directly
    // with `rigforge.sh apply`; the last-applied record is a record of our writes, not its state.
    // `source` travels with the field so the editor can say which of the three a box is showing —
    // an unlabelled empty box reads as "0"/"none" and invites overwriting a good value.
    const fromRig = key in rig;
    const source = fromRig ? "rig" : key in applied ? "applied" : "unknown";
    const value = fromRig ? rig[key] : applied[key];
    if (isSecretSentinel(value)) return { key, source, type: "secret", value: "" };
    // A null from the rig is a real answer — "no thermal cutoff set" — not a failed read, so it
    // keeps source "rig" and renders empty rather than being demoted to unknown. The TYPE stays
    // json regardless of source: buildTableChanges types the operator's edit off field.type, and
    // an empty *text* row would hand back "80" where the rig expects 80 — validate_worker_changes
    // checks key membership only, so a mistyped value would travel all the way to the rig.
    if (value === null || value === undefined) {
      return { key, source, type: "json", value: "" };
    }
    if (typeof value === "boolean") return { key, source, type: "boolean", value };
    if (typeof value === "number") return { key, source, type: "number", value };
    if (typeof value === "string") return { key, source, type: "text", value };
    // pools/autotune/watchdog (arrays/objects): a small per-row JSON sub-editor rather than a
    // bespoke widget per shape (#518 leaves that for later).
    return { key, source, type: "json", value: JSON.stringify(value, null, 2) };
  });
}

// Table edits -> the diff `changes` object. `edits` holds only the rows the operator touched
// (component state, keyed like ConfigView's); a row typed back to its original value is dropped
// so untouched rows never enter the diff, matching the JSON textarea's "record only what changed"
// behavior. Throws on an unparsable JSON sub-row — the caller surfaces that as an apply error.
export function buildTableChanges(fields, edits) {
  const changes = {};
  for (const f of fields) {
    if (!(f.key in edits)) continue;
    const raw = edits[f.key];
    if (f.type === "secret") {
      if (raw !== "") changes[f.key] = raw; // blank = leave the masked value alone
    } else if (f.type === "boolean") {
      const v = raw === true || raw === "true";
      if (v !== f.value) changes[f.key] = v;
    } else if (f.type === "number") {
      if (raw === "" || raw === String(f.value)) continue;
      const n = Number(raw);
      changes[f.key] = Number.isFinite(n) ? n : raw; // garbage passes through for the rig to reject
    } else if (f.type === "json") {
      const text = raw.trim();
      if (text === "" || text === f.value.trim()) continue;
      changes[f.key] = JSON.parse(text);
    } else if (raw !== f.value) {
      changes[f.key] = raw;
    }
  }
  return changes;
}

// The JSON mode's own path: parse, then the same non-empty/object/allowlist checks the table
// mode gets for free from only ever rendering allowlisted rows. Returns { changes } or { error }.
export function parseJsonChanges(text, writableKeys) {
  let changes;
  try {
    changes = JSON.parse(text);
  } catch {
    return { error: "Not valid JSON." };
  }
  if (
    !changes ||
    typeof changes !== "object" ||
    Array.isArray(changes) ||
    !Object.keys(changes).length
  ) {
    return { error: "Enter a non-empty JSON object of writable keys." };
  }
  const allowed = new Set(writableKeys || []);
  const bad = Object.keys(changes).filter((k) => !allowed.has(k));
  if (bad.length) return { error: `Not writable: ${bad.join(", ")}` };
  return { changes };
}

// Where a field's value came from (#1235). An unlabelled empty box reads as "0"/"none" and
// invites overwriting a good value with a guess, so a value we could not read says so.
export function fieldNote(source) {
  if (source === "rig") return null;
  if (source === "applied") return "last applied from here";
  return "could not read from the rig";
}

// Per-worker hashrate chart markers (#1015): one change-history row -> one tooltip label. The
// server keeps `status`/`type`/`changes`/`reason` as raw tokens (views.py "formats at the edge"
// only for display strings); this is the client mapping them to text, the same job STATUS_META
// already does for the History table's Outcome column, just phrased as a tooltip sentence.
export function markerLabel(row) {
  const changes = row.changes || {};
  if (row.type === "upgrade") {
    const version = changes.version || "an update";
    if (row.status === "applied") return `Upgraded to ${version}`;
    if (row.status === "noop") return `Upgrade to ${version}: rig already current`;
    return `Upgrade to ${version}: ${row.status}` + (row.reason ? ` — ${row.reason}` : "");
  }
  const keys = Object.keys(changes);
  const changed = keys.length ? keys.join(", ") : "config";
  if (row.status === "applied") return `Applied: ${changed}`;
  return `Apply ${row.status}` + (row.reason ? ` — ${row.reason}` : "");
}

// Change-history rows (server-shaped, range-filtered to match the chart's own hashrate slice) ->
// WorkerChartCard's marker points. `quiet` covers every outcome where the rig's config/build did
// NOT actually change (rejected/rolled_back/failed/throttled/noop/accepted) — shown with a muted
// glyph rather than dropped, so "we tried and it bounced" still explains a flat stretch (#1015).
export function buildChartMarkers(markers) {
  return (markers || []).map((row) => ({
    x: row.x,
    y: 0.5,
    label: markerLabel(row),
    kind: row.type === "upgrade" ? "upgrade" : "apply",
    quiet: row.status !== "applied",
  }));
}

// Where the rig's running config came from (#1345) -> the one line the operator reads. The server
// decides the VERDICT (it holds the only fact that settles it: whether the rig's last_change_id
// matches a change this dashboard spooled); this is the client turning that token into text, the
// same division of labour markerLabel() above already follows.
//
// `restored` is deliberately not phrased as an accusation: RigForge stamps it for its OWN automatic
// rollback after a change fails to hold, so the text has to leave room for the rig having healed
// itself rather than someone having edited it. `unrecorded` claims nothing for the same reason — a
// never-changed rig and a config edited underneath RigForge look identical from here.
//
// `unconfirmed` is the one that says "we do not know", and it must keep saying only that: it can
// neither promise the change held nor accuse the rig of dropping it. It is reached by an
// `accepted` row, which the host runner writes only after polling the rig's /status for a terminal
// outcome for 20s and getting none ("queued on the rig; outcome not yet observed", pithead's own
// note). Phrased "is unconfirmed" rather than "was never confirmed" on purpose — the reconciler
// can still settle that row on a later read poll, so claiming finality would be a second wrong
// answer in place of the first one this verdict exists to remove.
const CONFIG_ORIGIN_TEXT = {
  here: { cls: "text-muted", label: "Last changed from this dashboard" },
  reverted: {
    cls: "status-warn",
    label: "Last change from this dashboard was rolled back",
    detail:
      "the rig re-stamps the change id it reverted, so it is running whatever config came before",
  },
  unconfirmed: {
    cls: "status-warn",
    label: "Last change from this dashboard is unconfirmed",
    detail:
      "the rig acknowledged it but has not reported an outcome — it may be running, or it may have been rolled back",
  },
  elsewhere: {
    cls: "status-warn",
    label: "Last changed from another dashboard",
    detail: "applied over a control channel, with a change id this dashboard has no record of",
  },
  // There was a third muted verdict here, `untraced`: `elsewhere` with the accusation taken back
  // out, sent when the id was not found AND the history the server searched was full, so the id
  // might merely have sat past the end of the window. It was a trade — a genuinely foreign change
  // on a long-history rig landed there too, so a true alarm was swapped for a statement that was
  // always true. #1369 made the server look the id up directly instead of searching the window it
  // renders, which removes the doubt rather than wording it, so the verdict has no producer and
  // is gone from both sides.
  //
  // `unread` is the one verdict that is about US, not the rig (#1409). The server sends it when
  // its own history read failed outright — no DB connection, or a `sqlite3.Error` — so it never got
  // to look for the id. Before this it fell through to `elsewhere` and printed "Last changed from
  // another dashboard" over a change that may well have been ours: an accusation sourced from our
  // own broken database. `text-muted` because it claims nothing, and a warning colour over "we
  // could not tell" is the same overclaim in a different medium. This adds a verdict STATE,
  // deliberately not a new COLOUR: the text carries the distinction, the colour carries the class.
  unread: {
    cls: "text-muted",
    label: "Cannot tell — this dashboard could not read its own history",
    detail:
      "the change-history read failed here, so nothing was compared — this says nothing about the rig",
  },
  rig: { cls: "status-warn", label: "Last changed on the rig itself" },
  restored: {
    cls: "status-warn",
    label: "Last restored from a saved config",
    detail: "someone ran RigForge's restore command on the rig",
  },
  unrecorded: {
    cls: "text-muted",
    label: "No recorded config change",
    detail: "a rig that has never been changed looks the same as one changed outside RigForge",
  },
};

// null means SAY NOTHING — an absent verdict is a rig too old to answer (or no RigForge at all),
// which is not the same claim as "unknown" and must not render as one.
export function configOriginNote(origin, meta) {
  const text = CONFIG_ORIGIN_TEXT[origin];
  if (!text) return null;
  // No timestamp here: ConfigProvenance already renders changed_at inline on this same line, so
  // repeating it in the tooltip says the same thing twice.
  const parts = [];
  if (meta?.revision) parts.push(`config revision ${meta.revision}`);
  if (text.detail) parts.push(text.detail);
  return { cls: text.cls, label: text.label, title: parts.join(" · ") };
}

// #1367: the per-key disagreement between what this dashboard applied and what the rig reports it
// is running — the case configOriginNote structurally cannot see, because a config edited underneath
// RigForge records nothing for the provenance line to read.
//
// Renders ONLY a disagreement. `null` (could not check) and `[]` (checked, agrees) both say nothing,
// deliberately and for different reasons: `null` is the same "say nothing" posture the rest of this
// block takes, and `[]` is withheld because an all-clear here would be a reassurance bounded by
// three narrowings the operator cannot see from a badge — it judges only keys we have set, never
// pool passwords, and never mid-flight. This feature exists to stop a false reassurance; printing a
// qualified one in the same place would be the same defect wearing the opposite label.
export function configDriftNote(drift) {
  if (!Array.isArray(drift) || drift.length === 0) return null;
  const show = (v) =>
    v === null || v === undefined
      ? "not set"
      : typeof v === "object"
        ? JSON.stringify(v)
        : String(v);
  return {
    cls: "text-warn",
    label:
      drift.length === 1
        ? `The rig is not running what we applied: ${drift[0].key}`
        : `The rig is not running what we applied: ${drift.length} keys`,
    title: drift
      .map((d) => `${d.key}: we applied ${show(d.applied)}, the rig has ${show(d.rig)}`)
      .join(" · "),
  };
}

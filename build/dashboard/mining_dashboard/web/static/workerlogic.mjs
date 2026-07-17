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

// One row per writable key, typed off the current (last-applied) value's JSON shape. A key never
// applied yet has no value to type off, so it falls back to an empty JSON sub-editor.
export function buildFields(writableKeys, lastApplied) {
  const applied = lastApplied || {};
  return (writableKeys || []).map((key) => {
    const value = applied[key];
    if (isSecretSentinel(value)) return { key, type: "secret", value: "" };
    if (typeof value === "boolean") return { key, type: "boolean", value };
    if (typeof value === "number") return { key, type: "number", value };
    if (typeof value === "string") return { key, type: "text", value };
    // pools/autotune/watchdog (arrays/objects) and any never-applied key: a small per-row JSON
    // sub-editor rather than a bespoke widget per shape (#518 leaves that for later).
    return { key, type: "json", value: key in applied ? JSON.stringify(value, null, 2) : "" };
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

// Live syntax check for the JSON textarea, surfaced inline as the operator types (not only on
// Apply). Blank is not an error yet — the operator hasn't finished typing.
export function jsonSyntaxError(text) {
  if (!text.trim()) return null;
  try {
    JSON.parse(text);
    return null;
  } catch {
    return "Not valid JSON.";
  }
}

// Pure logic for the Configuration view (#33), kept DOM-free so node --test covers it.
//
// GET /api/config returns the live config.json with every set secret masked to the
// {__secret__: true} sentinel. buildSections flattens that into render-ready form fields;
// applyEdits folds the user's edits back into a proposed config for POST /api/control/preview.
// A secret left blank keeps its sentinel — the server swaps it for the live value ("unchanged").

export const SECRET_HINT = "set — leave blank to keep";

export function isSecretSentinel(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v) && v.__secret__ === true;
}

// Fixed-choice fields; everything else renders from its JSON type.
const FIELD_OPTIONS = {
  "monero.mode": ["local", "remote"],
  "p2pool.pool": ["main", "mini", "nano"],
  "workers.api_auth": ["none", "name", "token"],
  "xvb.donation_level": ["auto", "donor", "vip", "whale", "mega"],
};

// Inline warnings for high-consequence fields, shown before any preview round-trip. The pool
// text carries describe_change's P2POOL_FLAGS warning; the wallet texts its DEST messages.
const FIELD_WARNINGS = {
  "p2pool.pool":
    "P2Pool sidechain changing — p2pool re-syncs the new sidechain and your PPLNS window resets (XvB shares reset too).",
  "monero.wallet_address":
    "Monero payout address is changing — future mining rewards go to the new address.",
  "tari.wallet_address":
    "Tari payout address is changing — future merge-mining rewards go to the new address.",
};

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function walk(node, path, out) {
  for (const [key, value] of Object.entries(node)) {
    const p = [...path, key];
    const dotted = p.join(".");
    if (isPlainObject(value) && !isSecretSentinel(value)) {
      walk(value, p, out);
      continue;
    }
    const field = { path: p, key: dotted, warning: FIELD_WARNINGS[dotted] };
    if (isSecretSentinel(value)) Object.assign(field, { type: "secret", value: "" });
    else if (typeof value === "boolean") Object.assign(field, { type: "boolean", value });
    else if (typeof value === "number") Object.assign(field, { type: "number", value });
    else if (FIELD_OPTIONS[dotted])
      Object.assign(field, {
        type: "select",
        value: String(value ?? ""),
        options: FIELD_OPTIONS[dotted],
      });
    else Object.assign(field, { type: "text", value: String(value ?? "") });
    out.push(field);
  }
}

// Flatten the masked config into sections, one per top-level object key, each field addressed
// by its dotted path. Non-object top-level keys (e.g. a _docs string) are left out of the form
// but survive untouched in the proposed config.
export function buildSections(cfg) {
  const sections = [];
  for (const [name, value] of Object.entries(cfg || {})) {
    if (name.startsWith("_") || !isPlainObject(value)) continue;
    const fields = [];
    walk(value, [name], fields);
    if (fields.length) sections.push({ name, fields });
  }
  return sections;
}

function setPath(cfg, path, value) {
  let node = cfg;
  for (const key of path.slice(0, -1)) node = node[key];
  node[path.at(-1)] = value;
}

// The proposed config: the fetched (masked) config with the edits applied. Booleans/numbers are
// coerced back from input strings (garbage in a number field is passed through for the host-side
// validator to reject with its real message); a blank secret keeps its sentinel.
export function applyEdits(cfg, sections, edits) {
  const proposed = structuredClone(cfg);
  for (const section of sections) {
    for (const f of section.fields) {
      if (!(f.key in edits)) continue;
      const raw = edits[f.key];
      let v = raw;
      if (f.type === "boolean") v = raw === true || raw === "true";
      else if (f.type === "number") {
        const n = Number(raw);
        v = Number.isFinite(n) && String(raw).trim() !== "" ? n : raw;
      } else if (f.type === "secret" && raw === "") continue; // blank = keep the sentinel
      setPath(proposed, f.path, v);
    }
  }
  return proposed;
}

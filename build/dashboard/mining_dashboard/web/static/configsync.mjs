// Pure logic for two-way form ⇄ JSON config sync, kept DOM-free so node --test covers it.
//
// Born in the first-boot wizard and written as a shared module on purpose: the wizard's
// "simple fields on top, the whole config underneath, both live" shape is the pattern the
// dashboard's Configuration view is converging on (#785). Anything here must stay pure —
// views bind these to inputs; tests call them directly.

/** Read a dotted path ("monero.remote.host") out of a nested object; undefined if absent. */
export function pathGet(obj, path) {
  return path.split(".").reduce((acc, k) => (acc == null ? acc : acc[k]), obj);
}

/** Write a dotted path into a nested object, creating intermediate objects as needed. */
export function pathSet(obj, path, value) {
  const keys = path.split(".");
  let cur = obj;
  for (const k of keys.slice(0, -1)) {
    if (typeof cur[k] !== "object" || cur[k] === null) cur[k] = {};
    cur = cur[k];
  }
  cur[keys[keys.length - 1]] = value;
}

/**
 * Coerce a form input's string to the type the reference holds at that path. A form's value is
 * always a string; the config's type is not — a port must stay a number and a toggle a boolean,
 * or the JSON pane drifts from what the host would actually read.
 */
export function coerceForPath(reference, path, raw) {
  if (raw === "true") return true;
  if (raw === "false") return false;
  if (/^[0-9]+$/.test(raw) && typeof pathGet(reference, path) === "number") {
    return Number.parseInt(raw, 10);
  }
  return raw;
}

/**
 * Coerce a form input's string by the FIELD's declared type (the dashboard's config editor,
 * where configlogic's buildSections has already typed every field). The wizard's sibling
 * coerceForPath infers from a reference config instead — same job, different source of truth.
 */
export function coerceForType(type, raw) {
  if (type === "boolean") return raw === "true" || raw === true;
  if (type === "number") {
    const n = Number(raw);
    return Number.isNaN(n) ? raw : n;
  }
  return raw;
}

/**
 * Classify a pasted Monero address the way the CLI wizard does, so the page can name the
 * actual mistake before a submit round-trip. The HOST re-validates — this only saves a trip.
 * Returns { kind, message } with kind one of "empty" | "subaddress" | "integrated" |
 * "not-primary" | "partial" | "ok".
 */
export function classifyMoneroAddress(value) {
  const v = (value || "").trim();
  if (!v) {
    return { kind: "empty", message: "Must be your PRIMARY address — it starts with 4." };
  }
  if (v[0] === "8") {
    return {
      kind: "subaddress",
      message: "That is a subaddress (8…). p2pool cannot pay it — use your primary address.",
    };
  }
  if (v.length > 95) {
    return {
      kind: "integrated",
      message: "That looks like an integrated address. Use your plain primary address.",
    };
  }
  if (v[0] !== "4") {
    return { kind: "not-primary", message: "A primary Monero address starts with 4." };
  }
  if (v.length !== 95) {
    return { kind: "partial", message: `${v.length} of 95 characters.` };
  }
  return { kind: "ok", message: "Looks like a valid primary address." };
}

/**
 * Telegram needs the bot token AND the chat id, or neither — a half pair cannot deliver
 * anything, and writing enabled=true on a broken pair fails host validation on a blank the
 * operator never meant to set. The server enforces this; the page uses it to warn live.
 */
export function telegramPairReady(token, chat) {
  const t = (token || "").trim();
  const c = (chat || "").trim();
  if (t && c) return { ready: true, partial: false };
  if (t || c) return { ready: false, partial: true };
  return { ready: false, partial: false };
}

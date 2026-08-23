// Pure logic for the click-to-adopt form (issue #893), kept DOM-free so node --test covers it.
// workeradopt.mjs binds these to the form; tests call them directly.
//
// The security authority for the write itself is host-side (pithead's control_approval_gate add-
// only exception, re-checked by the dashboard's own handle_control_preview guard). What lives here
// is UX-layer, defense-in-depth validation — mirroring the same host/port/token shape pithead's
// validate_worker_endpoints enforces — so an obviously malformed value is refused before a round
// trip, not because this is where the trust decision is made.

const HOST_RE = /^[A-Za-z0-9._-]{1,253}$/;
const TOKEN_RE = /^[!-~]{1,128}$/;

/** The rig's control-API default port (RigForge's own default) — the form's port prefill. */
export const DEFAULT_CONTROL_PORT = "8082";

/**
 * Refuse an adopt submission before it ever reaches the network. ``host`` is the field the
 * operator confirmed or edited (the observed IP is only ever a PREFILL, never auto-submitted
 * unread) — this only checks its SHAPE, the same SSRF-motivated charset guard the host applies:
 * no port, path, or userinfo can ride into a probe URL. Returns an error string, or "" when every
 * field is well-formed.
 */
export function validateAdoptFields(host, controlPort, token) {
  const h = (host || "").trim();
  if (!h) return "Enter the rig's control address (a hostname or IP).";
  if (!HOST_RE.test(h)) {
    return "Host must be a hostname or IPv4 address — letters, digits, and . _ - only (no port or path).";
  }
  const port = Number(controlPort);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    return "Control port must be an integer between 1 and 65535.";
  }
  const t = (token || "").trim();
  if (!t || !TOKEN_RE.test(t)) {
    return "Enter the rig's control token — its control API is bearer-mandatory.";
  }
  return "";
}

/**
 * Client-side mirror of the host's SSRF floor on a NEW workers.list[] entry (pithead's
 * ``_control_host_is_internal`` / the dashboard's ``worker_adopt.host_is_internal``): loopback,
 * unspecified, link-local, multicast/reserved, "localhost", or the stack's own docker-bridge
 * subnet. UX only — a fast, clear refusal before the round trip; the host-side gate (and its own
 * dashboard-side mirror, checked at preview) is what actually enforces this.
 */
export function hostIsInternal(host, subnet) {
  const h = (host || "").trim().toLowerCase();
  if (h === "localhost" || h.endsWith(".localhost")) return true;
  const m = h.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (!m) return false; // a hostname clears this class; DNS resolution isn't re-checked here
  const octets = m.slice(1, 5).map(Number);
  if (octets.some((o) => o > 255)) return false;
  const [a, b, c] = octets;
  if (a === 0 || a === 127) return true; // this-network / loopback
  if (a === 169 && b === 254) return true; // link-local (cloud metadata included)
  if (a >= 224) return true; // multicast (224-239) + reserved (240-255)
  const bridge = (subnet || "172.28.0.0/24").match(
    /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.\d{1,3}\/24$/,
  );
  return !!bridge && `${a}.${b}.${c}` === bridge.slice(1, 4).join(".");
}

/**
 * The proposed config a successful adopt submits: ``liveConfig`` (as fetched from /api/config)
 * with one new descriptor appended to ``workers.list[]``. Every other key rides through untouched
 * — the host's add-only gate requires every already-live entry to reappear byte-for-byte, so this
 * never touches an existing element, only pushes a new one onto the end.
 */
export function buildAdoptedConfig(liveConfig, workerName, host, controlPort, token) {
  const cfg = JSON.parse(JSON.stringify(liveConfig || {}));
  const workers = cfg.workers && typeof cfg.workers === "object" ? cfg.workers : {};
  const list = Array.isArray(workers.list) ? workers.list.slice() : [];
  list.push({
    name: workerName,
    host: host.trim(),
    control_port: Number(controlPort),
    token: token.trim(),
  });
  cfg.workers = { ...workers, list };
  return cfg;
}

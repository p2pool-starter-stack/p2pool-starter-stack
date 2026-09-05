# Split out of config.py to keep it under its file-budget ceiling (#1285). Unlike the rest of
# config.py's flat environment settings, these two loaders parse the read-only config.json bind
# mount itself (not an env var) — config.py calls them once at import time to populate
# DASHBOARD_WORKERS / DASHBOARD_ENERGY, passing its own HOST_CONFIG_PATH explicitly so this module
# never has to import config.py back (that would be circular).

import json
import logging
import re

logger = logging.getLogger("Config")

# --- Per-worker endpoint descriptors (#172, config.json: workers.list[]) ---
# [{name, host?, port?, token?}] — per-rig overrides for the worker API probe when a rig doesn't
# match the fleet defaults (different port, API on another interface/NAT hop, its own token).
# Read from the read-only config.json bind mount above, NOT the .env render: entries carry
# per-worker API tokens, which stay in the owner-only config.json instead of riding a second file.
# Every field is optional bar `name` (the rig's stratum name). Validation is fail-closed: an entry
# with ANY invalid field is dropped whole, so a typo'd `host` can never leave its token attached
# to the miner-IP fallback path (#122). pithead validates the same shape loudly at apply; this
# parse only has to stay safe if the mount is stale or hand-edited.
#
# The descriptors live at workers.list[] (#506) and nowhere else. Until 2.0.0 an unset or empty
# workers.list fell back to the deprecated dashboard.workers[] (#172); that alias was removed in
# #1832 and pithead migrates a pre-2.0 config to workers.list[] before the dashboard ever reads
# the mount, so this loader needs no fallback and an alias left in a stale mount reads as absent.
#   name  — 1-128 printable non-space ASCII chars (matched against the stratum name, '+' stripped)
#   host  — hostname or IPv4 literal: letters/digits/dot/dash/underscore only, so a config value
#           can never smuggle a port, path, or userinfo into the probe URL (no ':/@?#'; IPv6
#           literals are not supported)
#   port  — integer 1-65535 (bool is an int subclass — rejected explicitly)
#   token — 1-128 printable non-space ASCII chars (header-safe)
#   watts — a positive number: the operator's manual power-draw estimate for a rig whose enriched
#           feed reports no RAPL watts (macOS, non-RigForge, or an old kit), so the energy/profit
#           calculator (#260) can still total the fleet draw. Marked "estimated" in the UI.
_WORKER_NAME_RE = re.compile(r"^[\x21-\x7e]{1,128}$")
_WORKER_HOST_RE = re.compile(r"^[A-Za-z0-9._-]{1,253}$")


def _valid_watts(v):
    """A positive, finite power estimate (bool rejected — it's an int subclass), else None."""
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) and 0 < v < 1e6 else None


def load_worker_endpoints(path) -> list[dict]:
    """The validated workers.list[] entries (#506); invalid entries dropped, first name wins.

    The deprecated dashboard.workers[] fallback (#172) was removed in 2.0.0 (#1832): pithead
    migrates a pre-2.0 config in place before this mount is written, so the alias never reaches
    here. A stale mount still carrying it reads as no descriptors at all, which is fail-closed.
    """
    try:
        with open(path) as f:
            doc = json.load(f)
    except (OSError, ValueError, AttributeError):
        return []
    workers_block = doc.get("workers") if isinstance(doc, dict) else None
    raw = workers_block.get("list") if isinstance(workers_block, dict) else None
    if not isinstance(raw, list):
        return []
    out, seen = [], set()
    for item in raw:
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        if not isinstance(name, str) or not _WORKER_NAME_RE.match(name) or name in seen:
            continue  # nameless/dup entries: unmatchable; duplicates: first-declared wins
        entry = {"name": name}
        if "host" in item:
            if not isinstance(item["host"], str) or not _WORKER_HOST_RE.match(item["host"]):
                continue
            entry["host"] = item["host"]
        if "port" in item:
            port = item["port"]
            if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
                continue
            entry["port"] = port
        if "control_port" in item:
            # The rig's writable control API port (#185). Operator-overridable, NOT derived from
            # `port`+1 — RigForge lets the operator pick it (default 8082). Only the HOST-side runner
            # ever dials it (with the real token); the dashboard container only shows/edits config.
            cport = item["control_port"]
            if isinstance(cport, bool) or not isinstance(cport, int) or not 1 <= cport <= 65535:
                continue
            entry["control_port"] = cport
        if "token" in item:
            tok = item["token"]
            # The container only ever reads the MASKED config (#440), where a real token is replaced
            # by the sentinel {"__secret__": true}. Keep the entry then (token present, value hidden)
            # so the worker stays editable — the HOST-side runner supplies the real token when it
            # dials the rig (#508). A genuinely bad token (bad string, or any other dict) still drops
            # the whole entry, fail-closed.
            if isinstance(tok, dict) and tok.get("__secret__") is True:
                entry["token"] = tok
            elif isinstance(tok, str) and _WORKER_NAME_RE.match(tok):
                entry["token"] = tok
            else:
                continue
        if "watts" in item:
            watts = _valid_watts(item["watts"])
            if watts is None:
                continue  # fail-closed like every other field: a bad watts drops the whole entry
            entry["watts"] = watts
        seen.add(name)
        out.append(entry)
    return out


def load_energy_config(path):
    """The validated ``dashboard.energy`` block for the energy/profit calculator (#260).

    Read straight off the read-only config.json bind mount (same as the worker descriptors above),
    not the .env render — it's a small, self-contained block with no secrets. Every field is
    optional and validated; a missing/invalid value falls back to its default so a typo degrades the
    feature (profit math hidden) instead of crashing the dashboard. pithead validates the same shape
    loudly at apply.

    ``cost_per_kwh`` — electricity price per kWh (0/unset ⇒ cost + profit hidden, energy view only).
    ``xmr_price``    — operator-supplied fiat price of 1 XMR (0/unset ⇒ net profit hidden), in the
                       same ``currency`` as ``cost_per_kwh``. Static by default (no unbidden price
                       egress); the fallback when ``price_feed`` is on but hasn't fetched yet.
    ``tari_price``   — operator-supplied fiat price of 1 XTM (#520; 0/unset ⇒ net profit counts
                       P2Pool XMR only). Same static-by-default reasoning as ``xmr_price``; folds
                       Tari's merge-mined earnings into net profit once both prices are known.
    ``currency``     — display label for all figures (e.g. USD, EUR). Label only — no conversion.
    ``price_feed``   — opt-in (default off): fetch both prices live from CoinGecko over Tor
                       (``service/price_feed.py``) instead of the static numbers above, which then
                       serve as the fallback until the first fetch lands.
    """
    try:
        with open(path) as f:
            raw = json.load(f).get("dashboard", {}).get("energy", {})
    except (OSError, ValueError, AttributeError):
        raw = {}
    if not isinstance(raw, dict):
        raw = {}

    def _nonneg(v):
        return (
            float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 else 0.0
        )

    currency = raw.get("currency")
    if not isinstance(currency, str) or not _WORKER_NAME_RE.match(currency):
        currency = "USD"
    return {
        "cost_per_kwh": _nonneg(raw.get("cost_per_kwh")),
        "xmr_price": _nonneg(raw.get("xmr_price")),
        "tari_price": _nonneg(raw.get("tari_price")),
        "currency": currency,
        "price_feed": raw.get("price_feed") is True,
    }

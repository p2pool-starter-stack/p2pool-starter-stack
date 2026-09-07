"""Dashboard side of the host-mutation control channel (#33).

The container can only ASK. This module reads the host-rendered PRE-MASKED config copy (#440) to
prefill the editor form, writes typed JSON intents into the requests/ spool — the container's
single writable leg — and reads results back from the read-only results/ mount. The host-side
runner (``pithead control-run-pending``) re-validates and executes; nothing here runs a command.

Secrets never enter the container: the host masks every set secret to the ``{"__secret__": true}``
sentinel before the copy is mounted (the raw config.json is not mounted at all), a proposal
carries the sentinel back for an untouched secret, and the host swaps it for the live value when
it stages the intent. ``read_config`` re-applies the same masking as defense-in-depth.
"""

import asyncio
import json
import logging
import os
import time
import uuid

from mining_dashboard.config import config
from mining_dashboard.service import request_spool

logger = logging.getLogger("ControlService")

# Config paths whose leaves are secrets. Mirrors pithead's CONTROL_SECRET_PATHS (the host-side
# masking source, #440) — keep the two lists in step.
SECRET_PATHS = [
    ("dashboard", "auth", "password"),
    ("telegram", "bot_token"),
    ("workers", "api_token"),
    ("monero", "node_username"),
    ("monero", "node_password"),
    # The private view key (#381): reveals all incoming payout amounts/timing to anyone who reads it.
    ("monero", "view_key"),
    # The Tari private view key (#462): same exposure for the Tari side (spend_public_key is public).
    ("tari", "view_key"),
    ("p2pool", "stratum_password"),
    # A capability secret: pithead's describe_change already refuses to echo it, but read_config
    # was serving it in cleartext to the browser. Mask it too (#33 hardening).
    ("healthchecks", "ping_url"),
    # ntfy topic URL + access token (#848): the URL can carry a topic token in its path/query and
    # the token is a Bearer credential — both masked like the ping URL above.
    ("notifications", "ntfy", "url"),
    ("notifications", "ntfy", "token"),
    # The backup's primary-dashboard URL (#249) can carry the primary's dashboard basic-auth as
    # userinfo — a capability secret, masked like the ping URL above.
    ("xvb", "standby", "source"),
]
SECRET_SENTINEL = {"__secret__": True}
# notifications.webhooks[] (#848): a list of bare URL strings, each one a bearer secret (query
# strings carry tokens). No fixed leaf path reaches an array element, so it is masked separately.
WEBHOOKS_PATH = ("notifications", "webhooks")

_RESULT_POLL_S = 0.5


def _load_host_config():
    """The host-rendered, pre-masked config copy (#440) — no raw secret ever crosses the mount."""
    with open(config.HOST_CONFIG_PATH) as f:
        return json.load(f)


def _get(cfg, path):
    """Walk ``path`` through nested dicts. Returns (found, value)."""
    node = cfg
    for key in path[:-1]:
        if not isinstance(node, dict) or key not in node:
            return False, None
        node = node[key]
    if not isinstance(node, dict) or path[-1] not in node:
        return False, None
    return True, node[path[-1]]


def _set(cfg, path, value):
    node = cfg
    for key in path[:-1]:
        node = node[key]
    node[path[-1]] = value


def mask_secrets(cfg):
    """Replace every set secret leaf (``SECRET_PATHS``) and each set ``notifications.webhooks[]``
    entry with the sentinel, in place. Mirrors pithead's ``render_masked_config``; shared by
    ``read_config`` and ``data_service`` so the fixed-path walk and the webhooks array mask (#848)
    never drift between the two defense-in-depth passes. An empty secret stays empty."""
    for path in SECRET_PATHS:
        found, value = _get(cfg, path)
        if found and value:
            _set(cfg, path, dict(SECRET_SENTINEL))
    found, hooks = _get(cfg, WEBHOOKS_PATH)
    if found and isinstance(hooks, list):
        _set(cfg, WEBHOOKS_PATH, [dict(SECRET_SENTINEL) if h else h for h in hooks])
    return cfg


def _deep_merge(base, override):
    """Recursively lay ``override`` over ``base`` (dicts merge; any other value replaces)."""
    merged = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


# Env-var -> config-path(s) map (#613), mirroring pithead's CONTROL_DASHBOARD_EDITABLE_KEYS
# (pithead ~L4793) — the commit gate's ACTUAL allowlist, the single source of truth for what the
# control channel will commit. Surfaced to the browser as ``_editable_keys`` below so the
# Configuration view can grey out everything else up front instead of letting an operator edit a
# host-only field and find out at Save (#613).
#
# Some env vars are derived from MORE than one config path — P2POOL_FLAGS folds in both
# ``p2pool.pool`` (--mini/--nano) and ``p2pool.clearnet`` (the Tor-egress socks flags appended in
# render_env) — so this has to mirror the actual derivation in render_env, not the prose summary
# in pithead's own allowlist comment (which lists "clearnet toggles" as generally host-only
# elsewhere; the gate itself works on RENDERED ENV VARS, not config paths, so a config path that
# feeds an allowlisted var IS committable even if it sounds like it shouldn't be from the comment
# alone).
#
# Drift-guarded (mirrors #515's WORKER_WRITABLE_KEYS check, see
# test_editable_keys_have_no_intra_repo_drift below): a test regexes
# CONTROL_DASHBOARD_EDITABLE_KEYS out of the pithead script and asserts its env-var names equal
# this map's keys, so an allowlist edit without a matching map edit fails CI loudly instead of
# silently drifting the greyed set out of sync with what the gate actually accepts.
EDITABLE_ENV_KEY_PATHS = {
    "P2POOL_FLAGS": ("p2pool.pool", "p2pool.clearnet"),
    "P2POOL_PORT": ("p2pool.pool",),
    "XVB_ENABLED": ("xvb.enabled",),
    "XVB_DONATION_LEVEL": ("xvb.donation_level",),
    "TARI_REQUIRED": ("dashboard.tari_required",),
    "DASHBOARD_FAIL_CLOSED": ("dashboard.fail_closed",),
    "DASHBOARD_CHECK_UPDATES": ("dashboard.check_for_updates",),
    "DASHBOARD_TZ": ("dashboard.timezone",),
    "MONERO_MEM_LIMIT": ("monero.mem_limit",),
    "TARI_MEM_LIMIT": ("tari.mem_limit",),
    "MONERO_PREP_THREADS": ("monero.prep_blocks_threads",),
    "HASHRATE_DROP_THRESHOLD_PCT": ("dashboard.hashrate_drop_threshold",),
    "HASHRATE_DROP_MINUTES": ("dashboard.hashrate_drop_minutes",),
    "TELEGRAM_DAILY_SUMMARY_TIME": ("telegram.daily_summary_time",),
    # TELEGRAM_EVENT_<NAME> -> telegram.events.<name> is a mechanical rename (pithead's tg_event()
    # helper and render_env do the same thing per event), so it's generated below rather than
    # hand-typed 25 times. wallet_changed / clearnet_exposed are the two events NOT in this list —
    # deliberately excluded: they're the tamper-evidence alarms on the very channel a compromised
    # container would use to silence them, so the dashboard must never be able to turn them off.
    # They still render (greyed) in the Notifications > Telegram events nested subgroup (#612).
    # NOTE (2026-08 audit): raffle_win was missing from this generated set for a while — the one
    # event toggle out of step with its siblings. If you add a new event toggle, list it here AND
    # in pithead's CONTROL_DASHBOARD_EDITABLE_KEYS — the drift guard below only catches a mismatch
    # between the two, not an omission from both.
    **{
        f"TELEGRAM_EVENT_{name.upper()}": (f"telegram.events.{name}",)
        for name in (
            "node_down",
            "node_recovered",
            "worker_offline",
            "worker_recovered",
            "worker_joined",
            "worker_left",
            "sync_finished",
            "disk_space",
            "db_unhealthy",
            "db_reset",
            "xvb_no_share",
            "xvb_registration",
            "new_release",
            "stack_online",
            "daily_summary",
            "hashrate_low",
            "hashrate_loss",
            "hugepages",
            "low_ram",
            "high_reject_rate",
            "block_found",
            "payout_found",
            "payout_confirmed",
            "container_unhealthy",
            "raffle_win",
        )
    },
}

# dashboard.energy.* is config.json-only — it never renders to .env (control_approval_gate reads
# it straight off config.json, pithead ~L4879), so it can never appear in the map above — but the
# gate explicitly ALLOWS it (#504). Fold it in as the map's one special-case addition. Worker
# descriptors (workers.list[], #506) are the gate's OTHER config.json-only special
# case, but they're REFUSED outright (per-rig hosts/tokens), so they never get an editable path —
# and buildSections never renders them as a form field anyway (arrays, #172).
_ENERGY_PATHS = (
    "dashboard.energy.cost_per_kwh",
    "dashboard.energy.currency",
    "dashboard.energy.xmr_price",
)


def _editable_paths():
    """Every config path the control gate will actually commit (#613): the env-var allowlist's
    paths, union the dashboard.energy special-case (#504)."""
    paths = {p for target in EDITABLE_ENV_KEY_PATHS.values() for p in target}
    paths.update(_ENERGY_PATHS)
    return sorted(paths)


# Env-var -> config-path map for the CONFIRM-gated set (#719), mirroring pithead's
# CONTROL_DASHBOARD_CONFIRM_KEYS the same way EDITABLE_ENV_KEY_PATHS mirrors the editable allowlist
# (drift-guarded by test_confirm_keys_have_no_intra_repo_drift). These are operationally-disruptive
# but NOT the security perimeter: the dashboard MAY commit them, but only behind a type-to-confirm.
# Surfaced to the browser as ``_confirm_keys`` so the Configuration view renders them editable with
# a "confirm to proceed" affordance instead of greying them out as host-only. The gate is still the
# authority: describe_change decides per-DIRECTION whether a change is CONFIRM (a data-dir move, a
# stratum-port repoint, a clearnet-sync ENABLE, a prune ENABLE) or stays a host-only DEST (prune
# DISABLE, a TOR data-dir move), so a field here can still be refused at commit in its heavy
# direction — the same edit-then-maybe-refuse tradeoff the issue accepts for MONERO_PRUNE.
CONFIRM_ENV_KEY_PATHS = {
    "MONERO_DATA_DIR": ("monero.data_dir",),
    "TARI_DATA_DIR": ("tari.data_dir",),
    "P2POOL_DATA_DIR": ("p2pool.data_dir",),
    "DASHBOARD_DATA_DIR": ("dashboard.data_dir",),
    "STRATUM_PORT": ("p2pool.stratum_port",),
    "MONERO_CLEARNET_SYNC": ("monero.clearnet_initial_sync",),
    "TARI_CLEARNET_SYNC": ("tari.clearnet_initial_sync",),
    "MONERO_PRUNE": ("monero.prune",),
    # 2026-08 security review: bounded (8-1024) and instantly reversible, but the biggest
    # steady-state knob on the shared Tor daemon's CPU — confirm-gated, not free-commit. The same
    # review kept proxy.donate_level and the two payout restore points host-only (donate traffic
    # bypasses the Tor socks5 per docs/privacy.md; a future-dated restore point silently defeats
    # payout-confirmation tamper evidence).
    "MONERO_OUT_PEERS": ("monero.out_peers",),
    # Node endpoints (#1888): confirm-gated, not free-commit, and paired with the approval gate's
    # host-side reachability probe. 42-control-policy-and-host-checks.sh carries the reasoning.
    "MONERO_NODE_HOST": ("monero.remote.host",),
    "MONERO_RPC_PORT": ("monero.remote.rpc_port",),
    "MONERO_ZMQ_PORT": ("monero.remote.zmq_port",),
    "TARI_GRPC_ADDRESS": ("tari.remote.host", "tari.remote.grpc_port"),
}


def _confirm_paths(cfg=None):
    """Every config path the control gate commits behind a type-to-confirm (#719), minus a chain's
    node endpoint (#1888) while that chain is not on a REMOTE node: a local (or, after #1855, an
    "off") chain derives its endpoint from the stack, so offering the field would edit nothing."""
    live = {c for c in ("monero", "tari") if (cfg or {}).get(c, {}).get("mode") == "remote"}
    paths = {p for target in CONFIRM_ENV_KEY_PATHS.values() for p in target}
    return sorted(p for p in paths if ".remote." not in p or p.split(".")[0] in live)


def env_key_config_paths(env_key):
    """The config-path prefixes a committed audit ``keys`` env-var name covers (#530).

    The #33 audit log records a commit's WHAT-changed as env-var NAMES (control_approval_gate's
    ``porcelain_keys``), while the out-of-band host-edit watcher diffs config.json PATHS — so
    correlating "did a commit explain this changed key" needs this env->path bridge. Mirrors the
    commit gate's own derivation: an allowlisted var maps through EDITABLE_ENV_KEY_PATHS, and the
    synthetic ``DASHBOARD_ENERGY`` name (which the gate folds in for a dashboard.energy-only
    commit, a config.json-only block that never renders to .env, #504) covers the whole energy
    block by prefix. An unrecognised name maps to nothing, so it can never explain a diffed key."""
    if env_key == "DASHBOARD_ENERGY":
        return ("dashboard.energy",)
    return EDITABLE_ENV_KEY_PATHS.get(env_key, ())


def _load_core_keys() -> list:
    """The wizard's core-key shortlist (#502/#529), read from the SAME file ``./pithead setup``
    reads — the one shared artifact, not a second hand-maintained list. Degrades to an empty list
    on a missing/unreadable/malformed file, matching the reference-merge fallback below."""
    try:
        with open(config.HOST_CORE_KEYS_PATH) as f:
            keys = json.load(f)
        return keys if isinstance(keys, list) else []
    except (OSError, ValueError):
        logger.warning("config.core-keys.json unavailable — the form renders with no core group.")
        return []


def read_config():
    """The full config schema for the editor's form, every set secret masked to the sentinel.

    ``config.reference.json`` (every key with its default) is merged UNDER the host's sparse,
    pre-masked copy so the form covers the whole schema — a missing/unreadable reference degrades
    to the host copy alone (graft #437). An *empty* secret stays empty, so the UI can tell
    "set — leave blank to keep" from "not set". The copy arrives already masked (#440); the
    masking pass here is defense-in-depth and runs AFTER the merge.

    The response also carries ``_core_keys`` (#529) and ``_editable_keys`` (#613) — both
    underscore-prefixed metadata keys, the same convention ``config.reference.json``'s own
    ``_docs`` uses, so ``buildSections`` on the frontend already skips them as config sections for
    free."""
    cfg = _load_host_config()
    try:
        with open(config.HOST_REFERENCE_PATH) as f:
            reference = json.load(f)
        reference.pop("_docs", None)
        cfg = _deep_merge(reference, cfg)
    except (OSError, ValueError):
        logger.warning("config.reference.json unavailable — serving the host config alone.")
    mask_secrets(cfg)
    cfg["_core_keys"] = _load_core_keys()
    cfg["_editable_keys"] = _editable_paths()
    cfg["_confirm_keys"] = _confirm_paths(cfg)
    return cfg


def submit(action, cfg=None, actor="", intent_id=None, version=None, confirm=None):
    """Write one intent into the requests spool (atomic: temp + rename, so the runner never
    reads a half-written file). Returns the request id — always a UUID, because the id becomes
    a host-side filename and the runner rejects anything else. ``version`` rides only on the
    upgrade intent (#59): the version the operator confirmed, which the host re-verifies
    against the GitHub release API — a proposal, never a target the container picks. ``confirm``
    rides only on a commit intent (#719): the operator's typed confirmation for an in-scope
    disruptive change, which the host gate requires before it lets a CONFIRM row proceed."""
    rid = str(uuid.UUID(intent_id)) if intent_id else str(uuid.uuid4())
    request = {"id": rid, "action": action, "actor": actor}
    if cfg is not None:
        # read_config's own metadata injections (#529/#613/#719) ride back with the editor's POST —
        # both modes round-trip the fetched doc wholesale — and the host gate's closed-schema
        # check would refuse a commit carrying them (#679). Shed them at the one choke point
        # every config intent passes through; everything else unknown still fails closed host-side.
        # A non-dict cfg passes through untouched: the host runner already rejects it with its
        # own "config must be a JSON object" result, which the UI knows how to surface.
        if isinstance(cfg, dict):
            cfg = {
                k: v
                for k, v in cfg.items()
                if k not in ("_core_keys", "_editable_keys", "_confirm_keys")
            }
        request["config"] = cfg
    if version is not None:
        request["version"] = version
    if confirm is not None:
        request["confirm"] = confirm
    return request_spool.write(request)


def submit_worker_apply(worker, changes, actor="", intent_id=None):
    """Spool a worker-config change intent (#185). Carries ONLY the worker NAME and the writable-key
    ``changes`` — never a host, port, or token: the host-side runner resolves the rig's real address
    and bearer from its own config.json (workers.list[]), so a tampered intent can at most target
    another already-configured rig, never an arbitrary host, and the rig token — masked out of this
    container (#440) — never crosses the mount. Returns the request id (always a UUID)."""
    rid = str(uuid.UUID(intent_id)) if intent_id else str(uuid.uuid4())
    request = {
        "id": rid,
        "action": "worker-apply",
        "actor": actor,
        "worker": worker,
        "changes": changes,
    }
    return request_spool.write(request)


def submit_worker_upgrade(worker, version, actor="", intent_id=None):
    """Spool a worker RigForge-upgrade intent (#597). Carries ONLY the worker NAME and the version
    the operator confirmed seeing — never a host, port, or token (the host runner resolves the
    rig's real address and bearer from workers.list[], exactly like worker-apply), and the version
    is a proposal, never a target: the host re-derives the real latest RigForge release over Tor
    and refuses a mismatch. Returns the request id (always a UUID)."""
    rid = str(uuid.UUID(intent_id)) if intent_id else str(uuid.uuid4())
    request = {
        "id": rid,
        "action": "worker-upgrade",
        "actor": actor,
        "worker": worker,
        "version": version,
    }
    return request_spool.write(request)


# The config keys the Worker Inspect editor may change — the exact writable allowlist the rig's
# control API enforces (rigforge WRITABLE, #236). Validated here (fail-closed, defence in depth), on
# the host runner, and finally by the rig itself. NOT writable: identity, filesystem paths, the API
# ports, and the control token — remote mutation of those would be escalation.
WORKER_WRITABLE_KEYS = frozenset(
    {"pools", "DONATION", "autotune", "watchdog", "watchdog_interval_min", "max_temp_c"}
)


def validate_worker_changes(changes):
    """Return an error string if ``changes`` isn't a non-empty object of writable keys, else ''."""
    if not isinstance(changes, dict) or not changes:
        return "changes must be a non-empty object of writable config keys"
    bad = sorted(k for k in changes if k not in WORKER_WRITABLE_KEYS)
    if bad:
        return "keys not writable via the control path: " + ", ".join(bad)
    return ""


def result(rid) -> dict | None:
    """The runner's result for ``rid``, or None while pending. The id is validated as a UUID
    before it touches a path (it arrives from a query param)."""
    rid = str(uuid.UUID(rid))
    try:
        with open(os.path.join(config.CONTROL_RESULTS_DIR, f"{rid}.json")) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


async def wait_result(rid, done=None, timeout_s=None):
    """Poll for the result until ``done(result)`` (default: any result exists) or timeout;
    returns the result dict or None. Commit passes a predicate that skips the still-present
    preview result (same id) until the runner overwrites it with the commit outcome."""
    if timeout_s is None:
        timeout_s = config.CONTROL_WAIT_S
    deadline = time.monotonic() + timeout_s
    while True:
        res = result(rid)
        if res is not None and (done is None or done(res)):
            return res
        if time.monotonic() >= deadline:
            return None
        await asyncio.sleep(_RESULT_POLL_S)

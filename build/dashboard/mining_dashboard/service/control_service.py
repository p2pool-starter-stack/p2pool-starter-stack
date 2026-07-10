"""Dashboard side of the #33 host-mutation channel.

The dashboard never touches the host directly. It reads the config (secrets masked), turns an
edited config into a typed intent, and drops that intent into the container-writable ``requests/``
spool. A root systemd runner on the host (``pithead control-run-pending``) claims the intent,
re-validates it against pithead's own parser, and runs ``pithead apply``. The dashboard can ASK; it
cannot forge a result or rewrite the audit log — ``results/`` and ``audit/`` are mounted read-only.

This module does exactly four things: mask secrets out of the config it hands the browser, merge the
real secrets back into a proposed config, write an intent atomically, and read a result/audit back.
It writes structured JSON only — never a shell string.
"""

import copy
import json
import os
import uuid

# Leaf paths in config.json that hold a secret. On read these are replaced with SECRET_SENTINEL so
# the raw value never reaches the browser (acceptance: GET /api/config cannot read secrets back).
# On write, a sentinel coming back means "unchanged" and the real value is re-inserted.
SECRET_PATHS = (
    ("dashboard", "auth", "password"),
    ("telegram", "bot_token"),
    ("workers", "api_token"),
    ("monero", "node_username"),
    ("monero", "node_password"),
    ("p2pool", "stratum_password"),
)
SECRET_SENTINEL = {"__secret__": True}


def _is_sentinel(value):
    return isinstance(value, dict) and value.get("__secret__") is True


def _get_in(obj, path):
    for key in path:
        if not isinstance(obj, dict) or key not in obj:
            return None
        obj = obj[key]
    return obj


def _set_in(obj, path, value):
    """Set obj[path...] = value, creating intermediate dicts. No-op if an intermediate is a
    non-dict (a malformed proposed config can't smuggle a value under a scalar)."""
    for key in path[:-1]:
        nxt = obj.get(key)
        if not isinstance(nxt, dict):
            return
        obj = nxt
    if isinstance(obj, dict):
        obj[path[-1]] = value


class ControlService:
    def __init__(
        self,
        host_config_path,
        requests_dir,
        results_dir,
        audit_log,
    ):
        self.host_config_path = host_config_path
        self.requests_dir = requests_dir
        self.results_dir = results_dir
        self.audit_log = audit_log

    # --- reads -------------------------------------------------------------------------------

    def _load_config(self):
        with open(self.host_config_path, encoding="utf-8") as fh:
            return json.load(fh)

    def read_config(self):
        """The on-disk config with every secret leaf masked. A secret that is SET becomes the
        sentinel (the form shows 'set — leave blank to keep'); an unset/empty secret stays as-is so
        the form knows it is blank. The raw secret value never leaves the host."""
        cfg = self._load_config()
        for path in SECRET_PATHS:
            value = _get_in(cfg, path)
            if isinstance(value, str) and value != "":
                _set_in(cfg, path, copy.deepcopy(SECRET_SENTINEL))
        return cfg

    def merge_secrets(self, proposed):
        """Return a full config to stage: for each secret leaf, a sentinel means 'keep the current
        value' (re-insert it from disk); anything else is a real change and kept as-is. The proposed
        config is otherwise used verbatim — the host re-validates it before applying."""
        merged = copy.deepcopy(proposed)
        current = self._load_config()
        for path in SECRET_PATHS:
            if _is_sentinel(_get_in(merged, path)):
                _set_in(merged, path, _get_in(current, path))
        return merged

    def result(self, request_id):
        """Read the runner's result for an id, or None if it isn't written yet. Rejects any id that
        isn't a plain uuid before touching the filesystem — the id becomes a path component."""
        if not _valid_uuid(request_id):
            return None
        path = os.path.join(self.results_dir, request_id + ".json")
        try:
            with open(path, encoding="utf-8") as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return None

    def read_audit(self, limit=50):
        """The last ``limit`` audit lines (each a JSON object), newest last. Empty if the log
        doesn't exist yet. audit/ is mounted read-only, so this is a pure read."""
        try:
            with open(self.audit_log, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except OSError:
            return []
        out = []
        for line in lines[-limit:]:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
        return out

    # --- writes (the only thing the dashboard is allowed to do) ------------------------------

    def submit(self, action, config, actor, intent_id=None):
        """Write one typed intent into requests/ atomically (temp + rename, so the runner never sees
        a half-written file). Returns the new request id. ``intent_id`` links a commit to the config
        a prior preview staged. Structured JSON only — no shell strings cross the boundary."""
        request_id = str(uuid.uuid4())
        intent = {
            "id": request_id,
            "action": action,
            "config": config,
            "actor": actor or "unknown",
        }
        if intent_id is not None:
            intent["intent_id"] = intent_id
        os.makedirs(self.requests_dir, exist_ok=True)
        final = os.path.join(self.requests_dir, request_id + ".json")
        tmp = final + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(intent, fh)
        os.replace(tmp, final)
        return request_id


def _valid_uuid(value):
    try:
        uuid.UUID(str(value))
        return True
    except (ValueError, AttributeError, TypeError):
        return False

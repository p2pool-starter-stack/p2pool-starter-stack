"""Prepare wizard-owned config copies for the current schema."""

from copy import deepcopy

_XVB_ALIASES = ("enabled", "url", "donor_id")
_WORKER_FIELDS = {"name", "host", "port", "control_port", "token", "watts"}


def _change(changes: list[str], path: str, replacement: str | None = None) -> None:
    changes.append(f"{path} → {replacement}" if replacement else f"{path} removed")


def _legacy_has_data(value) -> bool:
    """Match jq's ``value // [] != []``: null/false/[] are empty; malformed values are data."""
    return value is not None and value is not False and value != []


def _legacy_conflicts(cfg: dict) -> list[str]:
    conflicts = []
    dashboard = cfg.get("dashboard") if isinstance(cfg.get("dashboard"), dict) else {}
    workers = cfg.get("workers") if isinstance(cfg.get("workers"), dict) else {}
    old_workers, new_workers = dashboard.get("workers", []), workers.get("list", [])
    if (
        _legacy_has_data(old_workers)
        and _legacy_has_data(new_workers)
        and old_workers != new_workers
    ):
        conflicts.append("workers.list and dashboard.workers")
    old_xvb = cfg.get("xmrig_proxy") if isinstance(cfg.get("xmrig_proxy"), dict) else {}
    new_xvb = cfg.get("xvb") if isinstance(cfg.get("xvb"), dict) else {}
    if "xmrig_proxy" in cfg and not isinstance(cfg["xmrig_proxy"], dict):
        if "xvb" in cfg and cfg["xmrig_proxy"] != cfg["xvb"]:
            conflicts.append("xvb and xmrig_proxy")
    for key in _XVB_ALIASES:
        if key in old_xvb and key in new_xvb and old_xvb[key] != new_xvb[key]:
            conflicts.append(f"xvb.{key} and xmrig_proxy.{key}")
    return conflicts


def _migrate_legacy(cfg: dict, changes: list[str]) -> None:
    old_xvb = cfg.pop("xmrig_proxy", None)
    if isinstance(old_xvb, dict):
        new_xvb = cfg.get("xvb")
        can_copy = new_xvb is None or isinstance(new_xvb, dict)
        if new_xvb is None:
            new_xvb = {}
            cfg["xvb"] = new_xvb
        for key, value in old_xvb.items():
            old_path, new_path = f"xmrig_proxy.{key}", f"xvb.{key}"
            if key in _XVB_ALIASES and can_copy and key not in new_xvb:
                new_xvb[key] = value
                _change(changes, old_path, new_path)
            else:
                _change(changes, old_path)
    elif old_xvb is not None and old_xvb is not False:
        if "xvb" not in cfg:
            cfg["xvb"] = old_xvb
            _change(changes, "xmrig_proxy", "xvb")
        else:
            _change(changes, "xmrig_proxy")

    dashboard = cfg.get("dashboard")
    if isinstance(dashboard, dict) and "workers" in dashboard:
        old_workers = dashboard.pop("workers")
        workers = cfg.get("workers")
        can_copy = workers is None or isinstance(workers, dict)
        if workers is None:
            workers = {}
            cfg["workers"] = workers
        if can_copy and _legacy_has_data(old_workers) and not _legacy_has_data(workers.get("list")):
            workers["list"] = old_workers
            _change(changes, "dashboard.workers", "workers.list")
        else:
            _change(changes, "dashboard.workers")


def _known_only(cfg: dict, ref: dict, changes: list[str], prefix: str = "") -> dict:
    known = {}
    for key, value in cfg.items():
        path = f"{prefix}.{key}" if prefix else key
        if key not in ref:
            _change(changes, path)
        elif path == "workers.list" and isinstance(value, list):
            known[key] = []
            for item in value:
                if not isinstance(item, dict):
                    known[key].append(item)
                    continue
                clean = {name: field for name, field in item.items() if name in _WORKER_FIELDS}
                for name in item:
                    if name not in _WORKER_FIELDS:
                        _change(changes, f"{path}[].{name}")
                known[key].append(clean)
        elif isinstance(value, dict) and isinstance(ref[key], dict):
            known[key] = _known_only(value, ref[key], changes, path)
        else:
            # Keep invalid values for known keys. The host parser remains the authority that
            # rejects wrong types and unsafe combinations; this boundary removes names only.
            known[key] = value
    return known


def prepare_config(
    cfg: dict, reference: dict, *, reject_legacy_conflicts: bool = False
) -> tuple[dict, list[str]]:
    """Migrate removed aliases, then retain only names in the current reference schema.

    Values are never included in ``changes``: the list is safe to render beside payout and
    credential fields and persists across a failed install without copying their contents.
    """
    prepared = deepcopy(cfg)
    conflicts = _legacy_conflicts(prepared)
    if reject_legacy_conflicts and conflicts:
        names = "; ".join(conflicts)
        raise ValueError(f"removed 1.x keys differ from their replacements ({names})")
    changes: list[str] = []
    _migrate_legacy(prepared, changes)
    if reference:
        prepared = _known_only(prepared, reference, changes)
    return prepared, list(dict.fromkeys(changes))

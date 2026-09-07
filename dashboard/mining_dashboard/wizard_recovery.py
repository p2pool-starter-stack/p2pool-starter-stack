"""Persist the metadata that reconstructs a failed wizard attempt."""

import json
import os

from aiohttp import web


def recovery_state(spool_json, spool_read, disks: list[dict]) -> tuple[list[str], dict, str]:
    remembered = spool_json("config-changes.json").get("changes", [])
    if not isinstance(remembered, list) or not all(isinstance(item, str) for item in remembered):
        remembered = []

    raw_attempt = spool_json("install-attempt.json")
    offered = {disk["name"] for disk in disks}
    disk, wipe = raw_attempt.get("disk"), raw_attempt.get("wipe")
    attempt = (
        {"disk": disk, "wipe": wipe} if disk in offered and wipe in ("keep", "data", "all") else {}
    )

    raw_mode = spool_read("auth-mode") or "auto"
    auth_mode = raw_mode if raw_mode in ("auto", "set", "none") else "auto"
    return remembered, attempt, auth_mode


def remove_spool(spool: str, *names: str) -> None:
    for name in names:
        path = os.path.join(spool, name)
        if os.path.exists(path):
            os.unlink(path)


def remember_changes(spool: str, changes: list[str], read_json, write_text) -> None:
    previous = read_json("config-changes.json").get("changes", [])
    if not isinstance(previous, list) or not all(isinstance(item, str) for item in previous):
        previous = []
    combined = list(dict.fromkeys([*previous, *changes]))
    if combined:
        write_text("config-changes.json", json.dumps({"changes": combined}))
    else:
        remove_spool(spool, "config-changes.json")


def retry_handler(authed, stage, spool):
    async def retry(request):
        if not authed(request):
            raise web.HTTPFound("/")
        if stage() != "failed":
            return web.json_response({"error": "no failed install to reopen"}, status=409)
        remove_spool(spool(), "error.txt", "installing")
        return web.json_response({"status": "settings"})

    return retry

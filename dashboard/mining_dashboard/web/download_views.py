"""File downloads the control channel produces: routes that stream a host-built artifact.

Split out of web/server.py because that module holds every handler in the app and is at its
recorded line ceiling, so the diagnostics work had no room to register a route. The cut is not
arbitrary: these handlers share a shape none of the others have — they answer with a file the
HOST wrote into the results spool, not with JSON the container assembled, so they carry their own
rules about proving the artifact is finished before streaming it, and none of them take a CSRF
header because all of them are GETs. The support-bundle download joins this module rather than
server.py.
"""

import os
import uuid

from aiohttp import web

from mining_dashboard.config import config
from mining_dashboard.service import control_service


async def handle_backup_download(request):
    """Stream the archive an applied backup produced (#908).

    Read-only, no CSRF header required (matches the other GET routes) — a cross-site GET can
    trigger this but can't read a cross-origin response, and the archive is useless without the
    passphrase shown once in the kit. Any id not resolving to an "applied" archive 404s."""
    try:
        rid = str(uuid.UUID(request.query.get("id", "")))
    except ValueError:
        raise web.HTTPBadRequest(text="'id' must be a UUID.") from None
    res = control_service.result(rid)
    archive_name = (res or {}).get("archive")
    if not res or res.get("status") != "applied" or not archive_name:
        raise web.HTTPNotFound(text="No completed backup for that id.")
    # FileResponse stats the path itself and answers 404 if the archive isn't there — no need to
    # check twice.
    path = os.path.join(config.CONTROL_RESULTS_DIR, f"{rid}.tar.gz.enc")
    return web.FileResponse(
        path, headers={"Content-Disposition": f'attachment; filename="{archive_name}"'}
    )

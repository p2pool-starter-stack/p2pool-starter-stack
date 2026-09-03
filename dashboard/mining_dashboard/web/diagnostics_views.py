"""Service Diagnostics routes (#913 doctor detail, #943 log tail).

Its own module rather than server.py's: that file holds every other handler and is at its
recorded line ceiling. These two handlers are also the channel's only READ-ONLY asks — they
submit an intent the host answers with a report and never a mutation — so they need none of the
approval, confirmation or history-recording machinery the committing handlers around them share.

Both return 202 with a request id; the client polls the existing GET /api/control/result, the
same way preview/commit/upgrade/backup already do. There is no second polling route.

THE TRUST BOUNDARY: this container decides nothing about what may be read. It shape-checks the
request so an obviously malformed one fails fast, and the HOST decides whether a well-formed
container name is one it will serve logs for. A refusal comes back as a "rejected" result with
the host's own reason, which the panel surfaces verbatim rather than reinterpreting.
"""

import logging

from aiohttp import web

from mining_dashboard.service import diagnostics_service

logger = logging.getLogger(__name__)

# Sibling of server.py's identical pair. Kept local rather than imported because server.py
# imports THIS module to register the routes, so the import would be a cycle; folding both into a
# shared guard module is filed, not done here. If you change the header name, change it in both —
# and in the CONTROL_HEADERS constant each of the control .mjs files carries.
CONTROL_HEADER = "X-Pithead-Control"


def _require_control_header(request):
    """Same CSRF guard the mutating control routes use. These are POSTs even though they only
    read, because they spool a request the host acts on — a cross-site POST that queues host work
    is worth refusing whether or not the work mutates anything."""
    if request.headers.get(CONTROL_HEADER) != "1":
        raise web.HTTPForbidden(text="Missing X-Pithead-Control header.")


async def handle_diag_doctor(request):
    """Ask the host to run `doctor --json` and report (#913).

    No body. The appliance operator has no shell: today they can see THAT a service is unhealthy
    and never WHY, and this is the report that closes that gap. doctor's own exit code is a
    failure COUNT, not a run failure, so the host treats a non-zero rc as a valid document."""
    _require_control_header(request)
    try:
        rid = diagnostics_service.submit_diag_doctor(request.headers.get("X-Auth-User", ""))
    except Exception:
        logger.exception("Error submitting diag-doctor request")
        return web.json_response({"error": "Failed to submit the diagnostics request."}, status=500)
    return web.json_response({"id": rid, "status": "pending"}, status=202)


async def handle_diag_logs(request):
    """Ask the host for a bounded, redacted log tail for one container (#943).

    Body: ``container`` (a compose service the host is willing to read) and optional ``lines``.
    Neither is trusted as a bound or as an authorization — the host clamps the count to its own
    cap and matches the name against its own allowlist by exact membership. The tail is redacted
    host-side by the support bundle's redactor before it is written, never here."""
    _require_control_header(request)
    try:
        body = await request.json()
    except Exception:
        raise web.HTTPBadRequest(text="Body must be JSON.") from None
    # `[]` and `"str"` are valid JSON and have no .get — without this they raise past the handler
    # as a 500. A malformed body is the client's error, so it answers 400 like every other one.
    if not isinstance(body, dict):
        raise web.HTTPBadRequest(text="Body must be a JSON object.")
    container = body.get("container")
    if not diagnostics_service.valid_container(container):
        raise web.HTTPBadRequest(text="'container' must be a compose service name.")
    lines = body.get("lines", diagnostics_service.MAX_TAIL_LINES)
    # bool is an int subclass — exclude it, or `{"lines": true}` spools 1.
    if isinstance(lines, bool) or not isinstance(lines, int) or lines < 1:
        raise web.HTTPBadRequest(text="'lines' must be a positive integer.")
    try:
        rid = diagnostics_service.submit_diag_logs(
            container, lines, request.headers.get("X-Auth-User", "")
        )
    except Exception:
        logger.exception("Error submitting diag-logs request")
        return web.json_response({"error": "Failed to submit the diagnostics request."}, status=500)
    return web.json_response({"id": rid, "status": "pending"}, status=202)

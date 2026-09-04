"""One writer for the control-channel requests spool (#1732).

WHY THIS MODULE EXISTS: the temp-then-rename below is a correctness shape, not a convenience.
The host runner watches `CONTROL_REQUESTS_DIR` and reads whatever it finds there, so a request
written in place would be readable while still half-written. Writing to a dotted temp name and
`os.replace`-ing it onto the real name makes the request appear atomically, fully formed or not
at all. That property was being maintained in four separate places — three in `control_service`
and one in `diagnostics_service` — which is three chances for the next intent type to get it
subtly wrong.

WHY IT IS ITS OWN MODULE RATHER THAN A HELPER IN `control_service`: that file sits at its 414-line
budget ceiling with no headroom, and the budget gate refuses a raise on a non-exempt row. The ruled
shape for a zero-headroom file that must receive a line is to split into a new rowless module and
keep the old row, so the writer lands here and `control_service.py` gets smaller instead of larger.

`config` is referenced through the module object on every call, never bound at import time. The
service tests patch `CONTROL_REQUESTS_DIR` onto that shared object; a `from ... import
CONTROL_REQUESTS_DIR` here would read the import-time value and every one of those patches would
silently stop taking effect, which is the failure that leaves a test green while asserting nothing.
"""

import json
import os

from mining_dashboard.config import config


def write(request: dict) -> str:
    """Write one control intent into the requests spool atomically. Returns the request id.

    ``request`` must already carry its ``id``: the id becomes the host-side filename and the
    runner rejects anything that is not a UUID, so minting it is the caller's business — this
    writer does not invent one, because a request whose id was chosen here could not be returned
    to the caller before the file appeared."""
    rid = request["id"]
    tmp = os.path.join(config.CONTROL_REQUESTS_DIR, f".{rid}.tmp")
    with open(tmp, "w") as f:
        json.dump(request, f)
    os.replace(tmp, os.path.join(config.CONTROL_REQUESTS_DIR, f"{rid}.json"))
    return rid

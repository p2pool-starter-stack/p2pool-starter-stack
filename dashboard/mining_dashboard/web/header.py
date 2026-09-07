"""The header's address block: what this machine is called, and how to reach it.

The header names the machine as hostname-then-IP and, when the dashboard is published as a Tor
hidden service, carries its ``.onion`` URL underneath (#1853). Both are *ways in* rather than
status readings, which is why they sit together here instead of among ``views.py``'s metric
formatting.

The three ``DASHBOARD_ONION_*`` values are read in this module rather than in
``config/config.py`` for two reasons that happen to agree. Nothing else in the dashboard consumes
them, so a module-level constant would be indirection for one caller; and ``version.py`` already
establishes the injectable-``env`` reader for a presentation value, which lets a test pass a dict
instead of mutating process state. (``config/config.py`` is also at its recorded file-budget
ceiling, and that ratchet only moves down — see ``docs/dev/file-budget.tsv``.)

Nothing here ever emits client-authorisation key material. The dashboard container is not given
it: ``docker-compose.yml`` passes the enabled flag, the address and the client-auth *boolean*,
and the keys stay host-side behind ``pithead onion-client-key``.
"""

import os

from mining_dashboard.helper.utils import detect_host_ipv4, is_ip_address

# pithead writes the literal "placeholder" into .env when the onion has not been provisioned yet
# (lib/pithead/29-preserved-state-and-dirs.sh), so "enabled" on its own never means "reachable".
# The host's own `dashboard_onion_status` (lib/pithead/04-status.sh) makes exactly these two
# checks before it prints a URL, and this mirrors it rather than inventing a second rule.
_UNPROVISIONED = "placeholder"


def host_display_addr(host):
    """The numeric IP to show *beside* the configured host in the header, or ``None`` (Issue #119).

    The configured ``dashboard.host`` is often a hostname that won't resolve from another machine
    on the LAN (flaky mDNS/``.local``, no DNS entry), so we surface the host's primary IP next to
    it as a fallback way in. Returns ``None`` — meaning "show the host alone" — when there's
    nothing useful to add: the host is already an IP, the address can't be determined, or it just
    duplicates the host.
    """
    if is_ip_address(host):
        return None
    addr = detect_host_ipv4()
    if not addr or addr == host:
        return None
    return addr


def dashboard_onion(env=None):
    """The dashboard's ``.onion`` way in for the header, or ``None`` when there isn't one (#1853).

    Answers ``{"url", "client_auth"}`` only when the onion is both **enabled and provisioned** —
    the same pair of conditions the host applies before `pithead status` prints the line. An
    onion that is switched on but has no address yet is not a way in, so it renders as nothing at
    all rather than as an empty row the operator would read as breakage.

    ``client_auth`` is a boolean and never more than that: with client authorisation on, the URL
    alone does not open, and the *reason* is what the header has to say. The key that would open
    it is deliberately not in this container's environment, so this function could not leak it
    even if it tried to.

    The address is required to end in ``.onion``. That is a sanity check against a status word
    reaching the header, not v3 address validation — a stricter rule would silently hide a real
    address the day the address format changes, and hiding is the failure that looks like Tor
    being broken.
    """
    env = os.environ if env is None else env
    if env.get("DASHBOARD_ONION_ENABLED", "").strip().lower() != "true":
        return None
    address = env.get("DASHBOARD_ONION_ADDRESS", "").strip()
    if not address or address == _UNPROVISIONED or not address.endswith(".onion"):
        return None
    return {
        # The full URL, assembled here so the client renders one pasteable string and cannot
        # build a broken one. http:// matches the host's own line: the hidden service supplies
        # the encryption and authentication that TLS would, and Tor Browser expects this form.
        "url": f"http://{address}",
        "client_auth": env.get("DASHBOARD_ONION_CLIENT_AUTH", "").strip().lower() == "true",
    }

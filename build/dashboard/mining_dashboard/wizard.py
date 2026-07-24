"""First-boot setup wizard (#77 phase 3).

A deliberately tiny aiohttp app the host runs pre-provisioning via
``pithead firstboot-wizard``: token gate -> a form mirroring the CLI wizard's
questions -> an atomically written candidate config in the spool. The HOST does
everything privileged (validation, ``pithead setup``) — this container only asks,
the same trust shape as the #33 control channel. Serves plain HTTP on a trusted
LAN with secret minimization: wallet addresses and shape choices only; the
dashboard password is generated host-side and never crosses this window.

Env contract (set by ``pithead firstboot-wizard``):
  WIZARD_TOKEN   one-time human-typable token printed on the console
  WIZARD_SPOOL   rw spool dir (default /wizard-spool)
  WIZARD_BIND    bind host:port (default 0.0.0.0:8000)

After ``MAX_FAILURES`` bad tokens the process exits 3; the host re-mints a fresh
token and restarts the container — the re-mint loop lives host-side on purpose.
"""

import hmac
import json
import os
import sys
import tempfile

from aiohttp import web

MAX_FAILURES = 5
EXIT_TOKEN_LOCKOUT = 3

COOKIE = "wizard_session"

PAGE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pithead setup</title>
<style>
body {{ font-family: system-ui, sans-serif; max-width: 34rem; margin: 3rem auto; padding: 0 1rem; }}
label {{ display: block; margin: 1rem 0 0.25rem; font-weight: 600; }}
input, select {{ width: 100%; padding: 0.5rem; box-sizing: border-box; }}
button {{ margin-top: 1.5rem; padding: 0.6rem 1.4rem; }}
.err {{ color: #b00020; }} .note {{ color: #555; font-size: 0.9rem; }}
</style></head><body>
<h1>Pithead setup</h1>
{body}
</body></html>"""

GATE_FORM = """<p>Enter the one-time token shown on this machine's console or terminal.</p>
{error}
<form method="post" action="/auth">
<label for="token">Token</label>
<input id="token" name="token" autofocus autocomplete="off" placeholder="pit-XXXXXX">
<button type="submit">Continue</button>
</form>"""

SETUP_FORM = """<p>Answers apply once; everything else keeps its documented default and is
editable later from the dashboard.</p>
{error}
<form method="post" action="/submit">
<label for="mw">Monero payout address (primary, starts with 4)</label>
<input id="mw" name="monero_wallet" required minlength="95" maxlength="95">
<label for="tw">Tari payout address</label>
<input id="tw" name="tari_wallet" required>
<label for="mode">Monero node</label>
<select id="mode" name="monero_mode" onchange="r.style.display=this.value=='remote'?'block':'none'">
<option value="local">Run the bundled node (default)</option>
<option value="remote">Use a remote node I control</option>
</select>
<div id="r" style="display:none">
<label for="rh">Remote node host</label>
<input id="rh" name="remote_host" placeholder="192.168.1.10">
</div>
<label for="pool">P2Pool sidechain</label>
<select id="pool" name="pool">
<option value="mini">mini (default — best for most miners)</option>
<option value="main">main (for large hashrate)</option>
</select>
<label for="ibd">First sync</label>
<select id="ibd" name="clearnet_sync">
<option value="false">Fully private over Tor (days)</option>
<option value="true">Faster over clearnet, then Tor (hours)</option>
</select>
<button type="submit">Apply</button>
<p class="note">On Apply, this machine validates and provisions itself; the dashboard
login is generated and shown on the console.</p>
</form>"""

DONE = """<p><strong>Configuration received.</strong> This machine is validating and
provisioning itself — watch the console for the dashboard address and the generated
login. This setup page closes when provisioning completes.</p>
<p class="note" id="s">Waiting…</p>
<script>
setInterval(async () => {
  const t = await (await fetch('/status')).text();
  document.getElementById('s').textContent = t;
}, 2000);
</script>"""


def spool_dir() -> str:
    return os.environ.get("WIZARD_SPOOL", "/wizard-spool")


def _spool_read(name: str) -> str | None:
    """Blocking on purpose: single-operator page, tiny local files."""
    path = os.path.join(spool_dir(), name)
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return f.read().strip()


def _authed(request: web.Request) -> bool:
    tok = os.environ.get("WIZARD_TOKEN", "")
    return bool(tok) and hmac.compare_digest(request.cookies.get(COOKIE, ""), tok)


async def index(request: web.Request) -> web.Response:
    if _authed(request):
        raise web.HTTPFound("/setup")
    return web.Response(text=PAGE.format(body=GATE_FORM.format(error="")), content_type="text/html")


async def auth(request: web.Request) -> web.Response:
    form = await request.post()
    tok = os.environ.get("WIZARD_TOKEN", "")
    supplied = str(form.get("token", "")).strip()
    if tok and hmac.compare_digest(supplied, tok):
        resp = web.HTTPFound("/setup")
        resp.set_cookie(COOKIE, tok, httponly=True)
        raise resp
    request.app["failures"] += 1
    if request.app["failures"] >= MAX_FAILURES:
        # The host restarts the container with a fresh token; nothing to serve beyond this.
        print("wizard: token failure limit reached — exiting for a re-mint", flush=True)
        request.app["exit"](EXIT_TOKEN_LOCKOUT)
    return web.Response(
        text=PAGE.format(body=GATE_FORM.format(error='<p class="err">Wrong token.</p>')),
        content_type="text/html",
        status=403,
    )


async def setup_form(request: web.Request) -> web.Response:
    if not _authed(request):
        raise web.HTTPFound("/")
    prev = _spool_read("error.txt")
    err = f'<p class="err">{prev}</p>' if prev else ""
    return web.Response(
        text=PAGE.format(body=SETUP_FORM.format(error=err)), content_type="text/html"
    )


def build_config(form: dict) -> dict:
    """The submitted answers as a pithead config.json — mirrors the CLI wizard's
    question set; the host's parse_and_validate_config is the validator."""
    cfg = {
        "monero": {"wallet_address": str(form.get("monero_wallet", "")).strip()},
        "tari": {"wallet_address": str(form.get("tari_wallet", "")).strip()},
        "p2pool": {
            "pool": str(form.get("pool", "mini")),
            "stratum_password": "auto",
        },
    }
    if form.get("monero_mode") == "remote":
        cfg["monero"]["mode"] = "remote"
        cfg["monero"]["remote"] = {"host": str(form.get("remote_host", "")).strip()}
    if form.get("clearnet_sync") == "true":
        cfg["monero"]["clearnet_initial_sync"] = True
        cfg["tari"]["clearnet_initial_sync"] = True
    return cfg


def _spool_write_config(cfg: dict) -> None:
    """Atomic write: the host's consume loop only ever sees a complete file."""
    sd = spool_dir()
    os.makedirs(sd, exist_ok=True)
    err_file = os.path.join(sd, "error.txt")
    if os.path.exists(err_file):
        os.unlink(err_file)
    fd, tmp = tempfile.mkstemp(dir=sd, prefix=".config.")
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, os.path.join(sd, "config.json"))


async def submit(request: web.Request) -> web.Response:
    if not _authed(request):
        raise web.HTTPFound("/")
    form = await request.post()
    _spool_write_config(build_config(dict(form)))
    return web.Response(text=PAGE.format(body=DONE), content_type="text/html")


async def status(request: web.Request) -> web.Response:
    if _spool_read("applied") is not None:
        return web.Response(text="Provisioned — the dashboard is coming up now.")
    err = _spool_read("error.txt")
    if err is not None:
        return web.Response(text=f"Rejected: {err} — go back and correct the form.")
    return web.Response(text="Waiting for this machine to validate and apply…")


def make_app(exit_fn=sys.exit) -> web.Application:
    app = web.Application()
    app["failures"] = 0
    app["exit"] = exit_fn
    app.add_routes(
        [
            web.get("/", index),
            web.post("/auth", auth),
            web.get("/setup", setup_form),
            web.post("/submit", submit),
            web.get("/status", status),
        ]
    )
    return app


def main() -> None:
    if not os.environ.get("WIZARD_TOKEN"):
        print("wizard: WIZARD_TOKEN is required", file=sys.stderr)
        sys.exit(2)
    bind = os.environ.get("WIZARD_BIND", "0.0.0.0:8000")
    host, _, port = bind.rpartition(":")
    web.run_app(make_app(), host=host or "0.0.0.0", port=int(port))


if __name__ == "__main__":
    main()

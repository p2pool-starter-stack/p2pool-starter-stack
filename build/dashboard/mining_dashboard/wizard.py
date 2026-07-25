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

INSTALL_FORM = """<p>This machine is running from the installation medium. Choose the disk to
install onto — everything on it is erased unless it already holds a Pithead data partition.</p>
{error}
<form method="post" action="/install">
<label for="disk">Target disk</label>
<select id="disk" name="disk" required>
<option value="" selected disabled>Choose a disk…</option>
{options}
</select>
<label for="confirm">Type the disk name to confirm</label>
<input id="confirm" name="confirm" autocomplete="off" placeholder="e.g. nvme0n1">
<button type="submit">Erase and install</button>
<p class="note">Disks already holding a Pithead <code>data</code> partition are reinstalled in
place and keep their synced chain. Everything else is erased.</p>
</form>"""

INSTALLING = """<p><strong>Installing.</strong> Do not power the machine off. When it finishes,
reboot and remove the installation medium — the setup page comes back on the installed
system.</p>
<p class="note" id="s">Working…</p>
<script>
setInterval(async () => {
  const t = await (await fetch('/status')).text();
  document.getElementById('s').textContent = t;
}, 2000);
</script>"""

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


def installer_mode() -> bool:
    """The host sets this when it booted from removable media and a target disk exists.
    The container never probes hardware — it renders what the host put in the spool."""
    return _spool_read("disks.tsv") is not None


def _disk_options() -> str:
    """Disks the host offered, as <option>s. Never preselected: the first click must be a
    deliberate choice, because this step erases a disk."""
    raw = _spool_read("disks.tsv") or ""
    out = []
    for line in raw.splitlines():
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        name, size, model, serial, state = parts[:5]
        note = {
            "pithead-with-data": " — reinstall, keeps existing data",
            "pithead": " — reinstall, no data partition found",
        }.get(state, " — will be erased")
        label = f"{name}  {size}  {model} (SN {serial}){note}"
        out.append(f'<option value="{name}">{label}</option>')
    return "\n".join(out)


def _authed(request: web.Request) -> bool:
    tok = os.environ.get("WIZARD_TOKEN", "")
    return bool(tok) and hmac.compare_digest(request.cookies.get(COOKIE, ""), tok)


async def index(request: web.Request) -> web.Response:
    if _authed(request):
        raise web.HTTPFound("/install" if installer_mode() else "/setup")
    return web.Response(text=PAGE.format(body=GATE_FORM.format(error="")), content_type="text/html")


async def auth(request: web.Request) -> web.Response:
    form = await request.post()
    tok = os.environ.get("WIZARD_TOKEN", "")
    supplied = str(form.get("token", "")).strip()
    if tok and hmac.compare_digest(supplied, tok):
        resp = web.HTTPFound("/install" if installer_mode() else "/setup")
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


async def install_form(request: web.Request) -> web.Response:
    if not _authed(request):
        raise web.HTTPFound("/")
    prev = _spool_read("error.txt")
    err = f'<p class="err">{prev}</p>' if prev else ""
    body = INSTALL_FORM.format(error=err, options=_disk_options())
    return web.Response(text=PAGE.format(body=body), content_type="text/html")


async def install(request: web.Request) -> web.Response:
    if not _authed(request):
        raise web.HTTPFound("/")
    form = await request.post()
    disk = str(form.get("disk", "")).strip()
    confirm = str(form.get("confirm", "")).strip()
    valid = {ln.split("\t")[0] for ln in (_spool_read("disks.tsv") or "").splitlines() if ln}
    # Three independent gates, because this erases a disk: the target must be one the HOST
    # offered (never a name the browser invented), and the operator must retype it exactly.
    if disk not in valid:
        err = '<p class="err">Choose a disk from the list.</p>'
    elif confirm != disk:
        err = f'<p class="err">Type <code>{disk}</code> exactly to confirm.</p>'
    else:
        _spool_write_text("install-target", disk)
        return web.Response(text=PAGE.format(body=INSTALLING), content_type="text/html")
    body = INSTALL_FORM.format(error=err, options=_disk_options())
    return web.Response(text=PAGE.format(body=body), content_type="text/html", status=400)


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


def _spool_write_text(name: str, text: str) -> None:
    """Atomic like the config write: the host's loop must never see a partial target name."""
    sd = spool_dir()
    os.makedirs(sd, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=sd, prefix=f".{name}.")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, os.path.join(sd, name))


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
    if installer_mode():
        if _spool_read("installed") is not None:
            return web.Response(text="Installed — reboot and remove the installation medium.")
        err = _spool_read("error.txt")
        if err is not None:
            return web.Response(text=f"Install failed: {err}")
        return web.Response(text="Copying the system to the disk…")
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
            web.get("/install", install_form),
            web.post("/install", install),
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

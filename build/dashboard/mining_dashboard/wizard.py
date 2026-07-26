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
import html
import json
import os
import sys
import tempfile

from aiohttp import web

MAX_FAILURES = 5
EXIT_TOKEN_LOCKOUT = 3

COOKIE = "wizard_session"


def _canon_token(t: str) -> str:
    """The operator is transcribing from a console, often on a phone that autocapitalizes.
    Case and the pit- prefix carry no entropy — the six-character suffix does — so neither
    should be able to fail a correct transcription."""
    t = t.strip().upper()
    return t.removeprefix("PIT-")

PAGE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pithead setup</title>
<style>
body {{ font-family: system-ui, sans-serif; max-width: 38rem; margin: 3rem auto; padding: 0 1rem; line-height: 1.5; }}
h2 {{ margin: 2rem 0 0; font-size: 1.05rem; border-bottom: 1px solid #ddd; padding-bottom: 0.3rem; }}
.addr {{ font-family: ui-monospace, monospace; font-size: 0.85rem; }}
.when {{ display: none; margin-left: 0.75rem; padding-left: 0.75rem; border-left: 2px solid #ddd; }}
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
<input id="token" name="token" autofocus autocomplete="off" autocapitalize="off"
       spellcheck="false" placeholder="pit-XXXXXX">
<p class="note">Case doesn't matter, and the <code>pit-</code> prefix is optional.</p>
<button type="submit">Continue</button>
</form>"""

SETUP_FORM = """<p>Only the answers that cannot be guessed for you. Everything else keeps its
documented default and stays editable from the dashboard.</p>
{error}
<form method="post" action="/submit" id="f">

<h2>Payout addresses</h2>
<p class="note">Paste these — they are far too long to type, and a typo pays a stranger.</p>

<label for="mw">Monero payout address</label>
<input id="mw" name="monero_wallet" class="addr" required autocomplete="off" spellcheck="false"
       autocapitalize="off" placeholder="4… (95 characters)">
<p class="note" id="mwn">Must be your PRIMARY address — it starts with 4. p2pool cannot pay a
subaddress (8…) or an integrated address.</p>

<label for="tw">Tari payout address</label>
<input id="tw" name="tari_wallet" class="addr" required autocomplete="off" spellcheck="false"
       autocapitalize="off" placeholder="Tari address">
<p class="note">Merge-mining earns Tari from the same work that mines Monero — this stack always
does both, so it needs both addresses. Get one from Tari Universe or any Tari wallet.</p>

<h2>Monero node</h2>
<label for="mmode">Where does Monero data come from?</label>
<select id="mmode" name="monero_mode">
<option value="local">Run the bundled node on this machine (default)</option>
<option value="remote">Use a Monero node I already run</option>
</select>
<div class="when" id="mremote">
  <label for="mrh">Node host</label>
  <input id="mrh" name="monero_remote_host" placeholder="192.168.1.10" autocomplete="off">
  <label for="mrr">RPC port</label>
  <input id="mrr" name="monero_remote_rpc" value="18081" inputmode="numeric" pattern="[0-9]+">
  <label for="mrz">ZMQ port</label>
  <input id="mrz" name="monero_remote_zmq" value="18083" inputmode="numeric" pattern="[0-9]+">
  <label><input type="checkbox" id="mra" name="monero_remote_auth" value="1"> This node requires a
  username and password</label>
  <div class="when" id="mrauth">
    <label for="mru">Node username</label>
    <input id="mru" name="monero_remote_user" autocomplete="off">
    <label for="mrp">Node password</label>
    <input id="mrp" name="monero_remote_pass" type="password" autocomplete="new-password">
  </div>
</div>

<h2>Tari node</h2>
<label for="tmode">Where does Tari data come from?</label>
<select id="tmode" name="tari_mode">
<option value="local">Run the bundled node on this machine (default)</option>
<option value="remote">Use a Tari node I already run</option>
</select>
<div class="when" id="tremote">
  <label for="trh">Node host</label>
  <input id="trh" name="tari_remote_host" placeholder="192.168.1.10" autocomplete="off">
  <label for="trg">gRPC port</label>
  <input id="trg" name="tari_remote_grpc" value="18142" inputmode="numeric" pattern="[0-9]+">
  <p class="note">Only over a network you trust — this connection is not encrypted.</p>
</div>

<h2>Mining</h2>
<label for="pool">P2Pool sidechain</label>
<select id="pool" name="pool">
<option value="mini">mini — right for almost every home rig (default)</option>
<option value="main">main — only for very large hashrate</option>
</select>

<label><input type="checkbox" name="local_miner" value="1"> Also mine with this machine's own CPU</label>
<p class="note">Leave off if this box only coordinates other miners. A node that is also mining
shares its CPU with the chain it is serving.</p>

<h2>First sync</h2>
<label for="ibd">Downloading the chain the first time</label>
<select id="ibd" name="clearnet_sync">
<option value="false">Private, over Tor — takes days</option>
<option value="true">Faster, over the open internet, then Tor afterwards — takes hours</option>
</select>

<label for="tz">Time zone</label>
<input id="tz" name="timezone" value="auto" autocomplete="off" list="tzs">
<datalist id="tzs">
<option value="auto"><option value="UTC"><option value="America/New_York"><option value="America/Chicago">
<option value="America/Denver"><option value="America/Los_Angeles"><option value="America/Sao_Paulo">
<option value="Europe/London"><option value="Europe/Berlin"><option value="Europe/Warsaw">
<option value="Africa/Johannesburg"><option value="Asia/Dubai"><option value="Asia/Kolkata">
<option value="Asia/Singapore"><option value="Asia/Tokyo"><option value="Australia/Sydney">
</datalist>
<p class="note"><code>auto</code> uses this machine's own setting. For dashboard timestamps
and the daily summary — anything like <code>Europe/Berlin</code>.</p>

<button type="submit">Apply</button>
<p class="note">This machine validates and provisions itself. The dashboard login is generated
here and shown on the console — it never travels over this page.</p>
</form>
<script>
const $ = (id) => document.getElementById(id);
const toggle = (el, on) => {{ el.style.display = on ? 'block' : 'none'; }};
const sync = () => {{
  toggle($('mremote'), $('mmode').value === 'remote');
  toggle($('tremote'), $('tmode').value === 'remote');
  toggle($('mrauth'), $('mra').checked);
}};
['mmode','tmode','mra'].forEach(id => $(id).addEventListener('change', sync));
sync();

// Tell the operator what is wrong with a pasted address immediately, instead of after a submit
// round-trip. The HOST re-validates — this only saves a wasted trip.
$('mw').addEventListener('input', () => {{
  const v = $('mw').value.trim(), n = $('mwn');
  if (!v) {{ n.textContent = 'Must be your PRIMARY address — it starts with 4.'; n.className='note'; return; }}
  if (v[0] === '8') {{ n.textContent = 'That is a subaddress (8…). p2pool cannot pay it — use your primary address.'; n.className='err'; }}
  else if (v.length > 95) {{ n.textContent = 'That looks like an integrated address. Use your plain primary address.'; n.className='err'; }}
  else if (v[0] !== '4') {{ n.textContent = 'A primary Monero address starts with 4.'; n.className='err'; }}
  else if (v.length !== 95) {{ n.textContent = v.length + ' of 95 characters.'; n.className='note'; }}
  else {{ n.textContent = 'Looks like a valid primary address.'; n.className='note'; }}
}});
</script>"""

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
<input id="confirm" name="confirm" autocomplete="off" autocapitalize="off" spellcheck="false"
       placeholder="choose a disk above first">
<button type="submit">Erase and install</button>
<p class="note">Disks already holding a Pithead <code>data</code> partition are reinstalled in
place and keep their synced chain. Everything else is erased.</p>
</form>
<script>
document.getElementById('disk').addEventListener('change', e =>
  document.getElementById('confirm').placeholder = e.target.value);
</script>"""

INSTALLING = """<p><strong>Installing.</strong> Do not power the machine off — it powers
itself off when the copy is done. Then remove the USB stick and power the machine back on;
this setup page comes back, served from the installed system.</p>
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
        name, size, model, serial, state = (html.escape(p) for p in parts[:5])
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
    if tok and hmac.compare_digest(_canon_token(supplied), _canon_token(tok)):
        resp = web.HTTPFound("/install" if installer_mode() else "/setup")
        resp.set_cookie(COOKIE, tok, httponly=True, samesite="Strict")
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
    if not installer_mode():
        raise web.HTTPFound("/setup")
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
        # A fresh attempt clears the previous attempt's error, exactly as the config path does —
        # otherwise the status poll keeps reporting a failure the operator already moved past.
        err_file = os.path.join(spool_dir(), "error.txt")
        if os.path.exists(err_file):
            os.unlink(err_file)
        _spool_write_text("install-target", disk)
        return web.Response(text=PAGE.format(body=INSTALLING), content_type="text/html")
    body = INSTALL_FORM.format(error=err, options=_disk_options())
    return web.Response(text=PAGE.format(body=body), content_type="text/html", status=400)


async def setup_form(request: web.Request) -> web.Response:
    if not _authed(request):
        raise web.HTTPFound("/")
    if installer_mode():
        # This machine is running from the installation medium: a config submitted now would
        # land in the STICK's spool and vanish. Install first; configure the installed system.
        raise web.HTTPFound("/install")
    prev = _spool_read("error.txt")
    err = f'<p class="err">{prev}</p>' if prev else ""
    return web.Response(
        text=PAGE.format(body=SETUP_FORM.format(error=err)), content_type="text/html"
    )


def build_config(form: dict) -> dict:
    """The submitted answers as a pithead config.json. Mirrors the CLI wizard's question set;
    the HOST's parse_and_validate_config is the validator, so this only shapes, never decides.

    Keys are omitted rather than written empty: an absent key inherits the documented default,
    while an empty string is a value and would override it."""

    def s_(name: str) -> str:
        return str(form.get(name, "")).strip()

    def port(name: str, fallback: int) -> int:
        raw = s_(name)
        return int(raw) if raw.isdigit() else fallback

    cfg: dict = {
        "monero": {"wallet_address": s_("monero_wallet")},
        "tari": {},
        "p2pool": {"pool": s_("pool") or "mini", "stratum_password": "auto"},
    }

    # Both addresses are REQUIRED — tari.mode is local|remote only, there is no Monero-only
    # mode in this product, and the CLI wizard enforces the same. An empty value still passes
    # through so the host's validator produces the error, keeping one source of rejections.
    cfg["tari"]["wallet_address"] = s_("tari_wallet")

    if form.get("monero_mode") == "remote":
        cfg["monero"]["mode"] = "remote"
        remote = {
            "host": s_("monero_remote_host"),
            "rpc_port": port("monero_remote_rpc", 18081),
            "zmq_port": port("monero_remote_zmq", 18083),
        }
        cfg["monero"]["remote"] = remote
        if form.get("monero_remote_auth"):
            cfg["monero"]["node_username"] = s_("monero_remote_user")
            cfg["monero"]["node_password"] = s_("monero_remote_pass")

    if form.get("tari_mode") == "remote":
        cfg["tari"]["mode"] = "remote"
        cfg["tari"]["remote"] = {
            "host": s_("tari_remote_host"),
            "grpc_port": port("tari_remote_grpc", 18142),
        }

    if form.get("local_miner"):
        cfg["local_miner"] = {"enabled": True}

    if form.get("clearnet_sync") == "true":
        cfg["monero"]["clearnet_initial_sync"] = True
        cfg["tari"]["clearnet_initial_sync"] = True

    tz = s_("timezone")
    if tz and tz != "auto":  # auto IS the documented default — writing it would only pin it
        cfg.setdefault("dashboard", {})["timezone"] = tz

    if not cfg["tari"]:
        del cfg["tari"]
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
            return web.Response(text="Installed — the machine is powering off. Remove the stick, then power it back on.")
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

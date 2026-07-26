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

# Two-way binding between the simple fields and the JSON. Kept out of the .format() template on
# purpose: JS braces inside one must be doubled, and getting that wrong 500s the page.
BIND_SCRIPT = """
<script>
(function () {
  const cfg = JSON.parse(document.getElementById('cfg-seed').textContent);
  const box = document.getElementById('cfg');
  const err = document.getElementById('cfgerr');
  const fields = Array.from(document.querySelectorAll('[data-path]'));

  const get = (o, p) => p.split('.').reduce((a, k) => (a == null ? a : a[k]), o);
  const set = (o, p, v) => {
    const ks = p.split('.');
    let cur = o;
    ks.slice(0, -1).forEach(k => { if (typeof cur[k] !== 'object' || cur[k] === null) cur[k] = {}; cur = cur[k]; });
    cur[ks[ks.length - 1]] = v;
  };
  // The form's value is always a string; the config's type is not. Coerce to whatever the
  // reference already holds so a port stays a number and a toggle stays a boolean.
  const coerce = (el, raw) => {
    if (el.type === 'checkbox') return el.checked;
    if (raw === 'true') return true;
    if (raw === 'false') return false;
    if (/^[0-9]+$/.test(raw) && typeof get(cfg, el.dataset.path) === 'number') return parseInt(raw, 10);
    return raw;
  };
  const render = () => { box.value = JSON.stringify(cfg, null, 2); };

  // JSON -> form, so a reopened page (or a rejected attempt) shows what is actually set.
  const load = () => {
    fields.forEach(el => {
      const v = get(cfg, el.dataset.path);
      if (v === undefined || v === null) return;
      if (el.type === 'checkbox') el.checked = !!v;
      else el.value = String(v);
    });
    if (window.syncBlocks) window.syncBlocks();
  };

  fields.forEach(el => ['input', 'change'].forEach(ev => el.addEventListener(ev, () => {
    set(cfg, el.dataset.path, coerce(el, el.value));
    render();
  })));

  // Hand-edited JSON wins, and its shape is checked as it is typed.
  box.addEventListener('input', () => {
    try {
      const next = JSON.parse(box.value);
      err.textContent = '';
      Object.keys(cfg).forEach(k => delete cfg[k]);
      Object.assign(cfg, next);
      load();
    } catch (e) { err.textContent = 'Not valid JSON: ' + e.message; }
  });

  load();
  render();
})();
</script>"""

SETUP_FORM = """<p>Only the answers that cannot be guessed for you. Everything else keeps its
documented default and stays editable from the dashboard.</p>
{error}
<form method="post" action="/submit" id="f">

<h2>Payout addresses</h2>
<p class="note">Paste these — they are far too long to type, and a typo pays a stranger.</p>

<label for="mw">Monero payout address</label>
<input id="mw" name="monero_wallet" data-path="monero.wallet_address" class="addr" required autocomplete="off" spellcheck="false"
       autocapitalize="off" placeholder="4… (95 characters)">
<p class="note" id="mwn">Must be your PRIMARY address — it starts with 4. p2pool cannot pay a
subaddress (8…) or an integrated address.</p>

<label for="tw">Tari payout address</label>
<input id="tw" name="tari_wallet" data-path="tari.wallet_address" class="addr" required autocomplete="off" spellcheck="false"
       autocapitalize="off" placeholder="Tari address">
<p class="note">Merge-mining earns Tari from the same work that mines Monero — this stack always
does both, so it needs both addresses. Get one from Tari Universe or any Tari wallet.</p>

<h2>Monero node</h2>
<label for="mmode">Where does Monero data come from?</label>
<select id="mmode" name="monero_mode" data-path="monero.mode">
<option value="local">Run the bundled node on this machine (default)</option>
<option value="remote">Use a Monero node I already run</option>
</select>
<div class="when" id="mlocal">
  <label for="prune">Chain size</label>
  <select id="prune" name="prune" data-path="monero.prune">
  <option value="true">Pruned — about 120 GB (default, mines exactly the same)</option>
  <option value="false">Full — about 320 GB (only if you need the whole chain)</option>
  </select>
  <p class="note">A local Tari node adds about 170 GB on top. Under roughly 350 GB of disk,
  pruned Monero plus a <em>remote</em> Tari node is the combination that fits.</p>
</div>
<div class="when" id="mremote">
  <label for="mrh">Node host</label>
  <input id="mrh" name="monero_remote_host" data-path="monero.remote.host" placeholder="192.168.1.10 or my-node.local"
         autocomplete="off" spellcheck="false">
  <label for="mrr">RPC port</label>
  <input id="mrr" name="monero_remote_rpc" data-path="monero.remote.rpc_port" value="18081" inputmode="numeric" pattern="[0-9]+">
  <label for="mrz">ZMQ port</label>
  <input id="mrz" name="monero_remote_zmq" data-path="monero.remote.zmq_port" value="18083" inputmode="numeric" pattern="[0-9]+">
  <label><input type="checkbox" id="mra" name="monero_remote_auth" value="1"> This node requires a
  username and password</label>
  <div class="when" id="mrauth">
    <label for="mru">Node username</label>
    <input id="mru" name="monero_remote_user" data-path="monero.node_username" autocomplete="off">
    <label for="mrp">Node password</label>
    <input id="mrp" name="monero_remote_pass" data-path="monero.node_password" type="password" autocomplete="new-password">
  </div>
</div>

<h2>Tari node</h2>
<label for="tmode">Where does Tari data come from?</label>
<select id="tmode" name="tari_mode" data-path="tari.mode">
<option value="local">Run the bundled node on this machine (default)</option>
<option value="remote">Use a Tari node I already run</option>
</select>
<div class="when" id="tremote">
  <label for="trh">Node host</label>
  <input id="trh" name="tari_remote_host" data-path="tari.remote.host" placeholder="192.168.1.10 or my-node.local"
         autocomplete="off" spellcheck="false">
  <label for="trg">gRPC port</label>
  <input id="trg" name="tari_remote_grpc" data-path="tari.remote.grpc_port" value="18142" inputmode="numeric" pattern="[0-9]+">
  <p class="note">An IP or a hostname both work. Only over a network you trust — this
  connection is not encrypted.</p>
</div>

<h2>Mining</h2>
<label for="pool">P2Pool sidechain</label>
<select id="pool" name="pool" data-path="p2pool.pool">
<option value="mini">mini — right for almost every home rig (default)</option>
<option value="nano">nano — a single low-power rig</option>
<option value="main">main — only for very large hashrate</option>
</select>
<p class="note">The sidechains are sized by hashrate so miners find shares at a similar
cadence. Too large a tier means waiting days between shares; it costs nothing to change
later.</p>

<label><input type="checkbox" name="local_miner" value="1" data-path="local_miner.enabled"> Also mine with this machine's own CPU</label>
<p class="note">Leave off if this box only coordinates other miners. A node that is also mining
shares its CPU with the chain it is serving.</p>

<h2>First sync</h2>
<label for="ibd">Downloading the chain the first time</label>
<select id="ibd" name="clearnet_sync">
<option value="false">Private, over Tor — takes days</option>
<option value="true">Faster, over the open internet, then Tor afterwards — takes hours</option>
</select>

<h2>Alerts <span class="note">(optional — skip both if you are not sure)</span></h2>

<label for="hc">Healthchecks.io ping URL</label>
<input id="hc" name="healthchecks_url" data-path="healthchecks.ping_url" autocomplete="off" spellcheck="false"
       placeholder="https://hc-ping.com/your-uuid">
<p class="note">Tells you when this machine goes <em>silent</em> — a power cut or a crash,
which the machine itself cannot report. Create a free check at healthchecks.io and paste its
ping URL.</p>

<label for="tgt">Telegram bot token</label>
<input id="tgt" name="telegram_token" data-path="telegram.bot_token" autocomplete="off" spellcheck="false"
       placeholder="123456:ABC-DEF...">
<label for="tgc">Telegram chat ID</label>
<input id="tgc" name="telegram_chat" data-path="telegram.chat_id" autocomplete="off" spellcheck="false" placeholder="987654321">
<p class="note">Pushes alerts (node down, worker offline, sync finished) to Telegram and
answers status commands. Both fields are needed, or leave both blank.</p>

<label for="tz">Time zone</label>
<input id="tz" name="timezone" data-path="dashboard.timezone" value="auto" autocomplete="off" list="tzs">
<datalist id="tzs">
<option value="auto"><option value="UTC"><option value="America/New_York"><option value="America/Chicago">
<option value="America/Denver"><option value="America/Los_Angeles"><option value="America/Sao_Paulo">
<option value="Europe/London"><option value="Europe/Berlin"><option value="Europe/Warsaw">
<option value="Africa/Johannesburg"><option value="Asia/Dubai"><option value="Asia/Kolkata">
<option value="Asia/Singapore"><option value="Asia/Tokyo"><option value="Australia/Sydney">
</datalist>
<p class="note"><code>auto</code> uses this machine's own setting. For dashboard timestamps
and the daily summary — anything like <code>Europe/Berlin</code>.</p>

<details id="adv">
<summary><strong>Advanced</strong> — the exact configuration, every key and default</summary>
<p class="note">This is what the machine will run. Editing a field above updates it; editing it
here directly wins. Keys already at their documented default are not written to disk, so this
machine keeps receiving improved defaults from future updates — the effective configuration is
identical either way.</p>
<textarea id="cfg" name="config" rows="20" spellcheck="false"
  style="width:100%;font-family:ui-monospace,monospace;font-size:0.78rem;box-sizing:border-box"></textarea>
<p class="err" id="cfgerr"></p>
</details>

<button type="submit">Apply</button>
<p class="note">This machine validates and provisions itself. The dashboard login is generated
on the machine and shown on its console — it never travels over this page.</p>
</form>
<script>
const $ = (id) => document.getElementById(id);
const toggle = (el, on) => {{ el.style.display = on ? 'block' : 'none'; }};
const sync = () => {{
  const mlocal = $('mmode').value !== 'remote';
  toggle($('mlocal'), mlocal);          // chain size only matters for a node we run
  toggle($('mremote'), !mlocal);
  toggle($('tremote'), $('tmode').value === 'remote');
  toggle($('mrauth'), $('mra').checked);
}};
['mmode','tmode','mra'].forEach(id => $(id).addEventListener('change', sync));
window.syncBlocks = sync;
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
<p id="verdict" class="note"></p>
<label for="confirm">Type the disk name to confirm</label>
<input id="confirm" name="confirm" autocomplete="off" autocapitalize="off" spellcheck="false"
       placeholder="choose a disk above first">
<button type="submit">Erase and install</button>
<p class="note">Disks already holding a Pithead <code>data</code> partition are reinstalled in
place and keep their synced chain. Everything else is erased.</p>
</form>
<script>
// Restate the choice in full, below the control, where nothing is truncated and the text wraps.
document.getElementById('disk').addEventListener('change', e => {{
  const opt = e.target.selectedOptions[0];
  document.getElementById('confirm').placeholder = e.target.value;
  const d = document.getElementById('verdict');
  d.textContent = 'Installing to ' + e.target.value + ' — this ' + opt.dataset.verdict + '.';
  d.className = opt.dataset.verdict.startsWith('KEEPS') ? 'note' : 'err';
}});
</script>"""

INSTALLING = """<p><strong>Installing.</strong> Takes a few minutes. Do not power it off.</p>
<p class="note" id="s">Working…</p>
<div id="done" style="display:none">
<h2>Installed</h2>
<ol>
<li>Wait for the machine to switch itself off.</li>
<li>Remove the USB stick.</li>
<li>Switch it back on.</li>
</ol>
<p class="note">The setup page returns from the installed system, with a new token.</p>
</div>
<script>
const poll = setInterval(async () => {
  const t = await (await fetch('/status')).text();
  document.getElementById('s').textContent = t;
  if (t.indexOf('Installed') === 0) {
    clearInterval(poll);
    document.getElementById('s').style.display = 'none';
    document.getElementById('done').style.display = 'block';
  }
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


def _reference() -> dict:
    """Every key with its documented default, published into the spool by the host."""
    raw = _spool_read("config.reference.json")
    try:
        ref = json.loads(raw) if raw else {}
    except ValueError:
        ref = {}
    return {k: v for k, v in ref.items() if not k.startswith("_")}


def _deep_merge(base: dict, over: dict) -> dict:
    out = dict(base)
    for k, v in (over or {}).items():
        out[k] = _deep_merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def strip_defaults(cfg: dict, ref: dict) -> dict:
    """Drop every key whose value already equals the documented default.

    The page shows the FULL effective config, because hiding what a machine will run is how
    people get surprised. What gets written is only what actually differs — a config that
    pins all several hundred defaults at install time would freeze them forever, and an
    appliance receives improved defaults through OS updates. Same effective configuration,
    minus the freeze. Setting a value equal to today's default is therefore not a way to pin
    it; nothing in the product offers that, and the reference is the place to change one.
    """
    out: dict = {}
    for k, v in (cfg or {}).items():
        if k.startswith("_"):
            continue
        if isinstance(v, dict) and isinstance(ref.get(k), dict):
            sub = strip_defaults(v, ref[k])
            if sub:
                out[k] = sub
        elif k not in ref or v != ref[k]:
            out[k] = v
    return out


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
        # The consequence goes SECOND, right after the disk name. A <select> truncates on the
        # right, and bench testing showed the collapsed control cutting off exactly the words
        # that distinguish "keeps your 250 GB chain" from "erases everything" — the one part of
        # the line nobody may have to open a dropdown to read.
        verdict = {
            "pithead-with-data": "KEEPS existing data (reinstall)",
            "pithead": "ERASES it (Pithead layout, no data partition)",
        }.get(state, "ERASES everything on it")
        label = f"{name} — {verdict} — {size} {model} (SN {serial})"
        out.append(f'<option value="{name}" data-verdict="{verdict}">{label}</option>')
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
    err = f'<p class="err">{html.escape(prev)}</p>' if prev else ""
    # Defaults, with the last attempt merged over them: a rejected config comes back filled in
    # rather than making someone retype a 95-character address to fix one field.
    effective = _deep_merge(_reference(), _last_attempt())
    seed = (
        '<script type="application/json" id="cfg-seed">'
        + html.escape(json.dumps(effective))
        + "</script>"
    )
    body = SETUP_FORM.format(error=err) + seed + BIND_SCRIPT
    return web.Response(text=PAGE.format(body=body), content_type="text/html")


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

    # prune only means anything for a node we run. On remote, the key is noise at best and a
    # lie at worst — the chain lives on someone else's machine and its shape is not ours.
    if form.get("monero_mode") != "remote" and form.get("prune") == "false":
        cfg["monero"]["prune"] = False

    # Optional services: written ONLY when actually filled in. An empty ping_url or a
    # half-configured Telegram is worse than absent — one silently disables the dead-man's
    # switch the operator thinks they have, the other fails validation on a blank they never
    # meant to set.
    hc = s_("healthchecks_url")
    if hc:
        cfg["healthchecks"] = {"ping_url": hc}
    tg_token, tg_chat = s_("telegram_token"), s_("telegram_chat")
    if tg_token and tg_chat:
        cfg["telegram"] = {"enabled": True, "bot_token": tg_token, "chat_id": tg_chat}

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


def _last_attempt() -> dict:
    raw = _spool_read("last-attempt.json")
    try:
        return json.loads(raw) if raw else {}
    except ValueError:
        return {}


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
    raw = str(form.get("config", "")).strip()
    ref = _reference()
    # The JSON pane IS the configuration — the fields write into it, so what the operator can
    # see is exactly what gets applied. build_config remains the fallback for a browser with no
    # JavaScript, where the pane never populated.
    try:
        cfg = json.loads(raw) if raw else build_config(dict(form))
        if not isinstance(cfg, dict):
            raise ValueError("the top level must be a JSON object")
    except (ValueError, TypeError) as exc:
        err = f'<p class="err">Not valid JSON: {html.escape(str(exc))}</p>'
        effective = _deep_merge(ref, _last_attempt())
        seed = (
            '<script type="application/json" id="cfg-seed">'
            + html.escape(json.dumps(effective))
            + "</script>"
        )
        body = SETUP_FORM.format(error=err) + seed + BIND_SCRIPT
        return web.Response(text=PAGE.format(body=body), content_type="text/html", status=400)
    # Keep the full attempt for a retry, write only what differs from the defaults.
    _spool_write_text("last-attempt.json", json.dumps(cfg))
    _spool_write_config(strip_defaults(cfg, ref) if ref else cfg)
    return web.Response(text=PAGE.format(body=DONE), content_type="text/html")


async def status(request: web.Request) -> web.Response:
    if installer_mode():
        if _spool_read("installed") is not None:
            return web.Response(text="Installed — the machine is switching itself off.")
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

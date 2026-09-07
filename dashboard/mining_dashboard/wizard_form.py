"""The no-JavaScript fallback for the first-boot wizard's setup form (#77 phase 3).

Split out of ``wizard.py`` so that file has room to grow (#1318): it sits at its
``docs/dev/file-budget.tsv`` ceiling, and ceilings only ever go down. This was the largest
self-contained thing in it — a pure mapping from form fields to a pithead config, with no module
state, no spool access and no request handling — so moving it whole changes nothing about how it
is reached. ``wizard.py`` re-imports the name, so ``wizard.build_config`` still resolves both for
the tests and for the one call site in ``submit``.
"""


def build_config(form: dict) -> dict:
    """Form fields as a pithead config — the fallback for a client that never populated the
    JSON pane (no JavaScript: the harness's curl, a text browser). Mirrors the CLI wizard's
    question set; the host's parse_and_validate_config is the validator.

    Keys are omitted rather than written empty: an absent key inherits the documented default,
    while an empty string is a value and would override it."""

    def s_(name: str) -> str:
        return str(form.get(name, "")).strip()

    def port(name: str, fallback: int) -> int:
        raw = s_(name)
        return int(raw) if raw.isdigit() else fallback

    cfg: dict = {
        "monero": {"wallet_address": s_("monero_wallet")},
        "p2pool": {"pool": s_("pool") or "mini", "stratum_password": "auto"},
    }

    # Merge-mining Tari is opt-in, and "off" is what a new machine gets (#1855). The mode is
    # written EXPLICITLY on every submit, which is the one place this function departs from the
    # omit-and-inherit rule above, and it departs on purpose: a config with no tari.mode still
    # parses as "local", so omitting the key would quietly merge-mine on a machine whose
    # operator answered No. The default is only right for configs written before the question
    # existed; it is wrong for every answer this form collects.
    tari_mode = s_("tari_mode") or "off"
    cfg["tari"] = {"mode": tari_mode}
    if tari_mode != "off":
        # A machine that does not merge-mine has nowhere to be paid, so the key is omitted
        # rather than sent empty. When it DOES merge-mine, an empty value still flows through
        # so the HOST produces the rejection, as it does for the Monero address.
        cfg["tari"]["wallet_address"] = s_("tari_wallet")

    if form.get("monero_mode") == "remote":
        cfg["monero"]["mode"] = "remote"
        cfg["monero"]["remote"] = {
            "host": s_("monero_remote_host"),
            "rpc_port": port("monero_remote_rpc", 18081),
            "zmq_port": port("monero_remote_zmq", 18083),
        }
        if form.get("monero_remote_auth"):
            cfg["monero"]["node_username"] = s_("monero_remote_user")
            cfg["monero"]["node_password"] = s_("monero_remote_pass")

    if tari_mode == "remote":
        cfg["tari"]["remote"] = {
            "host": s_("tari_remote_host"),
            "grpc_port": port("tari_remote_grpc", 18142),
        }

    # prune only means anything for a node we run. On remote, the key is noise at best and a
    # lie at worst — the chain lives on someone else's machine and its shape is not ours.
    if form.get("monero_mode") != "remote" and form.get("prune") == "false":
        cfg["monero"]["prune"] = False

    # Optional services: written ONLY when actually filled in. An empty ping_url silently
    # disables the dead-man's switch the operator thinks they have; a half-configured
    # Telegram fails validation on a blank they never meant to set.
    hc = s_("healthchecks_url")
    if hc:
        cfg["healthchecks"] = {"ping_url": hc}
    tg_token, tg_chat = s_("telegram_token"), s_("telegram_chat")
    if tg_token and tg_chat:
        cfg["telegram"] = {"enabled": True, "bot_token": tg_token, "chat_id": tg_chat}

    if form.get("local_miner"):
        cfg["local_miner"] = {"enabled": True}

    # The raffle is opt-out: xvb.enabled is true in config.reference.json, so only the OFF
    # answer is worth writing. Writing True would pin a default the operator never chose to
    # pin, and pinning it is what makes a later change to the reference not reach this machine.
    if s_("xvb") == "false":
        cfg["xvb"] = {"enabled": False}

    if form.get("clearnet_sync") == "true":
        cfg["monero"]["clearnet_initial_sync"] = True
        cfg["tari"]["clearnet_initial_sync"] = True

    tz = s_("timezone")
    if tz and tz != "auto":  # auto IS the documented default — writing it would only pin it
        cfg.setdefault("dashboard", {})["timezone"] = tz

    return cfg

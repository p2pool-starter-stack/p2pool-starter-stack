# --- Dashboard control channel (#33) ---
# The dashboard container can only ASK: it drops typed JSON intents into $CONTROL_DIR/requests
# (its single writable spool mount). This host-side runner claims each request, validates it, and
# dispatches a FIXED set of actions, each a hardcoded host command the request's `action` string
# only SELECTS between — `apply --dry-run --porcelain` (preview), `apply -y` (commit), `upgrade`
# to the latest published release (#59, target re-derived host-side), `restart`/`apply` (the
# Telegram lifecycle verbs, #338), `worker-apply`/`worker-upgrade` (a rig's own control API,
# #185/#597), `backup` (an encrypted archive + one-time emergency kit, #908), the five staged
# appliance OS-update verbs `os-check`/`os-download`/`os-verify`/`os-install`/`os-reboot`
# (47-/48-os-update-*.sh), and the two read-only diagnostics verbs `diag-doctor`/`diag-logs`
# (#913/#943, 46a-control-diagnostics.sh). The dispatching `case` in 49-control-request-loop.sh
# is the list this sentence must match; check it there before trusting this one.
# Outcomes land in results/ and an audit line in audit/, both mounted read-only in the container —
# as is masked/, the pre-masked config copy the editor form prefills from (#440); the raw
# config.json is never mounted, so the container holds no secret it wasn't given.
# No string from the container is ever executed or interpolated into a command; the candidate
# config crosses the boundary only as a FILE handed to `apply` via PITHEAD_CONFIG_FILE.

# Approval gate for a commit (#33). The client-side typed-APPLY modal is NOT a security control:
# a compromised/XSS'd container writes the request spool directly and never renders that modal, so
# the only trustworthy gate is here, host-side. FAIL CLOSED, two independent checks:
#
#   1. TRUE DEFAULT-DENY: a commit that changes ANY env key NOT in
#      CONTROL_DASHBOARD_EDITABLE_KEYS — in EITHER direction (enable, change, or DISABLE) — is
#      refused. An allowlist, not a blocklist: a key added to render_env tomorrow is
#      un-committable from the dashboard until someone deliberately lists it here. Deliberately
#      decoupled from describe_change's cosmetic INFO/DEST flag: that flag labels only the
#      disruptive direction (enabling auth is DEST, disabling is INFO), so a compromised
#      container could otherwise switch security controls OFF with zero DEST rows.
#   2. Anything describe_change still flags DEST (pruning, data dirs, node-mode switch, ...) is
#      refused as disruptive, even for allowlisted keys.
#
# Both checks re-derive the changed keys from the staged config via the SAME dry-run path a preview
# runs — nothing is trusted from the container's request or its (host-written but container-visible)
# result file — so a forged "destructive:false" cannot slip a wallet swap or an auth-disable
# through. Out-of-band approval with deny-on-timeout is #338 (Telegram approve/deny) — it drops in
# here, replacing the refusal with a real second factor. Until then, these edits must be made from
# the host CLI. Echoes a reason on stdout when it refuses.

# The env keys committable from the dashboard: operational tuning only, and only keys whose value
# is derived from a validated enum, boolean, or number — never a free-form string that reaches a
# command line, URL, or credential. Everything else — wallets, auth, onion exposure, the control
# channel itself, Tor egress/clearnet toggles, binds, node RPC credentials, the XvB pool URL
# and donor id, tokens and passwords, the #381 payout-confirmation secrets (MONERO_VIEW_KEY,
# WALLET_RPC_PASSWORD) plus PAYOUT_CONFIRM_ENABLED, and their #462 Tari siblings (TARI_VIEW_KEY,
# TARI_WALLET_PASSWORD, TARI_SPEND_PUBLIC_KEY) plus TARI_PAYOUT_CONFIRM_ENABLED /
# TARI_WALLET_GRPC_ADDRESS / TARI_WALLET_SECRET_FILE — stays host-CLI-only. PAYOUT_SCAN_HEIGHT and
# TARI_WALLET_BIRTHDAY moved to the confirm-gated set below (2026-08 audit reclassification):
# they're wallet-creation metadata, not a secret, and a wrong value only re-scans from a different
# height on the wallet's NEXT creation — recoverable, not destructive.
# Each view key reveals every incoming payout amount/time, so it is never dashboard-committable
# (default-deny already refuses it; named here deliberately). The WALLET_CHANGED and
# CLEARNET_EXPOSED alert toggles are excluded on purpose: they are the tamper-evidence alarms on
# the Telegram channel (the future #338 approval channel), so the dashboard must not silence
# them. Space-separated exact env-key names.
#
# NOTE (2026-08 audit): TELEGRAM_EVENT_RAFFLE_WIN was missing from this list for a while — the one
# event toggle out of step with its 24 siblings, all otherwise editable. If you add a new event
# toggle, list it here AND in control_service.EDITABLE_ENV_KEY_PATHS (dashboard) — the drift
# guard only catches a mismatch between the two, not an omission from both.
CONTROL_DASHBOARD_EDITABLE_KEYS='P2POOL_FLAGS P2POOL_PORT
    XVB_ENABLED XVB_DONATION_LEVEL TARI_REQUIRED DASHBOARD_FAIL_CLOSED
    DASHBOARD_CHECK_UPDATES DASHBOARD_TZ
    MONERO_MEM_LIMIT TARI_MEM_LIMIT MONERO_PREP_THREADS
    HASHRATE_DROP_THRESHOLD_PCT HASHRATE_DROP_MINUTES TELEGRAM_DAILY_SUMMARY_TIME
    TELEGRAM_EVENT_NODE_DOWN TELEGRAM_EVENT_NODE_RECOVERED
    TELEGRAM_EVENT_WORKER_OFFLINE TELEGRAM_EVENT_WORKER_RECOVERED
    TELEGRAM_EVENT_WORKER_JOINED TELEGRAM_EVENT_WORKER_LEFT
    TELEGRAM_EVENT_SYNC_FINISHED TELEGRAM_EVENT_DISK_SPACE
    TELEGRAM_EVENT_DB_UNHEALTHY TELEGRAM_EVENT_DB_RESET TELEGRAM_EVENT_XVB_NO_SHARE
    TELEGRAM_EVENT_XVB_REGISTRATION TELEGRAM_EVENT_NEW_RELEASE
    TELEGRAM_EVENT_STACK_ONLINE TELEGRAM_EVENT_DAILY_SUMMARY
    TELEGRAM_EVENT_HASHRATE_LOW TELEGRAM_EVENT_HASHRATE_LOSS
    TELEGRAM_EVENT_HUGEPAGES TELEGRAM_EVENT_LOW_RAM
    TELEGRAM_EVENT_HIGH_REJECT_RATE TELEGRAM_EVENT_BLOCK_FOUND
    TELEGRAM_EVENT_PAYOUT_FOUND TELEGRAM_EVENT_PAYOUT_CONFIRMED TELEGRAM_EVENT_CONTAINER_UNHEALTHY
    TELEGRAM_EVENT_RAFFLE_WIN'

# The confirm-gated editable set (#719): operationally-disruptive env keys the dashboard MAY commit
# behind a type-to-confirm — NOT the security perimeter (wallets, keys, credentials, onion,
# tor_egress_firewall, dashboard.control.enabled, stratum password, per-rig hosts/tokens all stay
# host-only DEST). Type-to-confirm is UX FRICTION, not a security control: a compromised dashboard
# that can set a field can also fill the confirm box, so this set is strictly the "expensive but
# recoverable, not a breach" class — a data-dir move (re-sync), a stratum-port repoint (rigs
# reconnect), a clearnet-sync enable (host IP exposed during IBD, auto-reverts), a prune enable
# (reclaims disk), or a Tor-load repoint (MONERO_OUT_PEERS: bounded 8-1024 at validation and
# instantly reversible, but the biggest steady-state knob on the shared Tor daemon's CPU — 2026-08
# security review placed it here, not free-commit). The same review REVERTED three keys the
# configurability audit had proposed: PROXY_DONATE_LEVEL (docs/privacy.md's own words — donate
# traffic bypasses the Tor socks5, and a self-approving container could divert up to 99% of
# revenue silently), and PAYOUT_SCAN_HEIGHT / TARI_WALLET_BIRTHDAY (a future-dated value lands at
# the NEXT wallet creation and silently defeats the payout-confirmation tamper evidence — not the
# recoverable class this tier is for). All three stay host-only. describe_change flags
# each CONFIRM only in its in-scope DIRECTION — the flag carries the direction (prune DISABLE, TOR
# data-dir move, etc. still emit DEST and stay refused); this list is the static allowlist the
# gate's default-deny pass consults and the UI mirrors (control_service.CONFIRM_ENV_KEY_PATHS,
# drift-guarded like CONTROL_DASHBOARD_EDITABLE_KEYS).
# The four node-endpoint keys (#1888) are the 2026-09 addition, on the operator's ruling, and they
# are the reason to read this tier's boundary carefully rather than by analogy. They are NOT a
# data-dir move: repointing monerod's or the Tari base node's address moves TRUST, not disk — the
# stack believes the chain data, block templates and share heights whatever answers there. They are
# not free-commit either, for exactly that reason. They sit here because the change is INSTANTLY
# REVERSIBLE by the same route (type APPLY, put the old address back) and because it is the one
# perimeter entry an appliance operator must be able to make: there is no host shell on an
# appliance, so "edit config.json and run apply" is not a remedy, it is a dead end (#786/#1821).
# The compensating control is not the typed token — that is friction, as this comment says above —
# it is the host-side REACHABILITY PROBE the approval gate runs on the STAGED endpoint before it
# accepts one (43-control-approval-and-preview.sh, #1889's preflight_remote_nodes): a dashboard
# cannot silently park a chain on a node that is not there. The RPC LOGIN CREDENTIALS for a remote
# node (MONERO_NODE_USERNAME / MONERO_NODE_PASSWORD) are deliberately NOT here — those are secrets,
# not address identity, and they stay host-only DEST with the rest of the credentials above.
CONTROL_DASHBOARD_CONFIRM_KEYS='MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR DASHBOARD_DATA_DIR
    STRATUM_PORT MONERO_CLEARNET_SYNC TARI_CLEARNET_SYNC MONERO_PRUNE
    MONERO_OUT_PEERS
    MONERO_NODE_HOST MONERO_RPC_PORT MONERO_ZMQ_PORT TARI_GRPC_ADDRESS'

# The node-endpoint subset of the confirm set, named ONCE (#1888) so the approval gate's probe
# trigger is not a fourth hand-kept copy of these key names. Every key here must also be in
# CONTROL_DASHBOARD_CONFIRM_KEYS above — a key here but not there is unreachable; a node key there
# but not here would be committable with NO reachability probe, which is the failure that matters.
CONTROL_NODE_ENDPOINT_KEYS='MONERO_NODE_HOST MONERO_RPC_PORT MONERO_ZMQ_PORT TARI_GRPC_ADDRESS'

# True if $1 is EXACTLY a canonical dotted-decimal IPv4 literal — four decimal octets 0-255, none
# with a leading zero (a bare "0" is fine; "010"/"0177" are not). curl/glibc's numeric-address
# parsing also accepts a bare decimal integer ("2130706433"), octal per-octet ("0177.0.0.1", AND
# bash's own arithmetic tests would misread "010" as octal 8), hex ("0x7f000001"), and
# short/collapsed forms ("127.1" == 127.0.0.1) — none of those are "canonical" by this definition,
# on purpose. Used two ways below: to fast-path an already-clean literal straight to a
# classification with no resolver round trip, and to recognize a RESOLVED answer's own shape
# (getent's output is always canonical, so this always matches there).
_is_canonical_ipv4() {
    [[ "$1" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
    return 0
}

# True if a CANONICAL IPv4 address (already _is_canonical_ipv4-shaped) is inside this host's own
# reach: loopback/this-network (0.x/127.x — all of 127.0.0.0/8, not just 127.0.0.1, so a box's own
# non-default loopback alias is caught too), link-local (169.254.0.0/16, which also covers the
# 169.254.169.254 cloud-metadata address), multicast/reserved (224-255), or the stack's own
# docker-bridge /24 (network.subnet, read from the LIVE config — a same-commit network.subnet
# change is refused elsewhere, on neither editable allowlist, so the live value is the honest
# baseline either way). RFC1918 LAN ranges (10/8, 172.16/12, 192.168/16) are deliberately NOT on
# this list — dialing a LAN rig is this feature's whole purpose.
_ipv4_is_sensitive() {
    local a b prefix
    IFS=. read -r a b _ _ <<<"$1"
    case "$a" in
    0 | 127) return 0 ;;
    169) [ "$b" = 254 ] && return 0 ;;
    esac
    [ "$a" -ge 224 ] && return 0
    prefix=$(jq -r '.network.subnet // "172.28.0.0/24"' "$CONFIG_FILE" 2>/dev/null)
    case "$prefix" in
    *.0/24) prefix="${prefix%.0/24}" ;;
    *) prefix="172.28.0" ;;
    esac
    [ "${1%.*}" = "$prefix" ]
}

# True if $1 is shaped like an IPv6 literal — loose on purpose (a bare colon check): this only
# routes the value to the right classifier below, it doesn't itself decide safety.
_is_ipv6_literal() {
    case "$1" in
    *:*) return 0 ;;
    esac
    return 1
}

# True if an IPv6 literal is inside this host's own reach: loopback (::1), unspecified (::),
# link-local (fe80::/10 — the fixed first 10 bits always print as "fe8"/"fe9"/"fea"/"feb" in
# RFC 5952's canonical form, since none of those leading hex digits is ever zero-suppressed),
# multicast (ff00::/8 — this is what actually closes the /etc/hosts multicast aliases
# ip6-allnodes/ip6-allrouters/ip6-localnet/ip6-mcastprefix; a spelling denylist could only ever
# cover the aliases someone thought to type in, never the address CLASS), or an IPv4-mapped IPv6
# literal (::ffff:a.b.c.d) whose EMBEDDED v4 address is itself sensitive — curl dials the
# embedded address, so the v6 wrapper syntax must not launder it.
_ipv6_is_sensitive() {
    local v6
    v6=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    v6="${v6%%%*}" # strip a zone ID (fe80::1%eth0) — irrelevant to which block it's in
    case "$v6" in
    "::1" | "::") return 0 ;;
    fe8[0-9a-f]:* | fe9[0-9a-f]:* | fea[0-9a-f]:* | feb[0-9a-f]:*) return 0 ;;
    ff[0-9a-f][0-9a-f]:*) return 0 ;;
    ::ffff:*.*.*.*)
        _is_canonical_ipv4 "${v6##*:}" && _ipv4_is_sensitive "${v6##*:}" && return 0
        ;;
    esac
    return 1
}

# Resolves $1 to its numeric addresses (both A and AAAA) via the system resolver — once, at
# commit time; this write path is operator-confirmed, never a hot loop, so a real DNS round trip
# here is the right cost for the safety it buys. `getent ahosts` also resolves any numeric-address
# ATTEMPT that isn't the exact canonical form (decimal integer, octal, hex, short/collapsed —
# _is_canonical_ipv4's own comment) using the SAME numeric parsing glibc's getaddrinfo (and
# therefore curl) uses, so routing those through here too gets an exact answer instead of a
# guess. Prints one deduplicated IP per line; a non-zero exit (including a 5s timeout) means
# resolution failed, which the caller treats as FAIL CLOSED — an unresolved name can never be
# proven safe. This is the one seam a test replaces: point $PATH at a directory carrying a fake
# `getent` ahead of the real one (see tests/stack/test-control-add-only-ssrf.sh) to supply canned
# answers without needing real DNS.
_resolve_host_ips() {
    timeout 5 getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

# True if $1 — a workers.list[] host the add-only exception is about to let a commit introduce —
# resolves inside THIS host's own reach. Mirrors the READ-path SSRF guard a miner-claimed IP
# already gets (_safe_probe_host, dashboard/mining_dashboard/client/xmrig_client.py, #122) for the
# WRITE path: an add-only append is DASHBOARD-chosen (the operator confirms it in the browser, but
# the actual HTTP request is built and sent by the — possibly compromised — dashboard container),
# so without this a malicious/compromised dashboard could append a phantom descriptor pointed at
# its own host's loopback services or a sibling container, then immediately dial it (with an
# attacker-chosen bearer) via the pre-existing worker-apply/worker-upgrade path, which resolves and
# dials strictly from the HOST's own config. An ordinary LAN or public rig address is unaffected.
#
# #893 round 5: an earlier version of this function classified by STRING SHAPE alone — a denylist
# of "localhost" and its known /etc/hosts aliases. An independent review found that a spelling
# denylist can never answer "does this name reach my own loopback": this host's own Debian
# self-entry (e.g. a box named "gouda" resolving to 127.0.1.1 — every Debian install's own
# /etc/hosts gives its hostname a loopback entry) and, worse, ANY attacker-controlled DNS name
# pointed at 127.0.0.1 both looked like "a genuine hostname, therefore safe" to a string
# classifier — but a live curl dial to either one lands on loopback all the same. There is no
# spelling to denylist against an attacker who controls the DNS answer.
#
# The fix is RESOLVE, THEN CHECK: a canonical IPv4 literal (the exact form _is_canonical_ipv4
# recognizes) is classified directly, since it already IS the address that would be dialed and
# has exactly one meaning. Everything else — including an IPv6 literal, which unlike IPv4 has
# many equally-valid spellings of the same address ("::1" == "0:0:0:0:0:0:0:1") that a hand-rolled
# shortcut classifier could under-recognize the same way the old denylist did — goes through the
# resolver, which normalizes any of those the same way glibc's own numeric-address parsing would.
# EVERY returned address must clear the check — an attacker's own DNS answer can mix one public IP
# with one loopback IP in the same response, so checking only the first would miss it.
# DNS-rebinding (the resolved-at-commit
# address differing from the address at a later dial) is an accepted residual risk, same as
# before resolve-and-check existed: it requires a SEPARATE capability (DNS control) beyond a
# compromised dashboard, and the operator-confirmed write boundary this whole check lives behind
# is why that's acceptable without also adding a dial-time re-check (see the PR's "Dial-time
# re-check" note).
_control_host_is_internal() {
    local host resolved ip
    host=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    host="${host%.}" # a trailing dot is DNS's "FQDN root" marker; getent treats it identically
    if _is_canonical_ipv4 "$host"; then
        # A canonical dotted-decimal literal is unambiguous — it IS the address that would be
        # dialed, so classify it directly with no resolver round trip.
        _ipv4_is_sensitive "$host"
        return
    fi
    # Everything else — a genuine hostname, an IPv6 literal in ANY of its many equally-valid
    # spellings ("::1" and "0:0:0:0:0:0:0:1" are the identical address; a hand-rolled
    # canonicalizer here would just reopen the same bug class this fix closed for IPv4 — a
    # classifier that only recognizes ONE shape and silently treats every other shape as safe), or
    # an IPv4-shaped-but-non-canonical numeric-address ATTEMPT (decimal integer, octal, hex,
    # short/collapsed form) — goes through the resolver. `getent ahosts` normalizes ALL of those
    # into canonical addresses using the SAME parsing glibc's getaddrinfo (and therefore curl)
    # uses, including a bare literal (no network round trip needed for one), so this is correct
    # for a typed literal and a real hostname alike.
    resolved=$(_resolve_host_ips "$host") || return 0 # resolution failed/timed out -> FAIL CLOSED
    [ -n "$resolved" ] || return 0                    # an empty answer -> FAIL CLOSED
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        if _is_canonical_ipv4 "$ip"; then
            _ipv4_is_sensitive "$ip" && return 0
        elif _is_ipv6_literal "$ip"; then
            _ipv6_is_sensitive "$ip" && return 0
        else
            return 0 # an answer shape we don't recognize -> FAIL CLOSED, never wave it through
        fi
    done <<<"$resolved"
    return 1
}

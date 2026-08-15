#!/usr/bin/env bash
# tests/os/hw-battery.sh — the real, physical appliance release gate (#1022).
#
# The KVM battery (tests/os/run.sh) cannot see real firmware, a real NIC, a real watchdog device,
# or real cpufreq — and docs/dev/appliance-release.md's manual M1-M10 battery that was supposed to
# cover that gap has never actually been run. This script is the automated slice of that battery:
# it drives the REAL appliance over ssh, takes the bench reservation itself, runs the two fully
# automatable release-gate items (M7, M9) by calling `pithead os-update` and letting the box's own
# boot-time health gate decide (never reimplementing that decision), runs real-hardware-only
# assertions the KVM guest cannot make, and for the remaining physical items (M1/M4/M8/M10) prints
# exactly what the operator must do and records their explicit, timestamped attestation — it never
# marks a physical item passed on its own, and never silently skips one.
#
#   tests/os/hw-battery.sh --host root@ADDR [--identity KEYFILE] [--dir /data/pithead]
#                          [--out-dir DIR] [--non-interactive]
#
# Run from the repo root, on the bench coordinator (the same host tests/os/run.sh runs from —
# it needs docker + rauc locally to build the update bundles this battery installs).
#
# Reservation: takes the appliance bench lock (tests/os/bench-lock.sh) EXCLUSIVE before touching
# anything and holds it for the whole run — see docs/dev/release-server.md's "Appliance bench
# reservation" section for why the lock lives on the coordinator rather than the appliance, and
# for the box contract (what M7/M9 are free to destroy, and what must never be touched: /data,
# which on the real box holds a ~100+ GB synced Monero chain).
#
# A failed assertion is recorded and the run continues, so one pass over the box collects the
# whole battery; the run exits non-zero if anything failed OR a physical item was not attested.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=tests/os/bench-lock.sh
source "$HERE/bench-lock.sh"

PASS=0
FAIL=0
RESULT_LOG=""
ok() {
    PASS=$((PASS + 1))
    printf '  \033[1;32m✓\033[0m %s\n' "$1"
    RESULT_LOG="${RESULT_LOG}PASS: ${1}"$'\n'
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  \033[1;31m✗\033[0m %s\n      %s\n' "$1" "${2:-}"
    RESULT_LOG="${RESULT_LOG}FAIL: ${1} -- ${2:-}"$'\n'
}
info() {
    printf '\033[1;34m==>\033[0m %s\n' "$1"
    RESULT_LOG="${RESULT_LOG}INFO: ${1}"$'\n'
}
have() { command -v "$1" >/dev/null 2>&1; }

HOST=""
IDENTITY="$HOME/.ssh/id_ed25519"
REMOTE_DIR="/data/pithead"
OUT_DIR="$HERE/results"
NONINTERACTIVE=0
SSH_TIMEOUT="${SSH_TIMEOUT:-8}"
ATTESTATIONS=""

usage() {
    cat <<'EOF'
tests/os/hw-battery.sh — the real-appliance release-gate battery.

USAGE:
  tests/os/hw-battery.sh --host <user@address> [options]

CONNECTION:
  --host <user@host>     ssh destination of the physical appliance (required)
  --identity <keyfile>   ssh private key (default: ~/.ssh/id_ed25519). Its .pub is baked into
                         every test bundle this run builds (M7/M9), so the box stays reachable
                         with the SAME key afterwards.
  --dir <path>           the pithead stack directory ON THE BOX (default: /data/pithead)

OUTPUT:
  --out-dir <path>       where the dated result file is written (default: tests/os/results)
  --non-interactive      never prompt for the physical-item (M1/M4/M8/M10) attestations — each is
                         recorded NOT ATTESTED instead of being silently skipped or assumed passed

Takes the appliance bench reservation EXCLUSIVE before touching anything (see
docs/dev/release-server.md) and holds it for the whole run.
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --host)
            HOST="$2"
            shift 2
            ;;
        --identity)
            IDENTITY="$2"
            shift 2
            ;;
        --dir)
            REMOTE_DIR="$2"
            shift 2
            ;;
        --out-dir)
            OUT_DIR="$2"
            shift 2
            ;;
        --non-interactive)
            NONINTERACTIVE=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1 (see --help)" >&2
            exit 2
            ;;
        esac
    done
}

# --- ssh -----------------------------------------------------------------------------------
_ssh() {
    ssh -i "$IDENTITY" -o BatchMode=yes -o ConnectTimeout="${SSH_TIMEOUT:-8}" \
        -o StrictHostKeyChecking=accept-new "$HOST" "$@" 2>/dev/null
}
_wait_ssh() { # $1 seconds — the definition of "not bricked"
    local deadline=$(($(date +%s) + $1))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        _ssh true && return 0
        sleep 5
    done
    return 1
}
_marker() { _ssh cat /etc/pithead-test-marker 2>/dev/null | tr -d '\r\n'; }

# --- pure: the address classifier (#1021 class) ---------------------------------------------
# classify_ipv4_address <addr> — pure. "private": RFC1918 (10/8, 172.16/12, 192.168/16), loopback
# (127/8), link-local (169.254/16). "global": any other four-octet address (fail closed — a
# genuine IPv4 not in a known-private range is treated as world-addressable). "other": does not
# even parse as four 0-255 octets (e.g. a hostname).
classify_ipv4_address() {
    local a="$1" o1 o2 o3 o4 o
    # Anchored, exactly four dot-separated groups — simpler and more obviously correct than
    # splitting by hand, and it rejects "1.2.3" / "1.2.3.4.5" / a leading or trailing dot outright
    # (bash's [[ =~ ]] + BASH_REMATCH is available since bash 3.0, so this stays portable).
    if [[ "$a" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        o1="${BASH_REMATCH[1]}"
        o2="${BASH_REMATCH[2]}"
        o3="${BASH_REMATCH[3]}"
        o4="${BASH_REMATCH[4]}"
    else
        printf 'other'
        return
    fi
    for o in "$o1" "$o2" "$o3" "$o4"; do
        case "$o" in
        0?*)
            # A leading zero ("08"): not a normal dotted-quad octet, and bash's -le would
            # otherwise reinterpret it as (invalid) octal. Reject rather than guess.
            printf 'other'
            return
            ;;
        esac
        [ "$o" -le 255 ] || {
            printf 'other'
            return
        }
    done
    if [ "$o1" -eq 10 ]; then
        printf 'private'
    elif [ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; then
        printf 'private'
    elif [ "$o1" -eq 192 ] && [ "$o2" -eq 168 ]; then
        printf 'private'
    elif [ "$o1" -eq 127 ]; then
        printf 'private'
    elif [ "$o1" -eq 169 ] && [ "$o2" -eq 254 ]; then
        printf 'private'
    else
        printf 'global'
    fi
}

# classify_ipv6_address <addr> — pure. "private": loopback ::1, link-local fe80::/10, ULA
# fc00::/7. "global": 2000::/3 (the exact #1021 class — an ISP-assigned globally-routable
# address) and every other/unrecognized first group — fail closed, same rule as the IPv4 side.
# "other": the leading group is not plain hex (not an address at all).
classify_ipv6_address() {
    local a="$1" first dec
    [ "$a" != "::1" ] || {
        printf 'private'
        return
    }
    first="${a%%:*}"
    # Case-insensitive by widening the class (not by lowercasing $a): ${var,,} needs bash 4+, and
    # a macOS dev box's system bash is 3.2 — same portability reasoning as rig_lock's own
    # "GNU-only date -Iseconds errors on BSD/macOS" note (tests/integration/lib.sh).
    case "$first" in
    '' | *[!0-9a-fA-F]*)
        printf 'other'
        return
        ;;
    esac
    dec=$((16#$first))
    if [ "$dec" -ge $((16#fe80)) ] && [ "$dec" -le $((16#febf)) ]; then
        printf 'private' # link-local fe80::/10
    elif [ "$dec" -ge $((16#fc00)) ] && [ "$dec" -le $((16#fdff)) ]; then
        printf 'private' # ULA fc00::/7
    else
        printf 'global' # covers 2000::/3 and every unrecognized case
    fi
}

# classify_address <addr> — pure. Dispatches on ':' to the v4/v6 classifiers above; short-circuits
# the wildcard/any-address sentinels a listening-socket scan can produce ("0.0.0.0", "*", "::",
# "[::]") to "other" — a bind address, not a specific host to judge.
classify_address() {
    case "$1" in
    '' | '*' | 0.0.0.0 | '::' | '[::]')
        printf 'other'
        return
        ;;
    esac
    case "$1" in
    *:*) classify_ipv6_address "$1" ;;
    *) classify_ipv4_address "$1" ;;
    esac
}

# extract_addresses_from_caddy_site_line <line> — pure. generate_caddyfile's site-address line
# looks like `https://pithead.local, https://192.168.1.202, https://2605:…, https://localhost {`
# (Caddyfile syntax: addresses and the opening brace share the first line). Strips the scheme
# prefix and lets `read`'s own word-splitting drop surrounding commas/whitespace/the trailing
# brace; prints one candidate token per line. Hostnames (pithead.local, localhost) pass through
# unchanged — classify_address buckets them "other", which is correct: this only tokenizes, it
# does not judge. Known limitation: a custom dashboard.host port suffix (host:PORT) is not
# stripped — out of scope for the #1021 class this exists to catch (see docs/dev/release-server.md).
extract_addresses_from_caddy_site_line() {
    # The trailing \n matters: without it the last comma-split segment reaches `while read` with
    # no terminating newline, `read` returns 1 on that final line, and the loop body silently
    # never runs for it — the last address in the list would vanish.
    printf '%s\n' "$1" | tr ',' '\n' | while IFS=$' \t' read -r tok _; do
        tok="${tok#http://}"
        tok="${tok#https://}"
        [ -n "$tok" ] && printf '%s\n' "$tok"
    done
}

# _egress_verdict <output> — pure. A deliberate, small, standalone copy of tests/integration/
# lib.sh's egress_verdict (same three-way classification of bench-verify-egress.sh's output) —
# not sourced from there because that file also defines it_pass/it_fail-shaped globals that would
# collide with this harness's own ok/bad (tests/os/run.sh's idiom, not tests/integration's).
_egress_verdict() {
    case "$1" in
    *"[verify-egress] OK"*) printf 'ok' ;;
    *LEAK* | *✗*) printf 'leak' ;;
    *) printf 'inconclusive' ;;
    esac
}

# --- build the update bundles (M7/M9) ----------------------------------------------------------
# _build_bundle <marker> — mirrors tests/os/run.sh's own _build_bundle verbatim in spirit: the
# same product build pipeline (os/build-image.sh -> os/rauc/mkbundle.sh --dev), no reimplementation
# of the update mechanism. The one difference is deliberate: it bakes THIS run's own --identity
# key rather than a throwaway, so the box stays reachable with the same key that is already
# driving it, instead of risking the "gained/lost SSH" transition os_update_needs_confirmation
# warns about.
_build_bundle() {
    local marker="$1"
    (
        cd "$ROOT" || exit 1
        PITHEAD_UPDATER=rauc PITHEAD_TEST_SSH_PUBKEY="$(cat "${IDENTITY}.pub")" PITHEAD_TEST_MARKER="$marker" \
            os/build-image.sh
    ) >/tmp/hw-battery-build.log 2>&1 || return 1
    (cd "$ROOT" && os/rauc/mkbundle.sh --dev) >>/tmp/hw-battery-build.log 2>&1 || return 1
    find "$ROOT/os/rauc/build" -name '*.raucb' | head -1
}

# _build_broken_bundle <marker> — a validly-signed bundle whose payload cannot pass the boot-time
# health gate: p2pool's baked image reference is pointed at a tag nothing will ever load, so the
# container can never start and pithead doctor's check_revenue_containers correctly refuses to
# commit the slot. The edit is confined to THIS ONE SLOT's rootfs (baked at build time, restored
# in the working tree immediately after) — /data, the chain, and the wallets are never touched, so
# rolling back costs nothing.
# ponytail: mutate-and-restore the tracked compose file for one build rather than adding a new
# "break service X" build-time hook to os/build-image.sh. A crash between the sed and the restore
# (e.g. Ctrl-C mid-build) would leave docker-compose.yml modified in the working tree — a tracked
# file, recovered with `git checkout docker-compose.yml`, never data loss. Promote to a real build
# flag if another caller ever needs this.
_build_broken_bundle() {
    local marker="$1" compose="$ROOT/docker-compose.yml" backup rc=0 bundle=""
    backup="$(mktemp)"
    cp "$compose" "$backup"
    sed -i.bak 's/pithead-p2pool:\${STACK_VERSION:-dev}/\&-hw-battery-broken/' "$compose"
    rm -f "$compose.bak"
    if grep -q 'pithead-p2pool:\${STACK_VERSION:-dev}-hw-battery-broken' "$compose"; then
        bundle="$(_build_bundle "$marker")" || rc=$?
    else
        echo "could not locate the p2pool image line to break — refusing to build a bundle that would not actually be broken" >>/tmp/hw-battery-build.log
        rc=1
    fi
    cp "$backup" "$compose"
    rm -f "$backup"
    [ "$rc" -eq 0 ] && [ -n "$bundle" ] && printf '%s' "$bundle"
    return "$rc"
}

_stage_bundle() { # $1 bundle path -> a fixed, predictable path on the box
    scp -i "$IDENTITY" -o BatchMode=yes -o ConnectTimeout="${SSH_TIMEOUT:-8}" \
        -o StrictHostKeyChecking=accept-new -q "$1" "$HOST:/data/hw-battery-update.bundle"
}

# --- M7 — real update: build v+1, install, reboot, self-commit -----------------------------
run_m7() {
    info "M7 — real update: build v+1, pithead os-update, reboot, self-commit"
    local marker_before id_before hostkey_before
    marker_before="$(_marker)"
    [ -n "$marker_before" ] || {
        bad "M7 pre-check" "could not read the running slot's marker over ssh"
        return
    }
    id_before="$(_ssh cat /etc/machine-id)"
    hostkey_before="$(_ssh "ssh-keygen -lf /data/ssh/ssh_host_ed25519_key 2>/dev/null" | awk '{print $2}')"

    local next_marker bundle
    next_marker="hw-m7-$(date -u +%s)"
    bundle="$(_build_bundle "$next_marker")" || {
        bad "M7 build" "bundle build failed — see /tmp/hw-battery-build.log"
        return
    }
    ok "M7 built an update bundle for marker $next_marker ($(basename "$bundle"))"

    _stage_bundle "$bundle" || {
        bad "M7 stage" "scp to the box failed"
        return
    }
    if ! _ssh "cd $REMOTE_DIR && PITHEAD_ENGINE=podman ./pithead os-update /data/hw-battery-update.bundle -y" \
        >/tmp/hw-battery-osupdate-m7.log 2>&1; then
        bad "M7 install" "pithead os-update refused or failed — see /tmp/hw-battery-osupdate-m7.log"
        return
    fi
    ok "M7 pithead os-update installed the bundle"

    _ssh reboot >/dev/null 2>&1 || true
    sleep 10
    _wait_ssh 420 || {
        bad "M7 reboot" "box never came back after installing v+1"
        return
    }
    local marker_after
    marker_after="$(_marker)"
    if [ "$marker_after" = "$next_marker" ]; then
        ok "M7 booted the new build ($next_marker)"
    else
        bad "M7 booted the new build" "expected marker $next_marker, got '${marker_after:-none}'"
        return
    fi

    # Self-commit: reboot AGAIN with no explicit commit anywhere in this script. A REAL box gives
    # an uncommitted slot exactly one boot before falling back on the next attempt (the same shape
    # tests/os/run.sh's KVM update phase proves) — so staying on next_marker here is the box's OWN
    # pithead-boot health gate having committed it, never this harness deciding.
    _ssh reboot >/dev/null 2>&1 || true
    sleep 10
    _wait_ssh 420 || {
        bad "M7 second reboot" "box never came back"
        return
    }
    marker_after="$(_marker)"
    if [ "$marker_after" = "$next_marker" ]; then
        ok "M7 COMMIT: the health gate self-committed — still on $next_marker after a second reboot"
    else
        bad "M7 commit" "fell back to '${marker_after:-none}' on the second reboot — the new build never self-committed"
    fi

    # Identity survival across the A/B update: machine-id and the ssh host key live on /data,
    # untouched by a slot swap.
    local id_after hostkey_after
    id_after="$(_ssh cat /etc/machine-id)"
    hostkey_after="$(_ssh "ssh-keygen -lf /data/ssh/ssh_host_ed25519_key 2>/dev/null" | awk '{print $2}')"
    if [ -n "$id_before" ] && [ "$id_before" = "$id_after" ]; then
        ok "identity: machine-id survived the update ($id_before)"
    else
        bad "identity: machine-id survived the update" "before='${id_before:-none}' after='${id_after:-none}'"
    fi
    if [ -n "$hostkey_before" ] && [ "$hostkey_before" = "$hostkey_after" ]; then
        ok "identity: SSH host-key fingerprint survived the update ($hostkey_before)"
    else
        bad "identity: SSH host-key fingerprint survived the update" "before='${hostkey_before:-none}' after='${hostkey_after:-none}'"
    fi
}

# --- M9 — bad release: refused/rolled back, unaided -----------------------------------------
run_m9() {
    info "M9 — bad release: a deliberately broken bundle must be refused/rolled back, unaided"
    local marker_before
    marker_before="$(_marker)"
    [ -n "$marker_before" ] || {
        bad "M9 pre-check" "could not read the running slot's marker over ssh"
        return
    }

    local broken_marker bundle
    broken_marker="hw-m9-$(date -u +%s)"
    bundle="$(_build_broken_bundle "$broken_marker")" || {
        bad "M9 build" "broken bundle build failed — see /tmp/hw-battery-build.log"
        return
    }
    ok "M9 built a bundle with p2pool unable to start ($broken_marker)"

    _stage_bundle "$bundle" || {
        bad "M9 stage" "scp to the box failed"
        return
    }
    if ! _ssh "cd $REMOTE_DIR && PITHEAD_ENGINE=podman ./pithead os-update /data/hw-battery-update.bundle -y" \
        >/tmp/hw-battery-osupdate-m9.log 2>&1; then
        bad "M9 install" "pithead os-update refused the bundle before it ever booted — see /tmp/hw-battery-osupdate-m9.log"
        return
    fi
    _ssh reboot >/dev/null 2>&1 || true
    sleep 10
    if ! _wait_ssh 420; then
        bad "M9 BRICKED" "the box never came back after booting the deliberately broken bundle — disqualifying"
        return
    fi
    local marker_after
    marker_after="$(_marker)"
    if [ "$marker_after" = "$broken_marker" ]; then
        ok "M9 booted the broken build once, uncommitted (expected)"
    else
        info "M9 box answered ssh with marker '${marker_after:-none}' (expected the broken build's first boot)"
    fi

    # Nobody calls mark-good here: p2pool cannot start, so the box's OWN doctor gate refuses to
    # commit. This second reboot stands in for whatever next boot the box would eventually get on
    # its own (a power blip, a schedule) — the same shape the M7 self-commit check proves, in the
    # other direction.
    _ssh reboot >/dev/null 2>&1 || true
    sleep 10
    _wait_ssh 420 || {
        bad "M9 BRICKED" "no boot after the fallback reboot — disqualifying"
        return
    }
    marker_after="$(_marker)"
    if [ "$marker_after" = "$marker_before" ]; then
        ok "M9 ROLLED BACK: the broken build was refused — back on the previous build ($marker_before), unaided"
    else
        bad "M9 rollback" "expected the previous build ($marker_before) after the failed health check, got '${marker_after:-none}' — the broken build was not refused"
    fi
}

# --- real-hardware-only assertions -----------------------------------------------------------
run_no_global_address() {
    info "real-hardware-only — no globally-routable address is served"
    local ifaces bad_ifaces="" a
    ifaces="$(_ssh "hostname -I" 2>/dev/null)"
    if [ -z "$ifaces" ]; then
        bad "no-global-address: hostname -I" "empty or unreachable"
    else
        for a in $ifaces; do
            [ "$(classify_address "$a")" = "global" ] && bad_ifaces="${bad_ifaces:+$bad_ifaces }$a"
        done
        if [ -n "$bad_ifaces" ]; then
            info "interface carries a globally-routable address: $bad_ifaces (a router handing out public IPv6 — the condition that lets an unfiltered site list become internet-reachable)"
        else
            ok "no globally-routable address on any interface (hostname -I is all-private)"
        fi
    fi

    local caddyfile site_line bad_sites="" tok
    caddyfile="$(_ssh "cat $REMOTE_DIR/Caddyfile" 2>/dev/null)"
    site_line="$(printf '%s\n' "$caddyfile" | grep -m1 -E '^[[:space:]]*https?://')"
    if [ -n "$site_line" ]; then
        while IFS= read -r tok; do
            [ "$(classify_address "$tok")" = "global" ] && bad_sites="${bad_sites:+$bad_sites }$tok"
        done < <(extract_addresses_from_caddy_site_line "$site_line")
    fi
    if [ -n "$bad_sites" ]; then
        bad "rendered Caddyfile site list has no globally-routable address" "found: $bad_sites"
    else
        ok "rendered Caddyfile site list carries no globally-routable address"
    fi

    local listen bad_listen="" addr
    listen="$(_ssh "ss -tln 2>/dev/null" 2>/dev/null | tail -n +2)"
    while IFS= read -r addr; do
        [ -n "$addr" ] && [ "$(classify_address "$addr")" = "global" ] && bad_listen="${bad_listen:+$bad_listen }$addr"
    done < <(printf '%s\n' "$listen" | awk '{print $4}' | sed -E 's/^\[(.*)\]:[0-9]+$/\1/; s/:[0-9]+$//')
    if [ -n "$bad_listen" ]; then
        bad "no socket explicitly bound to a globally-routable address" "found LISTEN on: $bad_listen"
    else
        ok "no socket is explicitly bound to a globally-routable address (LAN/wildcard binds only)"
    fi

    if [ -n "$bad_sites" ] || [ -n "$bad_listen" ]; then
        bad "no globally-routable address is served" "see the Caddyfile/listen findings above"
    else
        ok "no globally-routable address is served — the dashboard is not reachable off-LAN"
    fi
}

run_watchdog_governor() {
    info "real-hardware-only — watchdog + CPU governor configuration present"
    local wd
    wd="$(_ssh "systemctl show -p RuntimeWatchdogUSec --value" 2>/dev/null)"
    if [ -n "$wd" ] && [ "$wd" != "0" ]; then
        ok "systemd runtime watchdog is armed (RuntimeWatchdogUSec=$wd)"
    else
        bad "systemd runtime watchdog armed" "RuntimeWatchdogUSec reads '${wd:-empty}' — expected a nonzero interval (baked as 20s)"
    fi
    if _ssh "[ -e /dev/watchdog ]"; then
        ok "a hardware watchdog device is present (/dev/watchdog) — this is what a KVM guest can never show"
    else
        info "no /dev/watchdog on this board — the systemd config is confirmed above; a board with no watchdog silicon is a real hardware limit, not a pithead defect"
    fi
    local gov
    gov="$(_ssh "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null")"
    if [ "$gov" = "performance" ]; then
        ok "CPU governor is running at performance (real cpufreq scaling — a KVM guest has no such node)"
    elif [ -n "$gov" ]; then
        bad "CPU governor is performance" "reads '$gov'"
    else
        info "no cpufreq scaling_governor node on this board — no-op by design where there is no cpufreq to steer"
    fi
}

run_tor_egress() {
    info "real-hardware-only — Tor egress posture on a real NIC"
    local out verdict
    out="$(_ssh "cd $REMOTE_DIR && bash tests/integration/benchmarks/bench-verify-egress.sh tor --dir $REMOTE_DIR --polls 3 --interval 10" 2>&1)"
    printf '%s\n' "$out" >/tmp/hw-battery-egress.log
    verdict="$(_egress_verdict "$out")"
    case "$verdict" in
    ok) ok "Tor egress posture holds on the real NIC (bench-verify-egress.sh: no clearnet leak)" ;;
    leak) bad "Tor egress posture on the real NIC" "bench-verify-egress.sh reported a LEAK — see /tmp/hw-battery-egress.log" ;;
    *) info "Tor egress check inconclusive (bench-verify-egress.sh produced no verdict — is $REMOTE_DIR the right stack directory?)" ;;
    esac
}

# --- physical items: print, never silently skip, record attestation with a timestamp --------
attest() { # attest <id> <instructions> <expected>
    local id="$1" instructions="$2" expected="$3"
    echo ""
    echo "=== $id (physical — operator action required) ==="
    echo "$instructions"
    echo "Expected: $expected"
    if [ "$NONINTERACTIVE" -eq 1 ] || [ ! -t 0 ]; then
        bad "$id attested" "not run interactively — NOT ATTESTED (rerun at a terminal, without --non-interactive, to record it)"
        ATTESTATIONS="${ATTESTATIONS}${id}: NOT ATTESTED (no interactive operator present)"$'\n'
        return 1
    fi
    local confirm="" outcome="" ts
    read -r -p "Type '$id' once you have performed this on the real hardware: " confirm || true
    if [ "$confirm" != "$id" ]; then
        bad "$id attested" "operator did not confirm — NOT ATTESTED"
        ATTESTATIONS="${ATTESTATIONS}${id}: NOT ATTESTED (operator declined or mistyped the confirmation)"$'\n'
        return 1
    fi
    read -r -p "Outcome (pass/fail + one line): " outcome || true
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ok "$id attested by ${USER:-operator} at $ts"
    ATTESTATIONS="${ATTESTATIONS}${id}: ATTESTED by ${USER:-operator} at ${ts} -- ${outcome:-<no detail given>}"$'\n'
}

write_results() {
    mkdir -p "$OUT_DIR"
    local ts file attestation_block
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    file="$OUT_DIR/hw-battery-$(date -u +%Y%m%dT%H%M%SZ).md"
    attestation_block="$ATTESTATIONS"
    [ -n "$attestation_block" ] || attestation_block="(none recorded)"
    {
        echo "# Appliance hardware battery — $ts"
        echo ""
        echo "Host: $HOST"
        echo "Result: $PASS passed, $FAIL failed"
        echo ""
        echo "## Automated (M7, M9, real-hardware-only assertions)"
        echo ""
        echo '```'
        printf '%s' "$RESULT_LOG"
        echo '```'
        echo ""
        echo "## Physical items (operator attestation)"
        echo ""
        printf '%s\n' "$attestation_block"
    } >"$file"
    echo "results written to $file"
}

require_host() {
    local c
    for c in docker rauc ssh scp; do
        have "$c" || {
            echo "missing $c — this battery builds/signs update bundles locally (see tests/os/README.md)" >&2
            exit 2
        }
    done
}

main() {
    parse_args "$@"
    [ -n "$HOST" ] || {
        echo "--host user@address is required" >&2
        usage >&2
        exit 2
    }
    # Resolve to an absolute path up front: build helpers cd to $ROOT before reading it.
    IDENTITY="$(cd "$(dirname "$IDENTITY")" 2>/dev/null && pwd)/$(basename "$IDENTITY")"
    [ -s "$IDENTITY" ] || {
        echo "no ssh private key at $IDENTITY (pass --identity)" >&2
        exit 2
    }
    [ -s "${IDENTITY}.pub" ] || {
        echo "no public key at ${IDENTITY}.pub — needed to bake into the M7/M9 test bundles" >&2
        exit 2
    }
    require_host

    info "checking the box is reachable before reserving it..."
    _wait_ssh 20 || {
        echo "cannot reach $HOST over ssh — nothing reserved, nothing touched" >&2
        exit 1
    }
    _ssh "command -v rauc" >/dev/null 2>&1 || {
        echo "$HOST has no rauc on PATH — this does not look like a pithead-os appliance" >&2
        exit 1
    }

    info "reserving the appliance bench (exclusive)..."
    bench_lock "hw-battery.sh $HOST $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ok "reservation acquired"

    run_m7
    run_m9
    run_no_global_address
    run_watchdog_governor
    run_tor_egress

    attest M1 "Write the image to a USB stick. Boot the target from it with Secure Boot ENABLED, then again with it DISABLED." \
        "reaches userspace both times, or fails with a legible message on Secure Boot rather than a blank screen"
    attest M4 "With a second disk present holding unrelated data, install to the appliance's own disk." \
        "the second disk is listed as untouched and its data is unchanged after install"
    attest M8 "During an update's write phase, physically cut power at the wall. Repeat three times." \
        "the machine boots the old version every time — a brick here blocks the release"
    attest M10 "Cut power at the wall with the stack running and synced. Restore power and do not touch the machine." \
        "it powers on by itself, the chain is intact, and mining resumes unaided"

    write_results
    echo ""
    printf 'hw-battery: \033[1;32m%d passed\033[0m, ' "$PASS"
    if [ "$FAIL" -gt 0 ]; then
        printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
        exit 1
    fi
    printf '0 failed\n'
}

# Test seam: `PITHEAD_HW_BATTERY_TEST=1 source tests/os/hw-battery.sh` defines every function
# (including the pure classifiers) without reserving anything, touching ssh, or running main —
# lets tests/stack/run.sh unit-test the pure logic. Mirrors os/build-image.sh's
# PITHEAD_BUILD_IMAGE_TEST seam.
if [ "${PITHEAD_HW_BATTERY_TEST:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

main "$@"

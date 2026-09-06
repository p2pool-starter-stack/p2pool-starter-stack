# shellcheck shell=bash
#
# The browser-shaped wizard submit for phase_provision (#1846). Sourced by tests/os/run.sh;
# tests/stack/test-harness-tooling.sh drives `--self-test` (tier 1, no guest).
# What a person's browser sends is not the no-JS field form: wizard.mjs takes the page's own
# served config (/api/wizard-state .config — the reference merged with the last attempt), sets the
# operator's answers on the same paths the page uses, and POSTs it whole as `config=<JSON>`
# beside `auth_mode=auto` (the recommended "generate a strong password for me"). The old leg
# posted `monero_wallet=…&pool=…`, which build_config() turns into a config server-side, so the
# path the operator actually took — and the one that refused on Both — never ran through the
# gate. A sibling, not rows in run.sh, which sits at its 3423-line ceiling.
#
# $1 ip, $2 authenticated cookie jar, then any extra form fields (`disk=vda`, `wipe=data` — the
# installer's disk half rides beside the config) -> prints the HTTP status of /submit (or a short
# reason when the page never served a config), the same contract the inline curl had.
# Reads /api/wizard-state the way a person waits for a page: up to six reads 5 s apart, until the jq
# filter in $3 yields a value. One cold read at -m 5 is not a verdict (#1932), and a fixture
# control built on one reddens with one word (#1936). On a hit WIZ_STATE holds the value (a raw
# string, or compact JSON) and the return is 0; otherwise WIZ_STATE is empty, the return is 1, and
# WIZ_STATE_WHY names what the last read saw — status, curl's rc, the read count, the head of the
# body — so the log discriminates a refusal from a timeout from a non-JSON page.
wizard_state_poll() { # <ip> <jar> <jq-filter>
    local raw="" http="" crc=0 tries=0
    WIZ_STATE="" WIZ_STATE_WHY=""
    while [ "$tries" -lt 6 ]; do
        raw=$(curl -sSk -b "$2" -m 5 -w '\n%{http_code}' "https://$1/api/wizard-state" 2>/dev/null)
        crc=$?
        http=${raw##*$'\n'}
        raw=${raw%$'\n'*}
        WIZ_STATE=$(printf '%s' "$raw" | jq -rc "$3" 2>/dev/null)
        [ -n "$WIZ_STATE" ] && return 0
        tries=$((tries + 1))
        sleep 5
    done
    WIZ_STATE_WHY="http=${http:-none} curl=$crc after ${tries}x5s body=$(printf '%s' "$raw" | head -c 60 | tr -c '[:print:]' '?')"
    return 1
}

provision_browser_submit() { # <ip> <jar> [field=value]...
    local ip="$1" jar="$2" cfg extra=()
    shift 2
    for f in "$@"; do extra+=(--data-urlencode "$f"); done
    wizard_state_poll "$ip" "$jar" '.config // empty' || {
        printf 'no-served-config(%s)' "$WIZ_STATE_WHY"
        return 1
    }
    # The four answers the Both role gives on the page, on the page's own paths (wizard.mjs
    # FIELDS: monero.wallet_address, tari.wallet_address, p2pool.pool, local_miner.enabled).
    cfg=$(printf '%s' "$WIZ_STATE" | jq -c --arg m "$HARNESS_WALLET" --arg t "$HARNESS_TARI" \
        '.monero.wallet_address = $m | .tari.wallet_address = $t | .p2pool.pool = "mini" | .local_miner.enabled = true') || {
        printf 'jq-failed'
        return 1
    }
    curl -sSk -b "$jar" --data-urlencode "config=$cfg" --data-urlencode "auth_mode=auto" "${extra[@]}" \
        "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null
}

# The page's own error line, for a red that names the refusal instead of a timeout. Empty when
# the page shows none (or cannot be reached).
provision_page_error() { # <ip> <jar>
    curl -sSk -b "$2" -m 5 "https://$1/api/wizard-state" 2>/dev/null | jq -r '.error // ""' 2>/dev/null
}

# --- self-test (#1936) -----------------------------------------------------------------------
#
# Driven by `tests/os/provision-browser-submit.sh --self-test`, tier 1, no guest: curl is a shim
# answering four shapes — a timeout, a 200 without .config, an HTML error page longer than the
# 60-byte bound, a config that arrives on the third read with a blank line before the status —
# and sleep is a no-op. Each
# reason is asserted on the exact string the battery log will carry. The last case is the control
# that the shim answered, not the real curl: no real read serves `.error` = x.
_wsp_case() { # <name> <got> <want>
    [ "$2" = "$3" ] && return 0
    printf '  FAIL %s: got [%s] want [%s]\n' "$1" "$2" "$3"
    return 1
}
_wsp_self_test() {
    local f=0 calls shape
    calls=$(mktemp)
    sleep() { :; }
    curl() { # the body, a newline, the status — what -w '\n%{http_code}' prints; rc per shape
        # the URL — the last argument — so a case can assert the route
        echo "${!#}" >>"$calls"
        case "$shape" in
        timeout) printf '\n000' && return 28 ;;
        noconfig) printf '{"error":"x"}\n200' ;;
        html) printf '<html><body>502 Bad Gateway\001 from an upstream that never answered in time</body></html>\n502' ;;
        late)
            [ "$(wc -l <"$calls")" -ge 3 ] || { printf '\n000' && return 28; }
            printf '{"config":{"monero":{"wallet_address":"4ABCDEFGHIJ"}}}\n\n200'
            ;;
        esac
    }
    shape=timeout
    : >"$calls"
    wizard_state_poll h j '.config // empty' && f=$((f + 1))
    _wsp_case timeout "$WIZ_STATE|$WIZ_STATE_WHY|$(wc -l <"$calls")" "|http=000 curl=28 after 6x5s body=|6" || f=$((f + 1))
    shape=noconfig
    : >"$calls"
    wizard_state_poll h j '.config // empty' && f=$((f + 1))
    _wsp_case noconfig "$WIZ_STATE_WHY" 'http=200 curl=0 after 6x5s body={"error":"x"}' || f=$((f + 1))
    shape=html
    : >"$calls"
    _wsp_case html "$(provision_browser_submit h j)" 'no-served-config(http=502 curl=0 after 6x5s body=<html><body>502 Bad Gateway? from an upstream that never ans)' || f=$((f + 1))
    shape=late
    : >"$calls"
    wizard_state_poll h j '.config // empty' || f=$((f + 1))
    _wsp_case late "$WIZ_STATE|$WIZ_STATE_WHY|$(wc -l <"$calls")" '{"monero":{"wallet_address":"4ABCDEFGHIJ"}}||3' || f=$((f + 1))
    shape=late
    : >"$calls"
    wizard_state_poll h j '.config.monero.wallet_address // empty' || f=$((f + 1))
    _wsp_case wallet "$WIZ_STATE" 4ABCDEFGHIJ || f=$((f + 1))
    shape=noconfig
    : >"$calls"
    wizard_state_poll h j '.error' || f=$((f + 1))
    _wsp_case control "$WIZ_STATE" x || f=$((f + 1))
    # The route: the wizard registers /api/wizard-state and no /api/state (#1932); a shim that
    # never reads its arguments would pass with either, so the URL the poll asked is asserted once.
    _wsp_case route "$(tail -n 1 "$calls")" 'https://h/api/wizard-state' || f=$((f + 1))
    rm -f "$calls"
    if [ "$f" -gt 0 ]; then
        printf '#1936 wizard-state-poll self-test FAILED: %s checks\n' "$f"
        return 1
    fi
    printf '#1936 wizard-state-poll self-test passed\n'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--self-test" ]; then
    set -uo pipefail # what tests/os/run.sh runs the helpers under
    _wsp_self_test
    exit $?
fi

# shellcheck shell=bash
#
# The browser-shaped wizard submit for phase_provision (#1846). Sourced by tests/os/run.sh.
# What a person's browser sends is not the no-JS field form: wizard.mjs takes the page's own
# served config (/api/state .config — the reference merged with the last attempt), sets the
# operator's answers on the same paths the page uses, and POSTs it whole as `config=<JSON>`
# beside `auth_mode=auto` (the recommended "generate a strong password for me"). The old leg
# posted `monero_wallet=…&pool=…`, which build_config() turns into a config server-side, so the
# path the operator actually took — and the one that refused on Both — never ran through the
# gate. A sibling, not rows in run.sh, which sits at its 3423-line ceiling.
#
# $1 ip, $2 authenticated cookie jar -> prints the HTTP status of /submit (or a short reason
# when the page never served a config), the same contract the inline curl had.
provision_browser_submit() { # <ip> <jar>
    local ip="$1" jar="$2" served cfg
    served=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/state" 2>/dev/null | jq -c '.config // empty' 2>/dev/null)
    [ -n "$served" ] || {
        printf 'no-served-config'
        return 1
    }
    # The four answers the Both role gives on the page, on the page's own paths (wizard.mjs
    # FIELDS: monero.wallet_address, tari.wallet_address, p2pool.pool, local_miner.enabled).
    cfg=$(printf '%s' "$served" | jq -c --arg m "$HARNESS_WALLET" --arg t "$HARNESS_TARI" \
        '.monero.wallet_address = $m | .tari.wallet_address = $t | .p2pool.pool = "mini" | .local_miner.enabled = true') || {
        printf 'jq-failed'
        return 1
    }
    curl -sSk -b "$jar" --data-urlencode "config=$cfg" --data-urlencode "auth_mode=auto" \
        "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null
}

# The page's own error line, for a red that names the refusal instead of a timeout. Empty when
# the page shows none (or cannot be reached).
provision_page_error() { # <ip> <jar>
    curl -sSk -b "$2" -m 5 "https://$1/api/state" 2>/dev/null | jq -r '.error // ""' 2>/dev/null
}

# --- Subcommand chaining (#94) ---

# Every dispatchable subcommand, in help order. main's dispatch, the chain validator, and the
# tab-completion script (pithead-completion.bash) key off this one list; tests/stack/run.sh fails
# if any of the three drift apart.
readonly PITHEAD_COMMANDS="setup apply render up down restart upgrade logs status doctor support-bundle reset-dashboard config-reset factory-reset backup restore uninstall firstboot-wizard load-images local-miner os-update control-run-pending onion-client-key rotate-dashboard-onion rotate-secrets render-quadlet version help"
# The subset allowed in a chain: commands that take no positional argument and terminate on their
# own. Excluded: setup (interactive first-run), logs (follows until Ctrl+C), restore (needs an
# archive path), reset-dashboard (destructive — run it deliberately, alone), and the one-shot
# info/maintenance commands (version, help, onion-client-key, rotate-dashboard-onion).
readonly PITHEAD_CHAINABLE="apply up down restart upgrade status doctor backup"

is_pithead_command() { case " $PITHEAD_COMMANDS " in *" $1 "*) ;; *) return 1 ;; esac }

# Reject a nonsensical chain BEFORE any step runs (#94): chainable commands only, no duplicates,
# at most one of up/down/restart (two run-state commands in one chain contradict or repeat each
# other), and `down` only as the final step (anything after it would act on a stopped stack).
validate_chain() {
    local c seen="" runstate=0 last="${!#}"
    for c in "$@"; do
        case " $PITHEAD_CHAINABLE " in
        *" $c "*) ;;
        *) error "Invalid chain: '$c' can't be chained — run it on its own. Chainable commands: $PITHEAD_CHAINABLE. Nothing was run." ;;
        esac
        case " $seen " in
        *" $c "*) error "Invalid chain: '$c' appears twice. Nothing was run." ;;
        esac
        seen="$seen $c"
        case "$c" in up | down | restart) runstate=$((runstate + 1)) ;; esac
    done
    if [ "$runstate" -gt 1 ]; then
        error "Invalid chain: up/down/restart contradict each other in one invocation. Nothing was run."
    fi
    if [ "$last" != "down" ]; then
        case " $* " in
        *" down "*) error "Invalid chain: 'down' must be the last step — the commands after it would run against a stopped stack. Nothing was run." ;;
        esac
    fi
}

# Run an all-subcommand argv left-to-right, validating the whole chain first. Each step is its own
# pithead invocation, so a step's `exit` can't skip the accounting here. Fails fast: the first
# non-zero step stops the chain, the report says what ran and what didn't, and that step's exit
# code is propagated.
run_chain() {
    validate_chain "$@"
    local total=$# i=0 c rc
    for c in "$@"; do
        i=$((i + 1))
        log "── chain step $i/$total: $c"
        rc=0
        bash "${PITHEAD_SELF:-$0}" "$c" || rc=$?
        if [ "$rc" -ne 0 ]; then
            warn "Chain stopped: step $i/$total ('$c') failed with exit code $rc."
            if [ "$i" -gt 1 ]; then warn "Already ran: ${*:1:$((i - 1))}."; fi
            if [ "$i" -lt "$total" ]; then warn "Did not run: ${*:$((i + 1))}."; fi
            exit "$rc"
        fi
    done
}

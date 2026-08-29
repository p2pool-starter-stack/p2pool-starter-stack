# --- Main Execution ---

# #493: a subcommand's -h/--help must print usage and exit 0 BEFORE any side effect, and a
# subcommand that takes no options must reject an unrecognized flag instead of silently ignoring it
# and running anyway. `pithead upgrade --help` used to run a full upgrade (image pull + container
# recreation) — on the v1.4.0 deploy that recreation collided with the real upgrade and corrupted
# the dashboard DB (#489). A --help must never mutate the host.
_help_requested() { # "$@" — return 0 if any argument is -h/--help
    local a
    for a in "$@"; do
        case "$a" in
        -h | --help) return 0 ;;
        esac
    done
    return 1
}
_reject_options() { # <verb> "$@" — this verb takes no options; error on any leftover argument
    local verb="$1"
    shift
    [ "$#" -eq 0 ] || error "Unknown option for $verb: '$1'. This command takes no options. Run '$0 $verb -h' or '$0 help'."
}

main() {
    # Chained subcommands (#94): when every argument is a bare subcommand name, run them
    # left-to-right as a chain. Any other token (a flag, a service name, an archive path) keeps
    # the invocation on the single-command path below, unchanged.
    if [ "$#" -ge 2 ]; then
        local _tok _chain=1
        for _tok in "$@"; do
            if ! is_pithead_command "$_tok"; then
                _chain=0
                break
            fi
        done
        if [ "$_chain" -eq 1 ]; then
            run_chain "$@"
            return 0
        fi
    fi

    local cmd="${1:-}"
    if [ -n "$cmd" ]; then shift; fi

    # #493: -h/--help on any subcommand prints help and exits 0 before ANY side effect. `logs` is the
    # one deliberate passthrough (its args go to `docker compose logs`), so it opts out and forwards
    # -h/--help downstream. The bare `pithead -h/--help/help` is its own command in the case below.
    case "$cmd" in
    "" | help | -h | --help | logs) ;;
    *) if _help_requested "$@"; then
        show_help
        exit 0
    fi ;;
    esac

    # Make the stack version + build provenance available to any `docker compose [up] build` this
    # invocation runs, so the dashboard image bakes in its version badge (Issue #58).
    export_build_provenance

    case "$cmd" in
    "")
        # No command: first-time users get setup, deployed users get help.
        if is_deployed; then show_help; else setup; fi
        ;;
    setup)
        for arg in "$@"; do
            case "$arg" in
            --skip-optimize) SKIP_OPTIMIZE=1 ;;
            --skip-deps) SKIP_DEPS=1 ;;
            *) error "Unknown option for setup: $arg. Run '$0 help'." ;;
            esac
        done
        setup
        ;;
    apply) apply "$@" ;;
    render)
        _reject_options render "$@"
        render_derived
        ;;
    up)
        _reject_options up "$@"
        require_deployed
        stack_up
        ;;
    down)
        _reject_options down "$@"
        require_env
        stack_down
        ;;
    restart)
        require_deployed
        stack_restart "$@"
        ;;
    upgrade)
        _reject_options upgrade "$@"
        require_deployed
        stack_upgrade
        ;;
    logs)
        require_env
        log "Following logs (Ctrl+C to exit)..."
        docker compose logs -f "$@"
        ;;
    status)
        _reject_options status "$@"
        require_env
        stack_status || exit 1
        ;;
    doctor)
        case "${1:-}" in
        "") doctor || exit 1 ;;
        --json)
            [ "$#" -eq 1 ] || error "doctor --json takes no further options. Run '$0 help'."
            doctor_json || exit 1
            ;;
        *) error "Unknown option for doctor: '$1'. Run '$0 help'." ;;
        esac
        ;;
    support-bundle) stack_support_bundle "$@" ;;
    reset-dashboard)
        require_deployed
        reset_dashboard "$@"
        ;;
    config-reset) config_reset "$@" ;;
    factory-reset) factory_reset "$@" ;;
    backup) stack_backup "$@" ;;
    restore) stack_restore "$@" ;;
    uninstall) stack_uninstall "$@" ;;
    firstboot-wizard) firstboot_wizard "$@" ;;
    load-images)
        _reject_options load-images "$@"
        load_baked_images
        ;;
    local-miner)
        _reject_options local-miner "$@"
        # A rig has no .env and never will — there is no stack on it to render one.
        [ "$(machine_role)" = "rig" ] || require_env
        provision_local_miner
        ;;
    os-update) os_update "$@" ;;
    control-run-pending)
        _reject_options control-run-pending "$@"
        require_deployed
        control_run_pending
        ;;
    onion-client-key)
        _reject_options onion-client-key "$@"
        onion_client_key
        ;;
    rotate-dashboard-onion) rotate_dashboard_onion "$@" ;;
    rotate-secrets) rotate_secrets "$@" ;;
    render-quadlet)
        rq_env=".env" rq_out="./quadlet"
        while [ $# -gt 0 ]; do
            case "$1" in
            --env)
                [ -n "${2:-}" ] || error "render-quadlet: --env needs a file argument."
                rq_env="$2"
                shift 2
                ;;
            --out)
                [ -n "${2:-}" ] || error "render-quadlet: --out needs a directory argument."
                rq_out="$2"
                shift 2
                ;;
            *) error "Unknown option for render-quadlet: $1. Run '$0 help'." ;;
            esac
        done
        render_quadlet_units "$rq_env" "$rq_out"
        ;;
    version | -V | --version) show_version ;;
    help | -h | --help) show_help ;;
    *) error "Unknown command: $cmd. Run '$0 help'." ;;
    esac
}

if [ "$_STACK_SOURCED" = "0" ]; then
    main "$@"
fi

show_help() {
    cat <<EOF
Usage: $0 <command> [options]

Manage the P2Pool / Monero + Tari merge-mining stack.

Setup & configuration:
  setup [--skip-optimize] [--skip-deps]
                            First-time setup: dependency check, interactive config, Tor
                            provisioning, kernel optimization, and start.
                              --skip-optimize  skip the kernel/GRUB HugePages tuning.
                              --skip-deps      skip dependency detection/install (for
                                               unsupported or custom setups).
  apply [-y|--yes] [--dry-run [--porcelain]]
                            Re-read config.json and propagate changes: previews what will
                            change, warns before anything disruptive, then recreates only
                            the containers that need it. Use this after you edit config.json.
                              -y, --yes        apply without the confirmation prompt.
                              --dry-run        print the change preview and stop; nothing is
                                               written or recreated.
                              --porcelain      with --dry-run: machine-readable preview lines
                                               (FLAG<TAB>KEY<TAB>MESSAGE), used by the
                                               dashboard control runner.

Lifecycle:
  render                    Regenerate every derived file (.env, Caddyfile, service
                            configs, host units) from config.json without touching
                            containers. The appliance runs this on every boot; run it by
                            hand after replacing the program under an existing config.
  up                        Start the stack.
  down                      Stop the stack.
  restart [tor|monerod]     Restart the stack — or one container: 'tor' picks fresh
                            guards when Tor clearnet egress is stuck (drops and rebuilds
                            all Tor circuits; a local monerod restarts alongside);
                            'monerod' re-dials peers when the node reports not
                            synchronized after a Tor restart.
  upgrade                   Re-render generated config and rebuild/restart the stack after
                            an update — a 'git pull' on source installs, or an extracted
                            release bundle (the dashboard's one-click upgrade runs this).

Inspection:
  logs [service]            Follow logs for all containers, or a single service.
  status                    Show container status + health-check every expected service
                            (warns about anything down; non-zero exit if so).
  doctor [--json]           Read-only diagnostics: deps, Docker, AVX2, HugePages, RAM/disk,
                            .env/onion state, and container status — a paste-able health report.
                              --json           machine-readable report on stdout (the human
                                               report moves to stderr); same checks, same
                                               non-zero exit on critical failures.
  support-bundle            Collect a chmod-600 diagnostics tarball for a bug report: host
                            facts, doctor (prose + JSON), masked config, redacted .env, and
                            the last 200 log lines per container (launch-line credentials
                            scrubbed). Read-only; nothing leaves the box — review, then share.
  version, -V, --version    Print the installed stack version (offline; no update check).

Maintenance:
  reset-dashboard [-y|--yes]
                            DESTRUCTIVE: wipe and recreate dashboard/p2pool data.
                              -y, --yes        skip the confirmation prompt.
  config-reset [-y|--yes]   DESTRUCTIVE: clear the configuration and reopen the setup wizard,
                            keeping every data directory — chains, wallets, Tor onion keys, and
                            dashboard history all stay, so reconfiguring costs no resync. Removes
                            config.json and the files rendered from it, then (on the appliance)
                            reboots into first-boot setup. Type-to-confirm unless -y.
                              -y, --yes        skip the confirmation prompt.
  factory-reset [-y|--yes]  DESTRUCTIVE (appliance only): erase the whole data partition back to
                            a blank machine — chains, wallets, Tor keys, and settings all go — then
                            reboot into the setup wizard. The chain resync that follows costs days;
                            reach for config-reset first. On a normal install, 'uninstall' is the
                            clean exit instead. Type-to-confirm unless -y.
                              -y, --yes        skip the confirmation prompt.
  backup [--with-chains] [--no-encrypt] [-y|--yes]
                            Write a timestamped, chmod-600 archive under backups/ holding the
                            irreplaceable bits: config.json, .env, Caddyfile, the Tor data dir
                            (onion keys), and the dashboard's database (your hashrate history &
                            settings). Blockchains are excluded unless --with-chains.
                            Encrypted by default (openssl AES-256-CBC + PBKDF2, .tar.gz.enc):
                            prompts for a passphrase, or reads PITHEAD_BACKUP_PASSPHRASE for
                            unattended runs. With --yes and no passphrase set, falls back to a
                            plaintext tar.gz with a warning.
                            If the stack is running, backup stops it for a consistent copy and
                            starts it again when it's done.
                              --with-chains    also include the blockchain data (large).
                              --no-encrypt     write a plaintext tar.gz (the pre-v1.4 format).
                              -y, --yes        skip the confirmation prompts (low free space,
                                               and stopping a running stack).
  restore [-y|--yes] <archive>
                            Restore config.json, .env, Caddyfile, the Tor data dir, and the
                            dashboard's database from a backup archive (prompts before
                            overwriting; fixes Tor ownership). Detects encrypted (.enc) vs
                            plaintext archives by content — old backups restore unchanged.
                            Asks for the passphrase (or reads PITHEAD_BACKUP_PASSPHRASE) and
                            fails before touching anything if it's wrong.
                              -y, --yes        restore without the confirmation prompt.

  uninstall [-y|--yes]      DESTRUCTIVE: the clean exit. Stops the stack, removes its
                            containers and images, deletes the rendered .env and Caddyfile,
                            this checkout's control-runner units, and the egress firewall
                            rules. Keeps what is yours: config.json, backups/, and the data
                            dirs (chains, Tor onion keys, dashboard DB) — the closing message
                            lists them for manual removal. Type-to-confirm unless -y.
                              -y, --yes        skip the confirmation prompt.

  firstboot-wizard [--cli]  Browser-first setup for an unconfigured checkout: serves a
                            token-gated form on http://<this-host>/ (the dashboard image in
                            wizard mode), validates the answers host-side, then runs setup.
                            A pre-seeded config.json skips the form; --cli runs the terminal
                            wizard instead. The one-time token prints here; five wrong tries
                            mint a fresh one. See $DOCS_URL/docs/appliance.md.

  load-images               Load the baked container-image archives (/opt/pithead/images)
                            into the engine when their content changed since the last load.
                            The boot path runs this on every boot — a reinstall or update
                            that ships new images converges without any wizard involvement.

  local-miner               Converge this machine's RigForge worker to what the machine is.
                            On a coordinator that follows local_miner.enabled: RigForge's
                            setup in appliance mode when it is on (the miner points at this
                            machine's own stratum), the miner stopped when it is off. On a rig
                            it follows rig.json instead — that machine has no stack, and the
                            miner is the whole of it. The boot path runs this on every boot;
                            a no-op outside the appliance.

  os-update BUNDLE [-y|--yes] [--allow-downgrade]
                            Install an OS update bundle into the spare A/B slot (appliance
                            only — runs 'rauc install'). Refuses a bundle older than the
                            running OS (a signed downgrade re-opens fixed holes), and refuses
                            one below the /data migration floor outright. When this system is a
                            debug build (SSH baked in) and the bundle is not, it warns and asks
                            first: that install removes the SSH channel driving it.
                              -y, --yes          skip the confirmation prompt.
                              --allow-downgrade  install an older bundle on purpose (does not
                                                 override the /data migration floor).

  onion-client-key          Print the Tor client-auth line for the dashboard onion —
                            the client PRIVATE key, kept out of 'status'. Add it to your Tor
                            client's ClientOnionAuthDir to reach a client-auth'd onion.

  rotate-dashboard-onion [-y|--yes]
                            Mint a fresh dashboard .onion address and client-auth key;
                            the old address and any client keys you handed out stop working.
                              -y, --yes        skip the confirmation prompt.

  control-run-pending       Process queued dashboard control requests: validate each
                            intent and run 'apply --dry-run' (preview), 'apply -y' (commit),
                            or a release upgrade (target verified against the GitHub
                            release API host-side). Normally fired by the pithead-control
                            systemd path unit when dashboard.control.enabled is true.

  render-quadlet [--env FILE] [--out DIR]
                            Render Podman Quadlet units (the appliance runtime) from a
                            rendered .env — the second render target beside docker-compose.
                            Defaults: --env .env, --out ./quadlet. Refuses local-node profiles
                            until their units are bench-proven (phase 2). The os/quadlet/
                            fixtures pin this output byte-for-byte.

  rotate-secrets [-y|--yes]
                            Regenerate the stack's internal credentials: the local Monero
                            RPC password, the stratum access-password (only when
                            p2pool.stratum_password is "auto" — every rig must then update its
                            'pass'), and the xmrig-proxy control-API token. Recreates the
                            affected containers; old values stay in timestamped .bak-* copies.
                              -y, --yes        skip the confirmation prompt.

  help, -h, --help          Show this message.

Commands can be chained: '$0 apply upgrade' runs both in order, stopping at the
first failure. Chainable: apply, up, down, restart, upgrade, status, doctor, backup.
Contradictory chains (e.g. 'up down', duplicates, anything after 'down') are
rejected before anything runs.

Tab-completion: 'source pithead-completion.bash' (bash; zsh via bashcompinit) —
see $DOCS_URL/docs/operations.md.

Workflow: edit config.json, then run '$0 apply'.
EOF
}

# One-line, greppable version identity for support threads (#386). Reads the provenance
# export_build_provenance already computed this invocation — never re-reads VERSION or calls git,
# so a release bundle (no .git) works and the values can't drift. `unknown` when VERSION is absent.
show_version() {
    local ver="unknown"
    [ -n "$PITHEAD_VERSION" ] && ver="v$PITHEAD_VERSION"
    if is_source_checkout; then
        echo "pithead dev (${PITHEAD_GIT_BRANCH:-unknown} @ ${PITHEAD_GIT_COMMIT:-unknown}, VERSION ${PITHEAD_VERSION:-unknown})"
    else
        echo "pithead $ver (release images $STACK_VERSION)"
    fi
}

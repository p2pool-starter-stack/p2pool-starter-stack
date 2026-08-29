# The @sha256 digest the bundled compose pins pithead-<suffix> to (#461 writes these into the
# released compose). Empty if the image line carries no digest (an un-pinned/dev compose). Mirrors
# the caddy-digest read at bcrypt-hash time (grep straight from docker-compose.yml at cwd).
compose_pinned_digest() {
    grep -oE "pithead-$1:[^[:space:]]*@sha256:[0-9a-f]+" docker-compose.yml |
        grep -oE 'sha256:[0-9a-f]+' | head -1
}

# The verifier runs as a container, not a host binary (#1072). cosign has no Ubuntu apt package, so
# requiring it on the host made signing a hidden prerequisite that no doc listed and no dependency
# check installed: a fresh bundle install dead-ended at first `up`, and every fielded install cut
# before signing engaged hit the same wall on its first signed upgrade — after the download, the
# extract, and the control-unit re-provision (#1070). Docker is already a hard prerequisite and the
# very next step of both callers pulls images with it, so running cosign this way costs the operator
# nothing to install and nothing to know about.
#
# The @sha256 pin is LOAD-BEARING, not cosmetic housekeeping: verifying release images by first
# pulling a verifier image is itself an unverified pull, and the digest is the only thing that
# closes it. Pinned, a hostile registry can serve nothing but the exact bytes named here or fail the
# pull outright; on a tag it could serve a "cosign" that exits 0 on everything and silently turn the
# whole gate off. Bootstrapping is therefore trust-on-first-use exactly as downloading the binary
# from GitHub was — no weaker, and pinned to bytes rather than to a mutable tag. Never relax this to
# a tag, and treat bumping it as a supply-chain change.
readonly COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign@sha256:4bedb8de1c5c1abd8dea60de704ba449402d238623fa8bb33d2ccaa9beffcbf5" # v2.6.3

# Verification is possible at all — i.e. we can run the verifier. Kept as its own predicate so the
# callers' fail-closed refusals read the same as they did when this was `command -v cosign`.
cosign_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# Run cosign in a container, with the install dir mounted read-only at /w as its working dir.
# ponytail: ONE mount, because every file cosign is ever handed lives under the install dir —
# cosign.pub sits next to this script, and the bundle + .sig it verifies on a one-click upgrade go
# under CONTROL_DIR, which is derived as "$PWD/data/control" and is not operator-settable. A caller
# that ever needs a path outside $PWD must add its own mount rather than assume this one covers it.
# HOME=/tmp: cosign caches TUF material under $HOME and prints a multi-line warning when it cannot
# write there — noise on every verify, and the operator is not meant to see this run at all.
# The image pull is quiet and happens once; without it docker streams pull progress mid-`up`.
cosign_run() {
    docker image inspect "$COSIGN_IMAGE" >/dev/null 2>&1 ||
        docker pull -q "$COSIGN_IMAGE" >/dev/null 2>&1 ||
        return 1
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$PWD:/w:ro" -w /w "$COSIGN_IMAGE" "$@"
}

# Translate a host path under the install dir into the path cosign_run's container sees. Both sides
# are canonicalized, so a caller reaching the same file through a symlink (`current -> pithead-vX`)
# still resolves. Fails — rather than emitting a path the mount does not cover — when the file is
# outside the install dir, because every caller reports a cosign failure as a signature failure.
cosign_container_path() { # <path>
    local dir root
    dir=$(cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 1
    root=$(pwd -P) || return 1
    case "$dir" in
    # One arm for both depths: at the install root the strip leaves "", giving /w/<name>.
    "$root" | "$root"/*) printf '/w%s/%s\n' "${dir#"$root"}" "$(basename -- "$1")" ;;
    *) return 1 ;;
    esac
}

# Cryptographic gate on a release pull (#376). Runs before both the upgrade pull and the
# first-install pull (#452), so every first-party image the pull would fetch must carry a cosign
# signature that verifies against the cosign.pub shipped next to this script. Key-based signing from
# the release box — no Rekor transparency log, hence --private-infrastructure (a plain key signature
# carries no Rekor bundle, and cosign would otherwise demand one).
#
# #451 — verification and the pull are bound to the SAME bytes: the released bundle pins each
# first-party image to an immutable @sha256 digest (#461), and compose pulls by that digest. We
# cosign-verify that SAME digest, not the mutable tag. A tampered registry cannot serve one manifest
# to cosign and another to docker — both are content-addressed to the identical sha256, and docker
# rejects a pull whose bytes don't hash to the pinned digest. Verifying the tag left a window open:
# cosign and the pull resolved the tag in separate registry dials.
#
# The decision table, fail-closed where a key exists:
#   source checkout                          -> skip: locally built images are unsigned by design
#   no cosign.pub (an older/unsigned bundle) -> proceed with one loud warning (#461 — an install
#                                               predating the first signed release has no key to
#                                               verify with; the digest-pinned bundle is what
#                                               protects it. Every bundle since ships the key, so
#                                               this is a legacy path, not a way to opt out)
#   cosign.pub present, docker missing       -> ABORT — an absent verifier must not silently
#                                               disable verification (docker is a prerequisite and
#                                               the very next step pulls images with it anyway)
#   cosign.pub present, image not pinned     -> ABORT: with no digest there's nothing to bind the
#                                               verification to the pulled bytes (the #451 window)
#   any signature that fails to verify       -> ABORT naming the image; nothing pulled or restarted
verify_release_images() {
    is_source_checkout && return 0
    if [ ! -f cosign.pub ]; then
        warn "No cosign.pub next to pithead — the release images will NOT be signature-verified. Releases up to v1.3.x shipped no key; the first signed bundle brings it."
        return 0
    fi
    cosign_available ||
        error "cosign.pub is present but docker is not available to run the verifier — refusing an unverified pull. Install Docker ($DOCS_URL/docs/getting-started.md#1-prerequisites) and re-run '$0'."
    # The 5 first-party images, verified by the exact digest compose pins them to (#451/#461).
    local suffix repo sha image out
    for suffix in tor monero p2pool xmrig-proxy dashboard; do
        repo="${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}/pithead-${suffix}"
        # #557: plain `sha="$(...)"` aborts under errexit on a no-match grep BEFORE this error()
        # fires — `if !` suspends errexit for the assignment so the crafted diagnostic is reachable.
        if ! sha="$(compose_pinned_digest "$suffix")" || [ -z "$sha" ]; then
            error "cosign.pub is present but pithead-${suffix} is not digest-pinned in docker-compose.yml — cannot bind verification to the bytes compose pulls; refusing. A signed release bundle pins every first-party image by @sha256."
        fi
        image="${repo}@${sha}"
        if ! out=$(cosign_run verify --key cosign.pub --private-infrastructure "$image" 2>&1); then
            # Strip control chars: cosign's stderr echoes registry-supplied bytes, and error()
            # prints via `echo -e`, so an attacker-controlled registry response could otherwise
            # inject ANSI escapes into the operator's terminal (#376 review).
            error "Signature verification FAILED for $image — the published image does not match the release key; refusing to pull or restart, nothing was changed. cosign said: $(printf '%s' "$out" | tr -d '[:cntrl:]' | tail -c 300)"
        fi
    done
    log "All 5 release images verify against their pinned digest (cosign.pub)."
}

stack_upgrade() {
    if is_appliance; then
        error "This is a Pithead OS appliance: the program tree is delivered by OS images and resynced from the system slot at every boot, so a tarball upgrade here would silently revert at the next reboot. Updates arrive as signed OS images — see the appliance guide."
    fi
    mutation_lock_acquire upgrade
    log "Upgrading stack (rebuilding containers)..."
    # A release (git pull) may change config templates, add/rename .env vars, or restructure the
    # Caddyfile / Tari config — all GENERATED files mounted into containers. Re-render them before
    # rebuilding so new images don't run against the stale generated config from the last
    # setup/apply (#128). Mirrors apply's render preamble; renders to a temp + swaps so preserved
    # secrets (Tor onions, RPC creds, proxy token) survive.
    require_env
    ensure_onion_password # #343: auto-generate a dashboard password if the onion is on without one —
    # MUST run before parse_and_validate_config, which rejects an onion enabled with an empty password
    # (mirrors setup/apply; without this, enabling the onion via `upgrade` errored instead of #355).
    parse_and_validate_config
    load_preserved_state
    ensure_directories
    resolve_dashboard_host # non-interactive; sets HOST_IP for the render
    # render_env writes DEPLOYMENT_COMPLETED=${DEPLOYMENT_COMPLETED:-false}; load_preserved_state
    # doesn't carry it, so re-assert it here (as apply does) — otherwise every upgrade rewrites the
    # flag to false and the next require_deployed command (up/apply/upgrade) errors "run setup". We
    # only reach here past require_deployed, so the stack IS deployed and the flag must stay true.
    DEPLOYMENT_COMPLETED=true
    render_env "${ENV_FILE}.new"
    mv "${ENV_FILE}.new" "$ENV_FILE"
    provision_node_onions # #103: as in apply — a node switched to local needs its onion first
    inject_service_configs
    generate_caddyfile
    provision_ssh_access
    provision_console_login
    log "Re-rendered generated config for the current release."
    migrate_compose_project
    # (Re)assert the Tor-only egress firewall BEFORE compose — same ordering as stack_up (#276), for
    # the same reason: if the firewall isn't already installed (e.g. `down` then `upgrade`), starting
    # containers first opens a startup window where a clearnet app (Tari, #271) can open a connection
    # that the leading ESTABLISHED rule then grandfathers past the DROP (#291). In normal operation
    # it's already installed from `up` and this is a cheap idempotent re-apply. Runs after the .env
    # render above so the toggle/subnet are current.
    apply_tor_egress_firewall # Tor-only egress (#270), consistent with up/apply
    # One-time move of the dashboard data out of the install dir (#455) — after the .env commit
    # (a failed move is retried on re-run) and before the recreate mounts the new location.
    migrate_dashboard_data
    # Source checkout: rebuild the images from build/. Release install: pull the new published images
    # instead — force a re-pull so a moved tag is refreshed (#44).
    if is_source_checkout; then
        # Source checkouts build the first-party images locally (--build) and use --pull never so up
        # never tries to pull an unpublished :dev tag. But the THIRD-PARTY images (caddy, tari, the
        # socket-proxies) are pinned by digest and CAN change between releases — under --pull never a
        # bumped digest fails with "No such image". Pull just the non-buildable images first so a new
        # digest is fetched; best-effort (older compose without --ignore-buildable falls through).
        docker compose pull --ignore-buildable 2>/dev/null || true
        compose_up_checked -d --build || error "Upgrade failed during 'docker compose up' — see the error above."
    else
        verify_release_images # #376: fail closed BEFORE the pull when a release key is on disk
        PITHEAD_PULL=always compose_up_checked -d || error "Upgrade failed during 'docker compose up' — see the error above."
    fi
    # #356: if the dashboard onion (#343) was just turned on, the recreated tor generated its hostname —
    # read it back into .env so `status`/`onion-client-key` show the address (mirrors apply's capture at
    # the end of a change). No-op when the onion is off or already captured. Without this, enabling the
    # onion via `upgrade` left the address uncaptured (apply's capture only runs when config changed).
    # #546: and regenerate the Caddyfile + restart caddy, exactly like apply's capture — the render
    # preamble above ran while the address was still the placeholder, so without this the HTTPS onion
    # vhost (#360) would never appear (the next apply no-ops on an unchanged config).
    if [ "${DASHBOARD_ONION_ENABLED:-false}" == "true" ] && onion_missing "${DASHBOARD_ONION:-}"; then
        if provision_dashboard_onion && render_env; then
            generate_caddyfile
            docker compose restart caddy
        fi
    fi
    update_current_symlink # #455: only a SUCCESSFUL upgrade moves the `current ->` pointer
    # #33: converge the control-runner units on the current toggle — LAST, and deliberately after
    # update_current_symlink. #1070: a fresh-dir one-click deploy runs this function from the NEW
    # version dir while `current ->` still points at the old one, so provisioning it early (where it
    # used to sit, before the image gate) pointed the units at a directory that had not become the
    # install yet. Any abort in between — the image gate, a failed pull, a health-gate failure —
    # then left the path unit watching a spool the running dashboard never writes to, silently
    # killing the control channel and with it the one-click upgrade that would have fixed it. The
    # units are host-global and name an absolute path, so the only safe moment to repoint them is
    # after this dir IS `current`. A failure before here now leaves the old install's units intact
    # and still serving. Do not move this back above the pull.
    # `steal`: this dir just became `current`, so repointing the units here is the definition of a
    # legitimate takeover — the old versioned dir still exists (it is the rollback), and without
    # the escape the ownership guard would refuse and leave the units on the previous install.
    provision_control_runner steal
    log "Stack upgraded."
    mutation_lock_release
}

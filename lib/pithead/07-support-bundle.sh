# `support-bundle` (#77 phase 1): most support is log collection — one command gathers what a
# report needs into a chmod-600 tarball the operator reviews before sharing. Read-only; nothing
# leaves the box. Secrets are redacted at the source: config via the control channel's masking
# (render_masked_config), .env by key pattern, container logs by argv position — p2pool echoes its
# --rpc-login, both wallet addresses and the service onion on launch, the leak class this exists to
# stop. The membership of that class was drawn too narrowly until #1585; add to bundle_redact_log,
# not to a second list.

# Keyed by POSITION and not by shape, which is #1585's ruling: no length bar reaches all three Tari
# address forms this repo validates (91, 48 and 67 characters, the last non-alphanumeric), and a bar
# low enough to try starts eating ordinary log tokens. The onion keeps its own shape rule — it is
# the one value that also appears away from the launch line. The .env half of this bundle has always
# treated wallets and onions as secrets, so leaving them here shipped one artifact under two
# policies. Per-form rows and the full derivation: tests/integration/selftest-bundle-redact-log.sh;
# tests/integration/lib.sh's redact() keys on the same property (#1607) and the two stay in step.
bundle_redact_log() {
    sed -E \
        -e 's/(--rpc-login|--http-access-token|--tls-fingerprint)[= ][^ ]+/\1 [redacted]/g' \
        -e 's/(--wallet[ =])[^-[:space:]][^[:space:]]*/\1[redacted-address]/g' \
        -e 's/(--merge-mine[ =][^[:space:]]+[[:space:]]+)[^-[:space:]][^[:space:]]*/\1[redacted-address]/g' \
        -e 's/[a-z2-7]{56}\.onion/[redacted].onion/g'
}

stack_support_bundle() {
    _reject_options support-bundle "$@"
    local ts out tmp rc=0
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    out="$PWD/support-bundle-$ts.tar.gz"
    tmp=$(mktemp -d)
    mkdir -p "$tmp/bundle/logs"

    log "Collecting diagnostics (read-only)..."
    {
        echo "pithead ${PITHEAD_VERSION:-unknown}"
        uname -a
        echo
        df -h 2>/dev/null || true
        echo
        free -h 2>/dev/null || true
    } >"$tmp/bundle/host.txt" 2>&1
    doctor_json >"$tmp/bundle/doctor.json" 2>"$tmp/bundle/doctor.txt" || rc=$?
    [ "$rc" -gt 0 ] && log "doctor reported failures — included in the bundle."

    # Masked config: the same jq walk the dashboard prefill uses; every set secret leaf becomes
    # {"__secret__": true}. Rendered into the scratch dir, never into the live control spool.
    if [ -f "$CONFIG_FILE" ]; then
        render_masked_config "$tmp/scratch" 2>/dev/null || true
        [ -f "$tmp/scratch/masked/config.json" ] &&
            cp "$tmp/scratch/masked/config.json" "$tmp/bundle/config.masked.json"
    fi
    # .env with secret-bearing values stripped by key pattern; structure (ports, dirs, modes)
    # stays — that is what support actually needs.
    if [ -f .env ]; then
        awk -F= '/^[A-Z0-9_]+=/ {
            if ($1 ~ /(PASSWORD|TOKEN|SECRET|KEY|WALLET|ONION|AUTH|PING_URL|CHAT_ID)/) print $1 "=[redacted]";
            else print; next } { print }' .env >"$tmp/bundle/env.redacted" 2>/dev/null || true
    fi

    # Container state + recent logs, when an engine is reachable. bundle_redact_log guards the
    # launch lines services echo: the credential flags, the wallet addresses and the service onion.
    if docker compose ps >"$tmp/bundle/compose-ps.txt" 2>/dev/null; then
        local svc
        for svc in $(docker compose ps --all --format '{{.Service}}' 2>/dev/null); do
            docker compose logs --no-color --tail 200 "$svc" 2>/dev/null |
                bundle_redact_log >"$tmp/bundle/logs/$svc.log" || true
        done
    else
        echo "container engine not reachable — no container state collected" >"$tmp/bundle/compose-ps.txt"
    fi

    tar -czf "$out" -C "$tmp" bundle
    chmod 600 "$out"
    rm -rf "$tmp"
    log "Support bundle written: $out"
    log "Secrets are redacted at collection, but REVIEW the contents before sharing: tar -tzf $(basename "$out")"
}

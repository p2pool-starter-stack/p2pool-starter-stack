# --- Backup / Restore ---
# Protect the irreplaceable bits: config.json, .env (secrets), the Caddyfile, the Tor data dir
# (onion service keys), and the dashboard data dir (its DB never re-syncs). The blockchains do
# re-sync, so they're excluded by default; pass --with-chains to fold in Monero/Tari/P2Pool data.
#
# The two files a backup archive cannot be worth taking without (#1059/#1244): config.json and
# .env carry the node credentials and secrets, unlike every optional item stack_backup adds
# below them (Caddyfile, the Tor data dir, the dashboard dir all get a plain `[ -f ]`/`[ -d ]`
# guard already — these two didn't). Called BEFORE the disk-space check and before anything
# touches the running stack, so a refusal here leaves the box exactly as it was, the same
# promise the space check already makes. `-f` (not `-e`) so a symlink dangling at this instant
# refuses too, the same as one dangling at tar time would. A function, not inline, so it is
# testable at tier 1 without driving the whole backup flow.
backup_require_items() { # <item>...
    local _req
    for _req in "$@"; do
        [ -f "$_req" ] ||
            error "Backup needs $_req, and it is not there as a regular file (missing, or a symlink to nowhere) — nothing was touched. Run './pithead status' to check the install, or './pithead setup' if this box is unprovisioned."
    done
}

# Turns a tar failure into something the NEXT investigation can read straight off the log,
# instead of needing another bench boot before anyone can look (#1059/#1244: a genuine
# occurrence had config.json present and root-owned moments earlier, then unstattable at tar
# time — twice, across the #970 retry — on a guest that was recycled before the state could be
# inspected by hand). $1 = the directory tar's `-C` pointed at; the rest = the absolute item
# paths passed to it, so this prints exactly what an investigator would check by hand next.
backup_diagnose_items() { # <tar -C dir> <item>...
    local cwd="$1"
    shift
    warn "tar ran with -C \"$cwd\" against these resolved items:"
    local it
    for it in "$@"; do
        if [ -f "$it" ]; then
            warn "  present: $(ls -ld "$it" 2>&1)"
        elif [ -L "$it" ]; then
            warn "  DANGLING SYMLINK: $it -> $(readlink -f "$it" 2>&1)"
        elif [ -e "$it" ]; then
            warn "  present but not a regular file: $(ls -ld "$it" 2>&1)"
        else
            warn "  MISSING: $it"
        fi
    done
}

stack_backup() {
    local with_chains=0 assume_yes=0 was_running=0 no_encrypt=0
    for arg in "$@"; do
        case "$arg" in
        --with-chains) with_chains=1 ;;
        --no-encrypt) no_encrypt=1 ;;
        -y | --yes) assume_yes=1 ;;
        *) error "Unknown option for backup: $arg. Run '$0 help'." ;;
        esac
    done

    require_env
    parse_and_validate_config

    # Resolve the encryption passphrase up front, before anything is touched. The archive holds
    # the stack's full secret material (.env, onion private keys, the dashboard DB), and chmod 600
    # only protects it on this disk — so it's encrypted by default (#374). Plaintext needs an
    # explicit choice: --no-encrypt, or an empty passphrase at the interactive prompt (with a loud
    # warning — never a silent lockout of the operator's own onion keys). An UNATTENDED run
    # (--yes) with no passphrase refuses instead of downgrading: a cron job whose
    # PITHEAD_BACKUP_PASSPHRASE line is typo'd away must fail loudly, not archive the onion keys
    # in plaintext forever while reporting success.
    local pass=""
    { set +x; } 2>/dev/null # xtrace would print the passphrase below (see the prompt-path comment)
    if [ "$no_encrypt" -eq 0 ]; then
        if [ -n "${PITHEAD_BACKUP_PASSPHRASE:-}" ]; then
            pass="$PITHEAD_BACKUP_PASSPHRASE"
        elif [ "$assume_yes" -eq 1 ]; then
            error "No PITHEAD_BACKUP_PASSPHRASE set for an unattended backup — refusing to write a plaintext archive of your onion keys and secrets. Set the env var, or pass --no-encrypt to choose plaintext explicitly."
        else
            local pass2=""
            # Under `bash -x` (the on_err debugging advice) xtrace would print the passphrase in
            # every comparison and redirection below — turn it off for the rest of this run.
            { set +x; } 2>/dev/null
            read -rs -p "Backup passphrase (empty = plaintext archive): " pass || true
            echo
            if [ -n "$pass" ]; then
                read -rs -p "Confirm passphrase: " pass2 || true
                echo
                [ "$pass" = "$pass2" ] || error "Passphrases do not match — nothing was written."
            else
                warn "Empty passphrase — writing a PLAINTEXT archive. It holds your onion keys and secrets; anyone who reads it owns the stack."
            fi
        fi
    fi

    local backups_dir="$PWD/backups"
    mkdir -p "$backups_dir"

    local stamp archive
    stamp=$(date +%Y%m%d-%H%M%S)
    archive="$backups_dir/pithead-backup-$stamp.tar.gz"
    [ -z "$pass" ] || archive="$archive.enc"

    # Collect what exists, as absolute paths. We tar with -C / and strip the leading slash, so
    # restore (extract at /) puts every file back exactly where it came from regardless of where
    # config.json / the data dirs live. config.json/.env/Caddyfile sit in the script dir ($PWD).
    #
    # CONFIG_FILE (unlike ENV_FILE) is overridable — PITHEAD_CONFIG_FILE points a single
    # invocation at an absolute candidate path (the control gate's staged-config preview uses
    # it). A bare "$PWD/$CONFIG_FILE" concatenation is unsound exactly then: prefixing $PWD onto
    # an already-absolute path produces a doubled, non-existent path like
    # "/data/pithead//tmp/staged.json" that no file was ever going to be at. Not what #1059's
    # capture hit — that override was not in play there — but real whenever it is, so resolve it
    # the way every path join should: only prefix $PWD onto a RELATIVE candidate.
    local _cfg_path="$CONFIG_FILE"
    case "$_cfg_path" in /*) ;; *) _cfg_path="$PWD/$_cfg_path" ;; esac
    # Kept as its own array so the check can be REPEATED under the lock below. This one runs
    # before the passphrase and stop-the-stack prompts, and #1342's point is exactly that a
    # precondition checked outside mutual exclusion can be false again by the time it is used.
    local required=("$_cfg_path" "$PWD/$ENV_FILE")
    local items=("${required[@]}")
    backup_require_items "${required[@]}"
    [ -f "Caddyfile" ] && items+=("$PWD/Caddyfile")

    if [ -d "$TOR_DATA_DIR" ]; then
        items+=("$TOR_DATA_DIR")
    else
        warn "Tor data dir not found ($TOR_DATA_DIR) — onion keys will NOT be in the backup."
    fi

    # The dashboard's data dir holds its database (hashrate history & settings). It's small and
    # irreplaceable (it does NOT re-sync), so it always goes in the default backup, not behind
    # --with-chains.
    [ -d "$DASHBOARD_DIR" ] && items+=("$DASHBOARD_DIR")

    if [ "$with_chains" -eq 1 ]; then
        log "Including blockchain data (this can be very large)..."
        local d
        for d in "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR"; do
            [ -d "$d" ] && items+=("$d")
        done
    fi

    # Strip the leading "/" so paths are stored relative to / inside the archive.
    local rel=()
    local p
    for p in "${items[@]}"; do rel+=("${p#/}"); done

    # Disk-space pre-check — run BEFORE we touch the running stack, so a "not enough space"
    # answer leaves everything as it was. Blockchains (--with-chains) are largely incompressible,
    # so we assume the archive needs roughly the source size plus a ~5% safety margin.
    local need_kb avail_kb
    # sudo: the Tor data dir is owned by 100:101; -c gives a grand total across all items.
    # `|| true`: du exits non-zero if it can't read any descendant (a permission-denied subdir, a
    # file vanishing mid-walk, an NFS hiccup) even though 2>/dev/null hides the message and a total
    # is still printed. Without this, errexit (set -e) aborts the whole backup on a bare assignment,
    # making the graceful "proceeding without a space check" fallback below unreachable (#127).
    need_kb=$(sudo du -sck "${items[@]}" 2>/dev/null | awk 'END{print $1}') || true
    avail_kb=$(df -Pk "$backups_dir" 2>/dev/null | awk 'NR==2{print $4}') || true
    if [ -n "$need_kb" ] && [ -n "$avail_kb" ]; then
        if [ "$avail_kb" -lt "$((need_kb + need_kb / 20))" ]; then
            local avail_gib=$((avail_kb / 1048576)) need_gib=$((need_kb / 1048576))
            if [ "$assume_yes" -eq 1 ]; then
                warn "Low free space (~$avail_gib GiB free, ~$need_gib GiB needed) — backing up anyway (--yes)."
            else
                read -r -p "Low free space (~$avail_gib GiB free, ~$need_gib GiB needed). Back up anyway? (y/N): " CONFIRM || true
                if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
                    log "Backup cancelled — nothing was changed."
                    return
                fi
            fi
        fi
    else
        warn "Could not determine free disk space for the backup — proceeding without a space check."
    fi

    # A consistent backup needs the services stopped — otherwise files (especially the blockchain
    # DBs under --with-chains) can be archived mid-write. Detect a running stack and offer to stop
    # it for the duration of the backup, restarting afterwards. The docker check is best-effort:
    # if docker (or its daemon) is unavailable we treat the stack as not running and continue.
    # This runs AFTER the disk check so an aborted backup never leaves the stack stopped.
    local running=""
    if command -v docker >/dev/null 2>&1; then
        running=$(docker compose ps --status running -q 2>/dev/null)
    fi
    if [ -n "$running" ]; then
        log "A consistent backup needs the services stopped, so the archive isn't captured mid-write."
        log "The stack will be stopped during the backup and started again afterwards."
        if [ "$assume_yes" -eq 1 ]; then
            log "Stopping the stack for the backup (--yes)..."
        else
            read -r -p "Stop the stack, back up, then start it again? (y/N): " CONFIRM || true
            if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
                log "Backup cancelled — nothing was changed. Stop the stack first ($0 down) or re-run and choose to stop."
                return
            fi
        fi
        # AFTER both prompts (passphrase, and permission to stop the stack): the hold must not
        # span an unbounded human wait. It runs from here across stack_down -> tar -> stack_up,
        # so nothing can mutate config.json inside that span. Nested acquisition is a no-op, so
        # the stack_down/stack_up below take no second lock.
        mutation_lock_acquire backup
        # Re-checked under the lock and BEFORE anything is stopped, so a file that vanished while
        # the operator was at a prompt refuses here rather than failing tar with the stack already
        # down — the same blast-radius rule as #1244/#1248.
        backup_require_items "${required[@]}"
        was_running=1
        stack_down
    else
        # Stack already stopped: the same hold and the same re-check, still before tar.
        mutation_lock_acquire backup
        backup_require_items "${required[@]}"
    fi

    log "Creating backup archive..."
    # Read with sudo because the Tor data dir is owned by 100:101.
    #
    # One bounded retry (#970): even with the stack stopped, tar can lose a race against a
    # container teardown finishing its last flush or a startup that slipped past the running
    # snapshot above — "file changed as we read it" is exit 1 and pipefail fails the pipeline.
    # A second pass a few seconds later reads a quiet tree; failing twice is a real fault and
    # stays fatal. tar's own stderr is left on the terminal both times — the failing member's
    # name is the diagnosis.
    local _attempt _backup_ok=0
    for _attempt in 1 2; do
        if [ -n "$pass" ]; then
            # Stream tar straight into openssl so no plaintext archive ever exists on disk.
            # AES-256-CBC with PBKDF2 at 600k iterations — bare `openssl enc` would fall back
            # to a single round of EVP_BytesToKey. The passphrase travels over fd 3 (a pipe),
            # never argv (visible in `ps`) and never a file.
            if (umask 077 && sudo tar -czf - -C "/" "${rel[@]}" |
                openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
                    -pass fd:3 -out "$archive" 3< <(printf '%s' "$pass")); then
                _backup_ok=1
                break
            fi
        else
            if (umask 077 && sudo tar -czf "$archive" -C "/" "${rel[@]}"); then
                _backup_ok=1
                break
            fi
        fi
        # sudo tar itself opens $archive, so a failed run can still leave a root-owned partial
        # file behind — remove it rather than leave a corrupt archive that looks like a backup
        # (#551), on the retry exactly as on the way out.
        sudo rm -f "$archive"
        [ "$_attempt" -eq 1 ] && {
            warn "Backup attempt 1 failed — retrying once on a quiet tree..."
            sleep 5
        }
    done
    if [ "$_backup_ok" -ne 1 ]; then
        [ "$was_running" -eq 1 ] && stack_up
        backup_diagnose_items "/" "${items[@]}"
        error "Backup failed — the partial archive was removed."
    fi
    sudo chown "$REAL_USER":"$REAL_USER" "$archive"
    chmod 600 "$archive"

    log "Backup written to: $archive"
    if [ -n "$pass" ]; then
        log "The archive is useless without the passphrase — store it somewhere other than this host."
    fi
    if [ "$with_chains" -eq 0 ]; then
        log "Blockchains excluded (they re-sync). Use 'backup --with-chains' to include them."
    fi

    if [ "$was_running" -eq 1 ]; then
        stack_up
        log "Stack restarted after the backup."
    fi
    mutation_lock_release
}

stack_restore() {
    local assume_yes=0 archive="" arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        -*) error "Unknown option for restore: $arg. Run '$0 help'." ;;
        *) [ -n "$archive" ] || archive="$arg" ;;
        esac
    done

    [ -n "$archive" ] || error "Usage: $0 restore [-y|--yes] <archive.tar.gz[.enc]>"
    [ -f "$archive" ] || error "Archive not found: $archive"
    # Resolve to an absolute path now, since we extract from "/" below.
    archive=$(cd "$(dirname "$archive")" && printf '%s/%s' "$PWD" "$(basename "$archive")")

    # Detect the format by magic bytes, not by flag or filename: `Salted__` is an openssl-encrypted
    # archive (the default since #374), gzip magic is a plaintext archive from any earlier release —
    # both keep restoring with the same command. Anything else is refused before the confirm prompt.
    local magic encrypted=0
    magic=$(head -c 8 "$archive" | od -An -tx1 | tr -d ' \n')
    case "$magic" in
    53616c7465645f5f) encrypted=1 ;; # "Salted__"
    1f8b*) ;;                        # gzip
    *) error "Not a pithead backup archive (neither openssl-encrypted nor gzip): $archive" ;;
    esac

    # Note: we do NOT require/parse the current config here — restore must work even when the
    # on-disk config.json is lost or corrupt. The config comes back out of the archive.

    warn "Restore will OVERWRITE config.json, .env, Caddyfile, the Tor data dir, and the dashboard's database from the archive."
    warn "Stop the stack first with '$0 down' so files are restored in a consistent state."
    if [ "$assume_yes" -eq 0 ]; then
        read -r -p "Continue and overwrite these files? (y/N): " CONFIRM || true
        if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
            log "Restore cancelled."
            return
        fi
    fi

    local pass=""
    if [ "$encrypted" -eq 1 ]; then
        { set +x; } 2>/dev/null # xtrace would print the passphrase in the checks below
        if [ -n "${PITHEAD_BACKUP_PASSPHRASE:-}" ]; then
            pass="$PITHEAD_BACKUP_PASSPHRASE"
        else
            read -rs -p "Backup passphrase: " pass || true
            echo
        fi
        [ -n "$pass" ] || error "This archive is encrypted — supply the passphrase (prompt or PITHEAD_BACKUP_PASSPHRASE)."
        # Pre-flight: decrypt only the first bytes and check for the gzip magic, so a wrong
        # passphrase fails HERE, before tar writes anything to /. `head -c 2` closes the pipe
        # early, so openssl stops after the first blocks (pipefail makes that exit 141 — hence
        # the `|| true`); we judge by the decrypted bytes, not the exit code.
        local plain_magic
        plain_magic=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
            -pass fd:3 -in "$archive" 2>/dev/null 3< <(printf '%s' "$pass") |
            head -c 2 | od -An -tx1 | tr -d ' \n') || true
        [ "$plain_magic" = "1f8b" ] || error "Wrong passphrase or corrupt archive — nothing was restored."
        # Full-stream verify BEFORE extraction: CBC has no authentication, so a bit-flip or
        # truncation past the first block would pass the magic check yet abort tar MID-EXTRACTION,
        # leaving the live config half-overwritten. Listing the whole archive (`tar -tzf -`, still
        # no plaintext on disk) decompresses and walks every member — catching a corrupt/tampered
        # tail — and, unlike `gzip -t`, tolerates tar's own zero-padding. A failure here refuses
        # before anything is touched.
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
            -pass fd:3 -in "$archive" 2>/dev/null 3< <(printf '%s' "$pass") |
            tar -tzf - >/dev/null 2>&1 ||
            error "Archive fails integrity verification (tampered or truncated) — nothing was restored."
    else
        # Same full-stream verify as the encrypted branch above, minus the decrypt step: a
        # truncated/corrupt plaintext archive would otherwise abort tar MID-EXTRACTION, leaving
        # the live config half-overwritten (#549).
        tar -tzf "$archive" >/dev/null 2>&1 ||
            error "Archive fails integrity verification (tampered or truncated) — nothing was restored."
    fi

    # After the confirm and the passphrase prompt, and after the integrity verify (read-only):
    # the extraction below is the mutating window.
    mutation_lock_acquire restore
    log "Restoring from $archive ..."
    # The archive stores paths relative to / (leading slash stripped), so extracting at / puts
    # every file back exactly where it came from. sudo so we can write into the 100:101-owned
    # Tor data dir. The encrypted path streams openssl into tar — no plaintext archive on disk.
    if [ "$encrypted" -eq 1 ]; then
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
            -pass fd:3 -in "$archive" 3< <(printf '%s' "$pass") |
            sudo tar -xzf - -C "/"
    else
        sudo tar -xzf "$archive" -C "/"
    fi

    # Now that config.json is back, resolve the Tor data dir from it and fix ownership so the
    # onion keys load (matching prepare_directories).
    parse_and_validate_config
    log "Fixing Tor data ownership (100:101)..."
    sudo chown -R 100:101 "$TOR_DATA_DIR"
    # The archive is extracted as root, so the restored dashboard DB (and any --with-chains data)
    # comes back root-owned. The containers run non-root (#255), so hand each data dir back to the
    # uid its container uses — conditional, so a same-owner archive is a no-op.
    ensure_owner "$MONERO_DIR" "$APP_UID" "$APP_GID"
    ensure_owner "$TARI_DIR" "$APP_UID" "$APP_GID"
    ensure_owner "$P2POOL_DIR" "$APP_UID" "$APP_GID"
    ensure_owner "$DASHBOARD_DIR" "$APP_UID" "$APP_GID"

    log "Restore complete. Start the stack with '$0 up'."
    mutation_lock_release
}

# Consume a restore-at-setup submission (#909, #786 sub-issue B): an uploaded encrypted backup
# archive + its emergency-kit passphrase, in place of the config form. Same decrypt/verify
# machinery as `stack_restore` (magic-byte format check, full-stream integrity verify BEFORE
# anything is touched), but staged through a COPY like consume_preseed_config — the exact
# validate-through-a-copy idiom this codebase already uses for "never mutate real state until
# accepted" — because a wizard-time restore must be able to fail clean and fall back to the
# form, not leave a half-restored Tor identity or dashboard database behind for a follow-up
# manual submit to inherit. rc: 0 landed (config.json + $spool/applied, identical to a typed
# submission — the caller falls into the SAME accept path), 1 rejected (error.txt written), 2
# none. The passphrase is read once and deleted immediately either way — it never outlives
# this call.
# Where an installer boot parks an ACCEPTED restore for the carry to the target's ESP —
# root-only tmpfs, gone at power-off, never mounted into any container. Overridable so the
# shell suite can run this without root's /run.
restore_carry_dir() { printf '%s' "${PITHEAD_RESTORE_CARRY_DIR:-/run/pithead-restore}"; }

# The whole restore acceptance, shared by its two doors — the wizard's spool channel
# (firstboot_consume_restore) and the installer-carried ESP pre-seed (consume_preseed_restore):
# size cap, encryption detection, decrypt verification, tar integrity, path-safety audit,
# extract-and-validate through a staging copy, then commit. One set of checks, two doors.
# With <config-only-dest> set, the validated config is copied there and NOTHING ELSE touches
# this machine — the installer flow, where the restored tree belongs to the TARGET and
# decrypted keys must never rest on the stick. rc 0: done. rc 1: refused, one page-ready
# line in <errfile>. Never deletes <archive> — the callers own their files.
restore_apply() { # <archive> <passphrase> <errfile> [<config-only-dest>]
    local archive="$1" pass="$2" errf="$3" cfg_dest="${4:-}"
    local size magic encrypted=0 tmp staged_cfg err

    # Server-side cap already refused an oversize upload before it reached the spool; checked
    # again here so a file dropped by any other means gets the same honest refusal.
    size=$(wc -c <"$archive" 2>/dev/null || echo 0)
    if [ "$size" -gt "$RESTORE_MAX_BYTES" ]; then
        printf 'backup archive is too large (max %s MB) — a Pithead backup holds only config, keys and the dashboard database, never the blockchains' "$((RESTORE_MAX_BYTES / 1048576))" >"$errf"
        return 1
    fi

    magic=$(head -c 8 "$archive" | od -An -tx1 | tr -d ' \n')
    case "$magic" in
    53616c7465645f5f) encrypted=1 ;; # "Salted__"
    1f8b*) ;;                        # gzip
    *)
        printf 'not a Pithead backup archive' >"$errf"
        return 1
        ;;
    esac

    if [ "$encrypted" -eq 1 ]; then
        if [ -z "$pass" ]; then
            printf 'this archive is encrypted — enter its passphrase' >"$errf"
            return 1
        fi
        local plain_magic
        plain_magic=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
            -pass fd:3 -in "$archive" 2>/dev/null 3< <(printf '%s' "$pass") |
            head -c 2 | od -An -tx1 | tr -d ' \n') || true
        if [ "$plain_magic" != "1f8b" ]; then
            printf 'wrong passphrase or corrupt archive' >"$errf"
            return 1
        fi
        if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
            -pass fd:3 -in "$archive" 2>/dev/null 3< <(printf '%s' "$pass") |
            tar -tzf - >/dev/null 2>&1; then
            printf 'archive fails integrity verification (tampered or truncated)' >"$errf"
            return 1
        fi
    else
        if ! tar -tzf "$archive" >/dev/null 2>&1; then
            printf 'archive fails integrity verification (tampered or truncated)' >"$errf"
            return 1
        fi
    fi

    # Path-safety audit BEFORE staging: the accepted tree is copied to "/" below, so a member with
    # an absolute path, a ".." component, or a symlink/hardlink could write outside the restore
    # set (a symlink extracted first, then written through). Modern tar refuses these, but the
    # destination is the filesystem root — do not trust the tar version. A Pithead backup carries
    # only regular files and dirs under known prefixes, so any escaping path or link is corruption
    # or an attack: fail closed. Lists names (whole-line, absolute/".." check) and the verbose
    # form (link check) separately, because a name with spaces is unparseable from `tar -tv`.
    local rnames rlinks
    if [ "$encrypted" -eq 1 ]; then
        rnames=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass fd:3 -in "$archive" 2>/dev/null 3< <(printf '%s' "$pass") | tar -tz 2>/dev/null)
        rlinks=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass fd:3 -in "$archive" 2>/dev/null 3< <(printf '%s' "$pass") | tar -tvz 2>/dev/null)
    else
        rnames=$(tar -tzf "$archive" 2>/dev/null)
        rlinks=$(tar -tvzf "$archive" 2>/dev/null)
    fi
    if printf '%s\n' "$rnames" | grep -qE '^/|(^|/)\.\.(/|$)' ||
        printf '%s\n' "$rlinks" | grep -qE '^l| -> | link to '; then
        printf 'archive contains unsafe paths or links — refusing to restore' >"$errf"
        return 1
    fi

    tmp=$(mktemp -d) || {
        printf 'could not stage the restore' >"$errf"
        return 1
    }
    if [ "$encrypted" -eq 1 ]; then
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
            -pass fd:3 -in "$archive" 2>/dev/null 3< <(printf '%s' "$pass") | tar -xzf - -C "$tmp"
    else
        tar -xzf "$archive" -C "$tmp"
    fi

    # The archive stores paths relative to "/" (same convention `stack_backup`/`stack_restore`
    # use), so the staged config lands at exactly $PWD/$CONFIG_FILE underneath $tmp.
    staged_cfg="$tmp/${PWD#/}/$CONFIG_FILE"
    if [ ! -f "$staged_cfg" ] || ! jq -e . "$staged_cfg" >/dev/null 2>&1; then
        rm -rf "$tmp"
        printf 'archive does not contain a usable configuration' >"$errf"
        return 1
    fi
    # Validated through the COPY — parse_and_validate_config fills in generated fields as it
    # goes (consume_preseed_config's own reasoning), and only a config that survives this is
    # ever promoted to the real config.json.
    if ! err=$(PITHEAD_CONFIG_FILE="$staged_cfg" bash -c "source '${BASH_SOURCE[0]}' && parse_and_validate_config" 2>&1); then
        rm -rf "$tmp"
        printf '%s' "$err" | tail -n 2 | tr -d '[:cntrl:]' | tail -c 240 >"$errf"
        return 1
    fi

    if [ -n "$cfg_dest" ]; then
        # Installer door: the card and the ESP staging need the config; the tree stays in the
        # archive for the target to restore itself.
        install -m 600 "$staged_cfg" "$cfg_dest"
        rm -rf "$tmp"
        return 0
    fi
    # Commit: everything the archive carried (config.json, .env, Caddyfile, the Tor data dir,
    # the dashboard database) lands at its real absolute path in one move — the same
    # destination `tar -xzf archive -C /` would use directly, just proven safe first.
    # prepare_directories (run by the `setup` this feeds) unconditionally re-chowns every data
    # dir afterwards, so ownership here does not need fixing up by hand.
    cp -a "$tmp"/. /
    rm -rf "$tmp"
    # #1239 (live KVM guest evidence): the archive's .env is the SOURCE machine's own —
    # DEPLOYMENT_COMPLETED=true there records THAT machine's prior deployment, not this
    # hardware's. Both doors that reach here feed straight into a headless `setup()`
    # (firstboot's spool-accept path, the ESP pre-seed door consumed at boot): setup()'s
    # is_deployed guard exists to stop an operator re-running setup on a box that is already
    # live (#924), and it has no way to tell "restored, never provisioned HERE" apart from
    # "live" — a carried true fires that guard's exact fatal, no-tty refusal, and setup never
    # runs: prepare_directories, render_env, provision_tor never fire, no container starts. A
    # just-restored box has NOT completed deployment on this hardware — clear the marker so the
    # caller's setup() actually provisions it. Every other restored .env value (the real onion
    # addresses, tokens, HOST_IP) is exactly what a re-provision must reuse, so only this one
    # line is touched; a full re-render happens anyway inside setup(). Scoped to THIS commit
    # path on purpose — stack_restore (the admin `./pithead restore` command, for a box already
    # deployed on its own hardware) has its own separate extraction and never calls restore_apply,
    # so a live box's restore keeps its completion marker exactly as it should.
    if [ -f "$PWD/$ENV_FILE" ]; then
        safe_sed 's/^DEPLOYMENT_COMPLETED=.*/DEPLOYMENT_COMPLETED=false/' "$PWD/$ENV_FILE"
    fi
    return 0
}

firstboot_consume_restore() { # <spool-dir> [<installer 0|1>]
    local spool="$1" installer="${2:-0}" archive="$1/restore-archive" passfile="$1/restore-passphrase"
    local pass=""
    [ -f "$archive" ] || return 2
    { set +x; } 2>/dev/null # xtrace would print the passphrase below
    pass=$(cat "$passfile" 2>/dev/null || true)
    rm -f "$passfile" # never persisted in the spool beyond this attempt, accepted or not

    if [ "$installer" -eq 1 ]; then
        # Installer boot: validate and surface the config for the card, but the restored TREE
        # belongs to the TARGET — decrypted keys must never rest on the stick. The accepted
        # archive and its passphrase park in tmpfs for the ESP carry the install branch stages.
        if ! restore_apply "$archive" "$pass" "$spool/error.txt" "$PWD/config.json"; then
            pass=""
            rm -f "$archive"
            return 1
        fi
        local carry
        carry=$(restore_carry_dir)
        (umask 077 && mkdir -p "$carry" &&
            mv "$archive" "$carry/archive" &&
            printf '%s' "$pass" >"$carry/pass") || {
            pass=""
            printf 'could not stage the restore for the install' >"$spool/error.txt"
            rm -rf "$carry" "$archive" "$PWD/config.json"
            return 1
        }
        pass=""
        touch "$spool/applied"
        return 0
    fi
    local rrc=0
    restore_apply "$archive" "$pass" "$spool/error.txt" || rrc=1
    pass=""
    rm -f "$archive"
    [ "$rrc" -eq 0 ] || return 1
    touch "$spool/applied"
    return 0
}

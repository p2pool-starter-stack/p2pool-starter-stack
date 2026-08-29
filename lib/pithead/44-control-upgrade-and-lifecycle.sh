# True when SemVer $1 is strictly newer than $2 (either may carry a leading `v`). Both arguments
# are shape-checked (vX.Y.Z) before the call. Pure bash/awk — macOS sort has no -V.
semver_newer() {
    local a b
    a=$(printf '%s' "${1#v}" | awk -F. '{printf "%d%05d%05d",$1,$2,$3}')
    b=$(printf '%s' "${2#v}" | awk -F. '{printf "%d%05d%05d",$1,$2,$3}')
    [ "$a" -gt "$b" ]
}

# Upgrade the install to the latest published release (#59). The container only PROPOSES ("the
# operator confirmed vX.Y.Z"); this host side re-derives the target itself: it asks the GitHub
# release API — over the stack's own Tor SOCKS, like every other stack egress — for the latest
# tag, refuses unless the proposed version matches that tag exactly AND the tag is strictly newer
# than the running VERSION, then downloads the release bundle for the HOST-derived tag and runs
# `pithead upgrade`: the same two steps docs/operations.md documents for a manual update. No
# container string ever reaches a command line or URL — the proposed version is shape-checked and
# used only in an equality comparison, so a container-supplied tag/registry cannot steer what is
# installed (the image-swap RCE the #33 review closed). Source checkouts are refused: their
# update is `git pull`, a judgment the operator makes at a shell. One attempt per 10 minutes,
# so a compromised container cannot use the root runner as an egress beacon or grind GitHub.
control_upgrade() { # <request-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    _upg_reject() { # <reason> — refuse before anything changed on the host
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$1" '{status:"rejected",error:$e,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "rejected"
    }
    _upg_fail() { # <reason> — the attempt started and did not finish
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$1" '{status:"failed",error:$e,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "failed"
    }
    if is_source_checkout; then
        _upg_reject "this install builds from source — upgrade from the host with 'git pull' then './pithead upgrade'."
        return 0
    fi
    # Ordered BEFORE the cosign precondition on purpose: an appliance cannot take a tarball
    # upgrade at all, whatever the host holds, so the appliance answer is the informative one.
    if is_appliance; then
        _upg_reject "this machine is a Pithead OS appliance — it updates through signed OS images, not release tarballs, and a tarball upgrade would silently revert at the next reboot. Use the OS update control in the dashboard header; nothing was changed."
        return 0
    fi
    # #376/#1023: the verifier is a PRECONDITION of a one-click upgrade, not a consequence of already
    # holding a key. Every release bundle ships cosign.pub (make_bundle copies the committed key
    # unconditionally), so the `pithead upgrade` this runner ends up calling will demand the
    # verifier at its image gate whatever the current install holds. Testing the LOCAL cosign.pub
    # instead — what this guard used to do — was blind to the one upgrade that needs it most: an
    # install cut before signing engaged moving to a signed release, which every fielded install
    # makes exactly once. That sailed past here and aborted inside the new CLI, after the download,
    # the extraction, and a full config re-render. Since #1072 the verifier is a container, so this
    # can only fail on a box whose docker is gone — which would also mean nothing is mining. Kept
    # anyway: checked with the source-checkout refusal above, both are "this install cannot take a
    # one-click upgrade at all", and neither claims the throttle or dials out, so a refusal here
    # costs the operator nothing.
    if ! cosign_available; then
        _upg_reject "docker is not available to run the release verifier — every image is verified against the shipped signing key before it is pulled, so this upgrade would fail partway through. Check the Docker daemon and retry."
        return 0
    fi
    # Throttle: one attempt per 10 minutes, checked before any network dial.
    local stamp="$cdir/staged/.upgrade-stamp"
    if [ -n "$(find "$stamp" -mmin -10 2>/dev/null)" ]; then
        _upg_reject "an upgrade was attempted less than 10 minutes ago — wait for it to finish, then retry."
        return 0
    fi
    # The proposed version must LOOK like a release tag before it is even compared.
    local proposed
    proposed=$(jq -r '.version // ""' "$file")
    if ! printf '%s' "$proposed" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        _upg_reject "malformed or missing 'version' in the upgrade request."
        return 0
    fi
    if [ -z "${PITHEAD_VERSION:-}" ]; then
        _upg_reject "cannot determine the running version (VERSION file missing) — upgrade from the host."
        return 0
    fi
    # Claim the throttle now — BEFORE the network dial — so every well-formed attempt costs the
    # 10-minute window, even one that will be rejected as non-latest. Otherwise a compromised
    # container floods well-formed-but-stale version intents and turns the root runner into an
    # unthrottled GitHub-API / Tor-egress beacon (each fails only at the proposed!=tag check, past
    # the dial). A genuine probe that fails to reach GitHub costing the operator a 10-minute wait
    # is the right trade.
    touch "$stamp"
    # Host-side re-derivation of the target: the latest tag according to GitHub, not the request.
    local rel tag
    if ! gh_release_fetch p2pool-starter-stack/pithead; then
        _upg_reject "$GH_RELEASE_HINT"
        return 0
    fi
    rel=$GH_RELEASE_JSON
    tag=$(printf '%s' "$rel" | jq -r '.tag_name // ""' 2>/dev/null)
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        _upg_reject "the GitHub release API returned no usable release tag — nothing was changed."
        return 0
    fi
    if [ "$proposed" != "$tag" ]; then
        _upg_reject "requested version $proposed is not the latest published release ($tag) — reload the dashboard and retry."
        return 0
    fi
    if ! semver_newer "$tag" "v$PITHEAD_VERSION"; then
        _upg_reject "already up to date (running v$PITHEAD_VERSION; latest release is $tag)."
        return 0
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" '{status:"running",version:$v,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "started"
    # Bundle URL built from the HOST-derived tag only; fetched over the same Tor SOCKS.
    local bundle="$cdir/staged/.$id.tar.gz" logf="$cdir/staged/.$id.log"
    if ! curl -fsSL --max-time 900 --max-filesize "$CURL_CAP_BUNDLE" --socks5-hostname "$GH_SOCKS" -o "$bundle" \
        "https://github.com/p2pool-starter-stack/pithead/releases/download/$tag/pithead.tar.gz" 2>/dev/null; then
        rm -f "$bundle"
        _upg_fail "could not download the $tag release bundle over Tor — the stack keeps running v$PITHEAD_VERSION."
        return 0
    fi
    # #376: verify the bundle against the cosign.pub ALREADY on disk before a byte of it is
    # extracted. The new bundle ships its own cosign.pub, but a key that arrives inside the
    # artifact it vouches for proves nothing — trust anchors at the key installed with the
    # release this host already runs. No local key (an older install) keeps today's behaviour —
    # TLS to GitHub plus tag pinning — with one loud line in the journal.
    if [ -f cosign.pub ]; then
        local sig="$cdir/staged/.$id.tar.gz.sig"
        if ! curl -fsSL --max-time 120 --max-filesize "$CURL_CAP_SMALL" --socks5-hostname "$GH_SOCKS" -o "$sig" \
            "https://github.com/p2pool-starter-stack/pithead/releases/download/$tag/pithead.tar.gz.sig" 2>/dev/null; then
            rm -f "$bundle" "$sig"
            _upg_fail "the $tag release carries no bundle signature (pithead.tar.gz.sig) — refusing to install it unverified; the stack keeps running v$PITHEAD_VERSION."
            return 0
        fi
        # The verifier is a container that sees the install dir at /w (#1072), so it needs the two
        # staged files named as IT sees them. Translated with a guard rather than a blind prefix
        # strip: a path that fell outside the mount would make cosign fail to open the file, and
        # this call reports any failure as "signature FAILED" — a mount bug must not be able to
        # masquerade as a tampered download and burn a legitimate release.
        local cbundle csig
        if ! cbundle=$(cosign_container_path "$bundle") || ! csig=$(cosign_container_path "$sig"); then
            rm -f "$bundle" "$sig"
            _upg_fail "the staged $tag bundle landed outside the install dir, where the release verifier cannot read it — refusing to install it unverified. The stack keeps running v$PITHEAD_VERSION."
            return 0
        fi
        if ! cosign_run verify-blob --key cosign.pub --signature "$csig" --insecure-ignore-tlog=true "$cbundle" >/dev/null 2>&1; then
            rm -f "$bundle" "$sig"
            _upg_fail "bundle signature verification FAILED for $tag — the download does not match the release key; refusing to extract it. The stack keeps running v$PITHEAD_VERSION."
            return 0
        fi
        rm -f "$sig"
    else
        warn "No cosign.pub next to pithead — bundle authenticity rests on TLS to GitHub plus tag pinning only."
    fi
    # Rollback guard (#376): a cosign signature binds BYTES, not a version — an attacker who
    # controls the release response could serve an OLDER genuinely-signed bundle at the $tag URL
    # and silently downgrade the stack to a patched-vulnerable version, and the signature would
    # still verify. Refuse unless the bundle's own top-level VERSION matches the host-derived
    # $tag, read WITHOUT extracting (the bundle unpacks to a fixed `pithead/` dir) so a mismatch
    # touches nothing on disk.
    # #548: the extraction above is a plain assignment, so under errexit a tar failure (a bundle
    # missing pithead/VERSION — corrupt download or a hostile non-pithead archive) would kill the
    # runner outright instead of reaching _upg_fail below, leaving this result stuck at "running"
    # and the claim never released. Guard it like every other dial/extract in this function.
    local bundle_version
    if ! bundle_version=$(tar -xzOf "$bundle" pithead/VERSION 2>/dev/null | tr -d '[:space:]') ||
        [ -z "$bundle_version" ]; then
        rm -f "$bundle"
        _upg_fail "the $tag bundle is missing pithead/VERSION (corrupt or not a pithead bundle) — refusing to install it. The stack keeps running v$PITHEAD_VERSION."
        return 0
    fi
    if [ "v$bundle_version" != "$tag" ]; then
        rm -f "$bundle"
        _upg_fail "the $tag download actually contains version ${bundle_version:-unknown} — refusing a version-mismatched (possible rollback) release. The stack keeps running v$PITHEAD_VERSION."
        return 0
    fi
    # #629: pick the extraction target. A versioned install (pithead-vX.Y.Z dir) whose data dirs
    # all resolve OUTSIDE the install dir gets the documented bundle-deploy layout
    # (docs/operations.md § A recommended layout): extract into a fresh sibling pithead-<tag>/,
    # seed the operator's config + the install-local state, and run the NEW dir's upgrade — on
    # success its update_current_symlink repoints `current`, and this dir survives untouched as
    # the rollback copy. Anything else falls back to the historical in-place extraction: a plain
    # `pithead/` extract has no versioned layout to maintain, and data living under this dir
    # (the pre-#455 default) would be stranded by a dir swap — the new render would re-derive
    # its default paths under the NEW dir and the stack would come up beside its own data.
    local new_dir="" cwd
    cwd=$(pwd -P) # physical path: the guard below compares canonicalized values on BOTH sides
    if is_versioned_install_dir "$cwd"; then
        new_dir="$(dirname "$cwd")/pithead-$tag"
        local dvar dval
        for dvar in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR TOR_DATA_DIR DASHBOARD_DATA_DIR; do
            dval=$(env_get "$dvar")
            [ -n "$dval" ] || continue
            # Canonicalize: the .env value may reach the same place through the `current` symlink.
            dval=$( (cd "$dval" 2>/dev/null && pwd -P) || printf '%s' "$dval")
            case "$dval" in
            "$cwd" | "$cwd"/*)
                warn "$dvar resolves inside the install dir — upgrading in place; move the data to a shared root outside the version dir to get per-version rollback dirs."
                new_dir=""
                break
                ;;
            esac
        done
    fi
    # Atomic create, no -p and no pre-check: root must never extract into (or follow a symlink
    # planted at) a path some other local account pre-created — mkdir fails on ANY existing
    # entry, closing the check-to-use race outright (#629 security review). A leftover dir from
    # an earlier failed attempt therefore also lands here: fall back to in-place and say why.
    if [ -n "$new_dir" ] && ! mkdir "$new_dir" 2>/dev/null; then
        warn "$new_dir already exists (a previous attempt, or not ours to create) — upgrading in place. Remove it to get the fresh-dir layout back."
        new_dir=""
    fi
    if [ -n "$new_dir" ]; then
        # Fresh-dir deploy (#629). Plain tar throughout: nothing in $new_dir is running.
        if ! tar -xzf "$bundle" --strip-components=1 -C "$new_dir" 2>"$logf"; then
            rm -f "$bundle"
            _upg_fail "could not extract the $tag bundle into $new_dir: $(tail -c 500 "$logf") — the running install is untouched; the stack keeps running v$PITHEAD_VERSION."
            rm -f "$logf"
            return 0
        fi
        rm -f "$bundle"
        # Seed what only the running install has: the operator's config, the rendered .env
        # (preserved secrets — onions, RPC creds; cp -p keeps it 0600), and the install-local
        # state dirs — the control spool (so the audit trail and results history carry over,
        # and the result written below is visible to the RECREATED dashboard, which mounts the
        # new dir's spool), the clearnet sync markers, and the caddy access log. Chain and
        # dashboard data live outside this dir (guarded above) and carry over by path.
        local sdir
        if ! cp -p "$CONFIG_FILE" "$new_dir/config.json" 2>"$logf" ||
            ! cp -p "$ENV_FILE" "$new_dir/.env" 2>>"$logf" ||
            ! mkdir -p "$new_dir/data" 2>>"$logf"; then
            _upg_fail "could not seed config into $new_dir: $(tail -c 500 "$logf") — the running install is untouched; the stack keeps running v$PITHEAD_VERSION."
            rm -f "$logf"
            return 0
        fi
        for sdir in control clearnet-state caddy-logs; do
            [ -d "$PWD/data/$sdir" ] || continue
            if ! cp -a "$PWD/data/$sdir" "$new_dir/data/" 2>"$logf"; then
                _upg_fail "could not carry data/$sdir over to $new_dir: $(tail -c 500 "$logf") — the running install is untouched; the stack keeps running v$PITHEAD_VERSION."
                rm -f "$logf"
                return 0
            fi
        done
        # Run the NEW release's upgrade from the NEW dir: it re-renders the generated config
        # (recomputing every $PWD-derived path, including CONTROL_DIR), re-provisions the
        # control-runner units onto the new path, pulls the $tag images, and repoints
        # `current ->` on success. The outcome goes to BOTH spools: the recreated dashboard
        # mounts the new one, a failure before the recreate is read from the old one.
        # #637: this dir — untouched by the whole deploy — is the restore point; name it in the
        # result so the operator learns it exists without reading docs/operations.md first.
        local rdir
        if (cd "$new_dir" && ./pithead upgrade) >"$logf" 2>&1; then
            for rdir in "$cdir" "$new_dir/data/control"; do
                control_write_result "$rdir/results" "$id" "$(jq -n --arg v "$tag" --arg r "$cwd" '{status:"upgraded",version:$v,rollback:$r,ts:(now|floor)}')"
                control_audit "$rdir/audit/control.log" "$id" "$actor" "upgrade" "upgraded"
            done
        else
            for rdir in "$cdir" "$new_dir/data/control"; do
                control_write_result "$rdir/results" "$id" "$(jq -n --arg v "$tag" --arg e "$(tail -c 2000 "$logf")" --arg d "$new_dir" --arg r "$cwd" \
                    '{status:"failed",version:$v,rollback:$r,error:($e + " — finish the upgrade from the host: cd " + $d + " && ./pithead upgrade; containers not yet recreated keep running the previous images."),ts:(now|floor)}')"
                control_audit "$rdir/audit/control.log" "$id" "$actor" "upgrade" "failed"
            done
        fi
        rm -f "$logf"
        return 0
    fi
    # #637: unlike the fresh-dir path, this one has no surviving previous dir — and the new
    # release's `upgrade` below re-renders .env (and may migrate config.json). Keep a timestamped
    # pre-upgrade copy of both next to the originals before a byte changes (cp -p keeps .env's
    # 0600; a fresh stamp per attempt so a failed try never overwrites the good copy) and refuse
    # to overwrite the install without one. The destination name is predictable, so root must
    # never write through a symlink a co-tenant planted there (the #629 mkdir guard's attack
    # class): copy to an unpredictable mktemp name first, then rename onto the final name —
    # rename(2) replaces a planted entry without following it.
    _upg_snapshot() { # <src> <dst>
        local tmp
        tmp=$(mktemp "$PWD/.bak-upgrade.XXXXXX") || return 1
        if ! cp -p "$1" "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        mv -f "$tmp" "$2"
    }
    local bak
    bak="bak-upgrade-$(date +%Y%m%d-%H%M%S)"
    if ! _upg_snapshot "$CONFIG_FILE" "$CONFIG_FILE.$bak" 2>"$logf" ||
        ! _upg_snapshot "$ENV_FILE" "$ENV_FILE.$bak" 2>>"$logf"; then
        rm -f "$bundle"
        _upg_fail "could not keep a pre-upgrade copy of config.json/.env: $(tail -c 500 "$logf") — refusing to overwrite the install without a restore point; the stack keeps running v$PITHEAD_VERSION."
        rm -f "$logf"
        return 0
    fi
    # Older snapshots hold yesterday's secrets: keep the newest three pairs, prune the rest.
    # Lexical order IS chronological for this stamp format; `|| true` — an empty glob under
    # pipefail must not kill the runner.
    ls -1r "$CONFIG_FILE".bak-upgrade-* 2>/dev/null | tail -n +4 | while IFS= read -r f; do rm -f "$f"; done || true
    ls -1r "$ENV_FILE".bak-upgrade-* 2>/dev/null | tail -n +4 | while IFS= read -r f; do rm -f "$f"; done || true
    # The reported paths: CONFIG_FILE is cwd-relative unless the (test-only) override made it
    # absolute — don't prepend $PWD onto an already-absolute path.
    local bak_paths
    case "$CONFIG_FILE" in
    /*) bak_paths="$CONFIG_FILE.$bak" ;;
    *) bak_paths="$PWD/$CONFIG_FILE.$bak" ;;
    esac
    bak_paths="$bak_paths $PWD/$ENV_FILE.$bak"
    # In-place extraction over the running install, in two passes. Pass 1 lays down everything
    # EXCEPT the running script with plain tar, which MERGES existing directories — a release
    # install already carries the non-empty build/* config-template mounts — and overwrites files.
    # A single `-U` (unlink-first) pass over the whole tree instead tries to unlink those non-empty
    # build/* dirs first and aborts ("Cannot unlink: Directory not empty"), leaving the install
    # half-written. Pass 2 is the ONE file that needs -U: the pithead script, unlinked-first so it
    # lands on a NEW inode and the copy executing this very function keeps running from the old one
    # (an in-place overwrite would corrupt it mid-run).
    if ! tar -xzf "$bundle" --strip-components=1 -C "$PWD" --exclude='pithead/pithead' 2>"$logf" ||
        ! tar -xzUf "$bundle" --strip-components=1 -C "$PWD" pithead/pithead 2>>"$logf"; then
        rm -f "$bundle"
        _upg_fail "the $tag release bundle failed to extract: $(tail -c 500 "$logf") — the stack keeps running v$PITHEAD_VERSION."
        rm -f "$logf"
        return 0
    fi
    rm -f "$bundle"
    # The extraction replaced this script on disk (the running copy keeps executing from its old
    # inode); run the NEW pithead's `upgrade`, which re-renders the generated config and pulls the
    # $tag images — exactly what the manual bundle update does.
    if "$PWD/pithead" upgrade >"$logf" 2>&1; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" '{status:"upgraded",version:$v,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "upgraded"
    else
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --arg e "$(tail -c 2000 "$logf")" \
            --arg b "$bak_paths" \
            '{status:"failed",version:$v,backup:$b,error:($e + " — finish the upgrade from the host with ./pithead upgrade; containers not yet recreated keep running the previous images."),ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "failed"
    fi
    rm -f "$logf"
}

# Validate + dispatch one CLAIMED request file. Trusts no byte of it: must be JSON, only the keys
# id/action/config/actor/version, the id must be a UUID (it becomes the result/staged FILENAME —
# anything else is rejected before it can touch a path), and the action one of the three known verbs.
# Lifecycle verbs for the Telegram control commands (#338): the only two host actions the bot can
# trigger, both FIXED — `restart` runs `$0 restart` (recreate the running stack) and `apply` runs
# `$0 apply -y` (re-render + re-apply the CURRENT on-disk config.json). The container's `action`
# string only SELECTS between these two hardcoded commands; nothing from the request is ever
# interpolated into a command, and `apply` here carries no config change (the default-deny config
# allowlist is only relevant to a config-editing commit, not a re-apply of the source of truth).
# Access control + the deny-on-timeout confirmation are enforced dashboard-side before the intent is
# ever spooled; this side records the actor and outcome in the same tamper-evidence audit log.
control_lifecycle() { # <verb: restart|apply> <id> <actor> <control-dir>
    local verb="$1" id="$2" actor="$3" cdir="$4" rc=0
    local logf="$cdir/staged/.$id.log"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "$verb" "started"
    # ${PITHEAD_SELF:-$0} is this script (run_chain uses the same handle); the verb is a FIXED
    # literal picked by the case, never a string from the request.
    local self="${PITHEAD_SELF:-$0}"
    case "$verb" in
    restart) "$self" restart >"$logf" 2>&1 || rc=$? ;;
    apply) "$self" apply -y >"$logf" 2>&1 || rc=$? ;;
    *) return 0 ;; # unreachable: the dispatch already gated the verb
    esac
    if [ "$rc" -eq 0 ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg a "$verb" '{status:"applied",action:$a,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$verb" "applied"
    else
        control_write_result "$cdir/results" "$id" "$(jq -n --arg a "$verb" --arg e "$(tail -c 2000 "$logf")" '{status:"failed",action:$a,error:$e,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$verb" "failed"
    fi
    rm -f "$logf"
}

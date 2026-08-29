# One-shot encrypted backup + one-time "emergency kit" (#908). Reuses stack_backup UNCHANGED
# (~L2793), encrypted ONLY — no request field can pick --no-encrypt (it stays CLI-only), and a
# failure to mint a passphrase refuses before anything is touched, never falls back to plaintext.
# The passphrase is generated HOST-SIDE (generate_node_password: the same 32-char-alnum strength
# already used for the local node RPC creds) and crosses to stack_backup only through its existing
# PITHEAD_BACKUP_PASSPHRASE env-var input — the same channel an unattended cron backup already
# uses — never argv (what the support bundle's redaction targets, #77) and never a file.
#
# One-time handoff lifecycle: the kit (passphrase + archive name + contents + created-at/`ts`)
# rides back through the SAME results/ leg every other verb uses, keyed by the request id — but
# results/ is mounted READ-ONLY into the dashboard container (#33's trust boundary: it can only
# ASK, via requests/), so the container can never itself delete or ack this file the way the
# first-boot wizard's handoff/handoff-ack does (that spool is mounted read-write end to end). The
# deliberate substitute here: a bounded, blocking TTL. Short enough that a stuck backup doesn't
# stall the single-threaded runner's other queued verbs for long; generous next to the dashboard's
# own long-poll window (CONTROL_WAIT_S) so an ordinary page load always sees it. Once it elapses
# the passphrase is overwritten with null — read or not, it is gone. The archive/filename/contents
# stay: it is ciphertext, useless without the passphrase, so it remains downloadable.
# ponytail: TTL, not a container->host ack request (a "backup-ack" verb through requests/ would be
# more precise but is a whole extra verb) — add one if this window proves too tight/loose live.
# Backstop for control_backup's one-time kit: null the passphrase in any kit JSON whose `ts` is
# older than the TTL but which still carries one — the case where the runner was killed during the
# self-redaction sleep (a reboot racing the window) and left a wallet-grade secret in plaintext on
# /data. Run at the top of every drain, so the fresh runner after such a reboot cleans it up. A
# generous margin over the TTL (2x, floor 120s) so this never races the in-band redaction of a kit
# whose window is still open.
control_redact_stale_kits() { # <results-dir>
    local results="$1" f now cutoff ts
    [ -d "$results" ] || return 0
    now=$(date +%s)
    cutoff=$((2 * ${CONTROL_BACKUP_KIT_TTL_S:-20}))
    [ "$cutoff" -lt 120 ] && cutoff=120
    for f in "$results"/*.json; do
        [ -f "$f" ] || continue
        # Cheap gate first: only kits that still hold a passphrase are candidates.
        jq -e '.passphrase // "" | length > 0' "$f" >/dev/null 2>&1 || continue
        ts=$(jq -r '.ts // 0' "$f" 2>/dev/null)
        [ "$((now - ts))" -ge "$cutoff" ] || continue
        jq '.passphrase = null | .note = "The passphrase was shown once and is no longer available on this host — back up again if you did not save it."' \
            "$f" >"$results/.$(basename "$f").tmp" 2>/dev/null &&
            mv "$results/.$(basename "$f").tmp" "$f"
    done
}

control_backup() { # <id> <actor> <control-dir>
    local id="$1" actor="$2" cdir="$3" rc=0
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    control_audit "$auditf" "$id" "$actor" "backup" "started"
    # Throttle (mirrors control_upgrade's #59 stamp): a compromised container flooding this verb
    # would repeatedly stop/start the whole mining stack, not just burn CPU — one attempt per 10
    # minutes, checked before the passphrase is even generated.
    local stamp="$cdir/staged/.backup-stamp"
    if [ -n "$(find "$stamp" -mmin -10 2>/dev/null)" ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"rejected",error:"a backup was started less than 10 minutes ago — wait for it to finish, then retry.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "rejected"
        return 0
    fi
    { set +x; } 2>/dev/null # xtrace would print the passphrase assignment below
    local pass
    pass=$(generate_node_password)
    if [ -z "$pass" ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"rejected",error:"could not generate a backup passphrase — nothing was backed up.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "rejected"
        return 0
    fi
    touch "$stamp" 2>/dev/null || true # claim the throttle before the disruptive part starts
    control_write_result "$results" "$id" "$(jq -n '{status:"running",ts:(now|floor)}')"
    local self="${PITHEAD_SELF:-$0}" logf="$cdir/staged/.$id.log"
    # Run as a CHILD PROCESS, like control_lifecycle/control_commit's own re-invocations:
    # stack_backup's error() exits its whole process on failure, which must not take the drain
    # loop's other pending requests down with it.
    export PITHEAD_BACKUP_PASSPHRASE="$pass"
    "$self" backup -y >"$logf" 2>&1 || rc=$?
    unset PITHEAD_BACKUP_PASSPHRASE
    if [ "$rc" -ne 0 ]; then
        control_write_result "$results" "$id" "$(jq -n --arg e "$(tail -c 2000 "$logf")" '{status:"failed",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "failed"
        rm -f "$logf"
        pass=""
        return 0
    fi
    local archive
    archive=$(sed -n 's/^\[pithead\] Backup written to: //p' "$logf" | tail -n1)
    rm -f "$logf"
    if [ -z "$archive" ] || [ ! -f "$archive" ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"failed",error:"the backup ran but the archive could not be located afterward.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "failed"
        pass=""
        return 0
    fi
    # Place it on the ALREADY-shared results/ leg (#33) — no new bind mount, keyed by the same id
    # as its own result. Tighter perms than the rest of results/ (which relies on default,
    # effectively world-readable perms — fine, nothing there is a secret): root-owned,
    # group-readable by the dashboard's own uid/gid only (APP_UID/APP_GID, #255), because this
    # file briefly shares a directory with its own passphrase below.
    local fname dest
    fname=$(basename "$archive")
    dest="$results/$id.tar.gz.enc"
    mv "$archive" "$dest"
    chown "0:$APP_GID" "$dest" 2>/dev/null || true
    chmod 640 "$dest" 2>/dev/null || true
    (umask 077 && control_write_result "$results" "$id" "$(jq -n --arg p "$pass" --arg f "$fname" '
        {status:"applied", passphrase:$p, archive:$f,
         contents:["config.json","the stack .env (secrets)","Caddyfile, if present",
                   "the Tor onion-service key directory, if present","the dashboard database"],
         note:"This passphrase is shown once and cannot be recovered — save it now.",
         ts:(now|floor)}')")
    pass=""
    chown "0:$APP_GID" "$results/$id.json" 2>/dev/null || true
    chmod 640 "$results/$id.json" 2>/dev/null || true
    control_audit "$auditf" "$id" "$actor" "backup" "applied"
    # The blocking TTL described above the function. Overridable so tests don't sit through it.
    sleep "${CONTROL_BACKUP_KIT_TTL_S:-20}"
    jq '.passphrase = null | .note = "The passphrase was shown once and is no longer available on this host — back up again if you did not save it."' \
        "$results/$id.json" >"$results/.$id.json.tmp" 2>/dev/null &&
        mv "$results/.$id.json.tmp" "$results/$id.json"
}

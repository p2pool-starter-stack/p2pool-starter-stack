# Read-only diagnostics over the control channel (#913 doctor detail, #943 log tail). This slice
# is named `46a-` deliberately: the build concatenates lib/pithead/*.sh in LC_ALL=C order
# (scripts/build-pithead.sh), which places it AFTER 46-control-worker-ops.sh and BEFORE
# 47-os-update-helpers.sh, i.e. at the end of the control-verb family where it belongs — but a
# plain `ls` under a UTF-8 locale sorts `46a-` BEFORE `46-`, so what you see in a directory
# listing is not the order the artifact is built in. Trust the C-locale sort, not the listing.
#
# Both verbs are ASKS with no host mutation: they read and report. That is what lets them skip the
# approval gate every mutating verb goes through. Neither takes a string that reaches a command —
# the container names a container from the FIXED allowlist below and a line count that is clamped
# host-side, and nothing else crosses.
#
# WHY THE APPLIANCE NEEDS THIS: an appliance operator has no shell. Today they can see THAT a
# service is unhealthy and never WHY, and their only recourse is the support bundle or the console.
#
# REDACTION: bundle_redact_log (07-support-bundle.sh) is the ONLY redactor on this slice, and it
# guards BOTH verbs — the log tail and the doctor document. It is reused rather than reimplemented
# on purpose: that function's own header records the ruling that a second list is how the two
# drift apart, and it carries #1585's per-form address rows. Anything either verb must newly
# redact belongs in bundle_redact_log, where the support bundle gets it too.
#
# THE ALLOWLIST IS NARROWER THAN THE COMPOSE SET, AND THAT IS THE POINT. `wallet-rpc` and
# `tari-wallet` are compose services this verb deliberately REFUSES. bundle_redact_log is keyed to
# the launch-line leak class — the credential flags and addresses services echo in argv on startup
# — and the wallet daemons are precisely the two whose ordinary output is most likely to carry key
# and address material in shapes outside that class. The support bundle may collect them because
# it lands as a chmod-600 tarball the operator reviews before sharing; this verb streams to a
# browser over the network, which is a different trust context for the same bytes. An operator
# debugging a crash-looping wallet still has the support bundle and the console.
readonly PITHEAD_DIAG_CONTAINERS="tor monerod tari p2pool xmrig-proxy dashboard docker-proxy docker-control caddy"

# Hard caps, enforced HOST-SIDE in the verb rather than by the caller: a bound the client asks for
# is not a bound. Lines match the support bundle's own --tail 200. The byte cap is the one that
# actually protects the runner and the results spool, because a single log line has no length
# limit — a service echoing a megabyte on one line satisfies any line cap.
readonly PITHEAD_DIAG_MAX_LINES=200
readonly PITHEAD_DIAG_MAX_BYTES=65536

# `doctor --json` for the dashboard (#913). Runs as a CHILD PROCESS for the same reason
# control_backup does: doctor's own error paths exit the process, and that must not take the
# single-threaded drain loop's other queued requests down with it. doctor's rc is the failure
# COUNT, not a run failure, so a non-zero rc still carries a valid document.
#
# THE DOCTOR DOCUMENT IS REDACTED TOO, and it is not obvious that it must be. doctor writes its
# report for the CLI, where the reader is the operator: `Dashboard onion:` prints the address in
# full on purpose (06-doctor.sh), because someone at a terminal needs it. That is the right call
# there and the wrong one here — this document crosses into the container, which is the party the
# whole channel is built not to trust, and the hidden-service address is the one value whose only
# security property is that nobody has it. The support bundle carries the same document unredacted
# because it lands as a chmod-600 file the operator reviews before sharing; same bytes, different
# trust context, same distinction the log tail already makes.
#
# It goes through bundle_redact_log — the same and only redactor the log tail uses — rather than a
# rule of its own, so a value added there is covered on both paths. Redacting JSON as text is safe
# for the onion rule (a fixed-shape match that cannot touch a quote), and the `jq -e .` check below
# is the backstop if any other rule ever did break structure: the result would be a refusal, not a
# leak.
control_diag_doctor() { # <id> <actor> <control-dir>
    local id="$1" actor="$2" cdir="$3"
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    local self="${PITHEAD_SELF:-$0}" out
    control_audit "$auditf" "$id" "$actor" "diag-doctor" "started"
    out=$("$self" doctor --json 2>/dev/null | bundle_redact_log | head -c "$PITHEAD_DIAG_MAX_BYTES")
    # A truncated document is not a document: report the failure rather than shipping half an
    # object the dashboard would fail to parse and render as "no data".
    if [ -z "$out" ] || ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
        control_write_result "$results" "$id" "$(jq -n '{status:"failed",error:"doctor did not return a readable report on this host.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "diag-doctor" "failed"
        return 0
    fi
    control_write_result "$results" "$id" "$(jq -n --argjson d "$out" '{status:"applied",doctor:$d,ts:(now|floor)}')"
    control_audit "$auditf" "$id" "$actor" "diag-doctor" "applied"
}

# Bounded, redacted log tail for ONE allowlisted container (#943).
control_diag_logs() { # <request-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    local container lines out found=0 c
    container=$(jq -r '.container // ""' "$file")
    lines=$(jq -r '.lines // 0' "$file")
    control_audit "$auditf" "$id" "$actor" "diag-logs" "started"
    # Membership, not pattern-matching: the name must be one of the listed words exactly, so no
    # separator or glob trick reaches `docker compose logs`.
    for c in $PITHEAD_DIAG_CONTAINERS; do
        [ "$container" = "$c" ] && found=1 && break
    done
    if [ "$found" -ne 1 ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"rejected",error:"not a container this dashboard may read logs for.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "diag-logs" "rejected"
        return 0
    fi
    # Clamp rather than reject: a caller asking for more than the cap gets the cap, which keeps the
    # bound a host property. A non-numeric or absent count falls to the cap the same way.
    case "$lines" in
    '' | *[!0-9]*) lines="$PITHEAD_DIAG_MAX_LINES" ;;
    esac
    # Bound the WIDTH before comparing values. `[ N -gt M ]` does not compare a digit string past
    # 64 bits — it errors, and as the left operand of `&&` that error is swallowed, so the clamp
    # below silently no-ops and the request reaches `--tail` uncapped. A digit string longer than
    # the cap's own width cannot be within the cap, so this decides those cases without arithmetic.
    [ "${#lines}" -gt "${#PITHEAD_DIAG_MAX_LINES}" ] && lines="$PITHEAD_DIAG_MAX_LINES"
    [ "$lines" -lt 1 ] && lines=1
    [ "$lines" -gt "$PITHEAD_DIAG_MAX_LINES" ] && lines="$PITHEAD_DIAG_MAX_LINES"
    # Redact BEFORE the byte cap, never after: truncating first would leave the tail of a redacted
    # line intact, which is the leak the redactor exists to stop.
    out=$(docker compose logs --no-color --tail "$lines" "$container" 2>/dev/null |
        bundle_redact_log | head -c "$PITHEAD_DIAG_MAX_BYTES")
    if [ -z "$out" ]; then
        control_write_result "$results" "$id" "$(jq -n --arg c "$container" '{status:"applied",container:$c,lines:"",note:"No log output — the container may not be running on this host.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "diag-logs" "applied"
        return 0
    fi
    control_write_result "$results" "$id" "$(jq -n --arg c "$container" --arg l "$out" '{status:"applied",container:$c,lines:$l,ts:(now|floor)}')"
    control_audit "$auditf" "$id" "$actor" "diag-logs" "applied"
}

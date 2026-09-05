# Secret leaves in config.json, as jq path arrays. The single host-side source for BOTH control-
# channel maskings (#440): the pre-masked prefill copy (render_masked_config) and the sentinel
# swap at staging (control_preview). Mirrors the dashboard's control_service.SECRET_PATHS — keep
# the two lists in step.
readonly CONTROL_SECRET_PATHS='[
    ["dashboard","auth","password"],
    ["telegram","bot_token"],
    ["workers","api_token"],
    ["monero","node_username"],
    ["monero","node_password"],
    ["monero","view_key"],
    ["tari","view_key"],
    ["p2pool","stratum_password"],
    ["healthchecks","ping_url"],
    ["notifications","ntfy","url"],
    ["notifications","ntfy","token"],
    ["xvb","standby","source"]]'

# #690: bound every host-runner curl so a hostile/MITM'd rig or release response can't stream an
# unbounded body into memory ($( )) or onto disk (-o) inside the --max-time window. --max-filesize
# aborts BOTH before the transfer (when Content-Length is honest) AND mid-stream once received
# bytes cross the cap (verified curl 8.7 → exit 63), so a lying or absent Content-Length is covered
# too — every runner curl already treats a non-zero exit as failure and cleans its partial file.
# Two envelopes: JSON dials + the cosign sig are tiny; the release BUNDLE is a whole-stack tarball.
readonly CURL_CAP_SMALL=1048576 # 1 MiB — GitHub release JSON, rig control responses, cosign sig
# ponytail: 16 MiB, ~128× today's ~126 KB bundle; bump if a real bundle ever approaches it (a
# cap-hit surfaces as _upg_fail's "could not download over Tor", loud but network-flavoured).
readonly CURL_CAP_BUNDLE=16777216 # 16 MiB — the pithead.tar.gz release bundle (code + configs)
# The signed OS image bundle (.raucb) is a whole rootfs — its own envelope, ~3× today's size so a
# grown release still downloads while a runaway stream is still cut off.
readonly CURL_CAP_OS_BUNDLE=3221225472 # 3 GiB — the pithead-os .raucb A/B update bundle

# The latest-release JSON for a GitHub repo, over the stack's own Tor SOCKS like every other
# stack egress. Prints the JSON and returns 0; on failure prints nothing, returns 1, and leaves
# GH_RELEASE_HINT holding the sentence the operator should actually be told.
#
# The reason this is a function and not two `curl -fsS` calls: `-f` collapses every non-2xx into
# one exit code, so a 403 came out as "could not reach GitHub over Tor" and sent the operator to a
# doctor run that correctly reports Tor healthy. GitHub's unauthenticated limit is 60 requests an
# hour PER IP, and a Tor exit is shared with everyone else using it, so a spent budget is a normal
# condition with nothing wrong with this machine — and a different remedy (pick a new exit) from a
# dial that genuinely failed.
# NOT stdout, deliberately: the JSON lands in GH_RELEASE_JSON and the caller runs this as a plain
# command. Assigning it through a command substitution reads naturally and is WRONG — that is a
# subshell, so the hint set here would never reach the caller and every rejection would carry an
# empty message. Two globals, one call, no subshell.
GH_RELEASE_HINT=""
GH_RELEASE_JSON=""
# The SOCKS address this fetch used, published so a caller that goes on to download the release over
# the same Tor path derives it ONCE rather than twice. Folding the lookup into a function deleted the
# caller's own derivation, and `set -u` then killed the runner at its first download — the upgrade
# result sat at "running" for ever with a single dial in the log. One derivation, one truth.
GH_SOCKS=""
gh_release_fetch() { # <owner/repo>; sets GH_RELEASE_JSON on success, GH_RELEASE_HINT on failure; rc 2 = never reached the server at all (#1050)
    local repo="$1" prefix out code retry_hint
    prefix=$(env_get NETWORK_PREFIX 2>/dev/null) || true
    [ -n "$prefix" ] || prefix="172.28.0"
    GH_SOCKS="${prefix}.25:9050"
    GH_RELEASE_HINT=""
    GH_RELEASE_JSON=""
    # Every caller of this fetch is reachable from the dashboard on an appliance (os-check, the
    # RigForge worker-upgrade) — which has no shell to run 'doctor' from, the product's defining
    # property (#1139). The one caller that DOES want the CLI hint (the DIY one-click upgrade)
    # already refuses before it ever dials on an appliance host, so keying this off is_appliance
    # — a fact about the machine, not the caller — gets every call site right with one seam.
    if is_appliance; then
        retry_hint="Retry from the dashboard in a few minutes."
    else
        retry_hint="Check './pithead doctor' and retry."
    fi
    # -w appends the status on its own line, so a non-2xx keeps its BODY — which is where GitHub
    # says the limit was exceeded. Without -f, curl's own non-zero exit now means only a transport
    # failure, which is exactly the distinction that was missing.
    if ! out=$(curl -sS --max-time 60 --max-filesize "$CURL_CAP_SMALL" -w '\n%{http_code}' \
        --socks5-hostname "$GH_SOCKS" -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null); then
        GH_RELEASE_HINT="could not reach the GitHub release API over Tor — nothing was changed. $retry_hint"
        # rc 2, not 1: no HTTP response came back from GitHub, so this is distinct from every
        # failure below, which DID reach the server and keeps the ordinary rc 1. rc 2 does NOT
        # mean no real attempt happened, though — through Tor a circuit-build timeout or an
        # exit-relay refusal returns this exact same curl exit for a dial that genuinely went
        # out on the wire, indistinguishable here from a purely local "Tor daemon down" (#1050).
        # A caller that throttles on this rc must bound the retry rate with a short cooldown,
        # not skip the cooldown outright.
        return 2
    fi
    code=${out##*$'\n'}
    out=${out%$'\n'*}
    # No status line at all means the response is not one we can reason about — and without this the
    # WHOLE BODY becomes "$code" and gets echoed into an operator-facing message, which is both
    # nonsense to read and a way for a remote body to land verbatim in the dashboard.
    case "$code" in
    [0-9][0-9][0-9]) ;;
    *)
        GH_RELEASE_HINT="the GitHub release API answered in a shape this cannot read — nothing was changed. $retry_hint"
        return 1
        ;;
    esac
    case "$code" in
    2*)
        GH_RELEASE_JSON="$out"
        return 0
        ;;
    403 | 429)
        if printf '%s' "$out" | grep -qi 'rate limit'; then
            GH_RELEASE_HINT="the Tor exit this machine is currently using has spent GitHub's shared hourly request budget — nothing is wrong with this box, and 'doctor' will say so. Run './pithead restart tor' to pick a new exit, then retry."
            return 1
        fi
        ;;
    esac
    GH_RELEASE_HINT="the GitHub release API answered HTTP $code — nothing was changed. Retry in a few minutes."
    return 1
}

# Render the pre-masked prefill copy (#440): the live config with every SET secret leaf replaced
# by the {"__secret__":true} sentinel, written atomically to <control-dir>/masked/config.json.
# The dashboard serves the Configuration form from THIS file (mounted read-only) — the raw
# config.json is never mounted into the container, so a full container compromise reads masked
# config, results, and the audit log, nothing more. An EMPTY secret stays empty, so the UI can
# tell "set — leave blank to keep" from "not set". World-readable on purpose (it holds no secret
# values; the container reads it as $APP_UID); best-effort, so a render hiccup degrades to a
# stale prefill, never a failed apply.
render_masked_config() { # <control-dir>
    local mdir="$1/masked" tmp
    mkdir -p "$mdir" 2>/dev/null || true
    tmp="$mdir/.config.json.tmp"
    # Per-worker tokens (#172) live in the variable-length descriptor array at workers.list[]
    # (#506), out of reach of the fixed-path walk above — mask each SET .token entry by entry.
    # Masking an empty array is a no-op.
    #
    # dashboard.workers[] STAYS masked although 2.0.0 removed that alias (#1832), for the reason
    # os/overlay/pithead-media-config:163 stays: a masking predicate is not alias acceptance. "The
    # migration ran first" is FALSE at two of this function's three callers — 49:81 re-renders the
    # prefill before draining PRECISELY so a hand-edit since the last apply shows up, and 07:75
    # renders straight off $CONFIG_FILE for a support bundle. Neither runs parse_and_validate_config,
    # and migrate_legacy_workers returns early on a dry run in any case. A machine upgraded to 2.0.0
    # but not yet applied would otherwise put a raw per-rig token into the editor prefill and into a
    # support bundle — the artifact operators hand to strangers. Masking a key nothing reads costs
    # one no-op jq branch; not masking one that is still on disk is a credential leak.
    if jq --argjson paths "$CONTROL_SECRET_PATHS" '
        reduce $paths[] as $p (.;
            if ((try getpath($p) catch null) // "") == "" then .
            else setpath($p; {"__secret__": true}) end)
        | if (.workers | type) == "object" and (.workers.list | type) == "array"
          then .workers.list |= map(
              if (.token // "") == "" then . else .token = {"__secret__": true} end)
          else . end
        | if (.dashboard | type) == "object" and (.dashboard.workers | type) == "array"
          then .dashboard.workers |= map(
              if (.token // "") == "" then . else .token = {"__secret__": true} end)
          else . end
        # notifications.webhooks[] (#848): the whole URL is the bearer secret (query strings carry
        # tokens), and there is no fixed leaf path — mask each set entry, like the worker tokens.
        | if (.notifications | type) == "object" and (.notifications.webhooks | type) == "array"
          then .notifications.webhooks |= map(
              if (. // "") == "" then . else {"__secret__": true} end)
          else . end' "$CONFIG_FILE" >"$tmp" 2>/dev/null; then
        chmod 644 "$tmp" 2>/dev/null || true
        mv "$tmp" "$mdir/config.json" 2>/dev/null ||
            warn "Could not write $mdir/config.json — the dashboard editor prefill may be stale."
    else
        rm -f "$tmp"
        warn "Could not render the masked config copy — the dashboard editor prefill may be stale."
    fi
}

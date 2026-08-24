#!/usr/bin/env bash
#
# .trivyignore obsolete-mute watch (#1174).
#
# Nothing today checks whether a `.trivyignore` entry's finding still exists anywhere. Two
# sentences in the file itself used to claim the weekly CVE sweep (#833) does — it does not: the
# sweep passes `trivyignores: .trivyignore` to trivy (os-rootfs.yml, ci.yml), and trivy's ignore
# file filters matching findings OUT of the report before the sweep ever sees them. A muted finding
# is invisible to the sweep by construction, so a mute that outlives the finding it was written for
# rots silently — which is exactly how the two mutes #1153 found stale survived until someone
# checked by hand.
#
# REPORT-ONLY. The `pin-watch.sh` posture: never a gate, because a cleared mute is housekeeping, not
# a build failure. It never edits `.trivyignore` and never opens a PR.
#
# THE TRAP, found while writing #1174: `.trivyignore` is SHARED across both lanes and covers
# SEVERAL images. A per-image "does this ID still show up" check is worse than no check, because it
# produces a confident, WRONG deletion list — seven IDs looked dead scanning the appliance rootfs
# alone, and some of those were live dashboard-image mutes. An entry is obsolete only when it is
# absent from EVERY covered image's own scan, so this script builds and scans all of them with no
# ignore file and only reports an ID that no covered image reports.
#
# The covered images, enumerated from the real build/scan setup rather than guessed (ci.yml's
# build-images matrix + os-rootfs.yml, both cited below):
#   pithead-os-rootfs    os/rootfs/Dockerfile   (debian:trixie-slim + the golang builder stage)
#   pithead-dashboard    dashboard              (python:3.11-slim, the `production` stage — the
#                                                 same default target ci.yml's untargeted build uses)
#   pithead-monero       build/monero           (ubuntu:24.04)
#   pithead-p2pool       build/p2pool           (ubuntu:24.04)
#   pithead-xmrig-proxy  build/xmrig-proxy      (ubuntu:24.04)
#   pithead-tor          build/tor              (alpine:3.24)
#
# Each is built EXACTLY the way the gate builds it (same Dockerfile, same context, same required
# build args) — scanning an image built any other way proves nothing about what the gate sees.
#
# FAIL LOUDLY ON A BROKEN RUN. An empty image list, a build that cannot run, or a scan that cannot
# run (trivy/docker missing, a pull failure, an unparseable report) must never fall through to "0
# obsolete mutes found" — that is a false green wearing the report's own shape, the same defect
# class the sweep itself has. A broken or partial scan means "unknown", never "clean", so this
# refuses to name ANY mute obsolete off an incomplete run and exits 1 instead.
#
# THE PARITY CONTRACT (#1290). TRIVY_VERSION below is the one place that declares which trivy
# engine this script's own scan uses. `--check-parity` (wired into `make lint-trivy-parity`) holds
# ci.yml's and os-rootfs.yml's trivy-action `version:` input, and the pinned image's own measured
# version, to that one value — it does not prove what trivy-action resolves a declared input to at
# run time, only that the two workflows and this script all declare the same one; what the action
# does with a declared input is upstream's contract. A dependabot bump of trivy-action that silently
# moves the action's own UNDECLARED default is exactly the drift this catches.
#
# Usage:
#   scripts/trivyignore-watch.sh              Build + scan every covered image with NO ignore file
#                                              applied, print the report, rc 1 only if the run
#                                              itself is broken (an obsolete-mute finding is
#                                              printed, not a failure — report-only).
#   scripts/trivyignore-watch.sh --self-test  Drive the union/report logic against fixture scan
#                                              output. No docker, no network, no image builds.
#   scripts/trivyignore-watch.sh --check-parity
#                                              Check that ci.yml's and os-rootfs.yml's trivy-action
#                                              steps pin `version:` to TRIVY_VERSION (#1290). No
#                                              docker, no network. Exit code is the check's own rc.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IGNOREFILE="$ROOT/.trivyignore"

# The two CVE-gate workflows whose trivy-action steps must stay pinned to TRIVY_VERSION (#1290).
# Overridable so --self-test can point this at fixture files instead.
GATE_WORKFLOWS="$ROOT/.github/workflows/ci.yml $ROOT/.github/workflows/os-rootfs.yml"

# The ONE source of truth for the scanning engine (#1290) — the parity contract is in the header.
# Digest-pinned (repo convention, #135/#373) rather than `:latest`, so a run today and a run next
# month scan with the same trivy and the same vulnerability-DB client.
TRIVY_VERSION="0.74.0"
TRIVY_IMAGE="aquasec/trivy@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969" # TRIVY_VERSION above

# Same severity/fixability scope as the gate (ci.yml, os-rootfs.yml): .trivyignore only ever holds
# entries that would otherwise block on THAT scope, so scanning any wider scope here would report
# an ID as "still live" off a finding the gate itself would never have seen in the first place.
SEVERITY="HIGH,CRITICAL"

IMAGES="pithead-os-rootfs pithead-dashboard pithead-monero pithead-p2pool pithead-xmrig-proxy pithead-tor"

# --- building and scanning ------------------------------------------------------------------------

# <name> -> image tag on stdout, rc 1 if the build fails. Build output goes to stderr so stdout
# carries only the tag.
build_image() {
    local name="$1" tag="pithead-mutewatch-$1:latest"
    case "$name" in
    pithead-os-rootfs)
        # Same two steps os-rootfs.yml runs: stamp BUILD_COMMIT (the Dockerfile COPYs it), then
        # build with the release variant's updater. Heavy — the rootfs COMPILES docker-compose and
        # cosign from source on a pinned Go toolchain (scripts/pin-watch.sh carries the same note).
        git -C "$ROOT" rev-parse HEAD >"$ROOT/os/rootfs/BUILD_COMMIT" || return 1
        docker build -f "$ROOT/os/rootfs/Dockerfile" -t "$tag" \
            --build-arg PITHEAD_UPDATER=rauc "$ROOT" >&2 || return 1
        ;;
    pithead-dashboard) docker build -t "$tag" "$ROOT/dashboard" >&2 || return 1 ;;
    pithead-monero) docker build -t "$tag" "$ROOT/build/monero" >&2 || return 1 ;;
    pithead-p2pool) docker build -t "$tag" "$ROOT/build/p2pool" >&2 || return 1 ;;
    pithead-xmrig-proxy) docker build -t "$tag" "$ROOT/build/xmrig-proxy" >&2 || return 1 ;;
    pithead-tor) docker build -t "$tag" "$ROOT/build/tor" >&2 || return 1 ;;
    *) return 1 ;;
    esac
    printf '%s' "$tag"
}

# <tag> -> one vulnerability ID per line on stdout, rc 1 on any failure to run or parse the scan.
# NO trivyignores flag — that is the entire point: an ignored finding must still show up here so an
# obsolete mute can be told apart from a live one.
scan_image() {
    local tag="$1" json
    json=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "$TRIVY_IMAGE" \
        image --scanners vuln --severity "$SEVERITY" --ignore-unfixed --format json "$tag" \
        2>/dev/null) || return 1
    printf '%s' "$json" | jq -er '(.Results // [])[] | (.Vulnerabilities // [])[] | .VulnerabilityID' \
        2>/dev/null
    # jq exits 1 when it produces no output at all (a clean scan) — that is success here, not a
    # scan failure, so the pipeline's rc is deliberately not propagated past this point.
    return 0
}

# <ignorefile> -> one finding ID per line, comments and blank lines stripped. `.trivyignore`'s
# entries are bare IDs (CVE-.../GHSA-...) one per line; an inline note, if one is ever added, would
# be a second whitespace-separated field, so only the first field is taken.
ignored_ids() {
    grep -vE '^[[:space:]]*(#|$)' "$1" | awk '{print $1}'
}

# --- engine parity (#1290) --------------------------------------------------------------------

# -> the pinned $TRIVY_IMAGE's own reported version on stdout, rc 1 if docker fails to run it or
# the output has no `Version: ` line to parse. Real trivy output's first line is exactly
# "Version: 0.74.0"; only the FIRST matching line counts.
engine_version() {
    local out ver
    out="$(docker run --rm "$TRIVY_IMAGE" --version 2>/dev/null)" || return 1
    ver="$(printf '%s\n' "$out" | awk '/^Version: /{print $2; exit}')"
    [ -n "$ver" ] || return 1
    printf '%s' "$ver"
}

# $GATE_WORKFLOWS -> one `<basename>\t<version>` line per trivy-action step found, in file order.
# `<version>` is MISSING when the step has no `version:` key in its `with:` block, or NOFILE when
# the workflow file itself does not exist. A single awk state machine per file: a line that starts
# (optional list-item marker aside) with `uses:` naming aquasecurity/trivy-action@ opens a step —
# anchored to line-start so a commented-out `# uses: ...` cannot open a phantom step; a `version:`
# key inside it is captured with any trailing inline comment stripped; the next list item
# (`- ...`, i.e. the next step) or EOF closes the step and emits it.
gate_versions() {
    local f base
    for f in $GATE_WORKFLOWS; do
        base="$(basename "$f")"
        if [ ! -f "$f" ]; then
            printf '%s\tNOFILE\n' "$base"
            continue
        fi
        awk -v file="$base" '
            function emit() { print file "\t" (ver == "" ? "MISSING" : ver) }
            /^[[:space:]]*(-[[:space:]]+)?uses:.*aquasecurity\/trivy-action@/ {
                if (instep) emit()
                instep = 1; ver = ""
                next
            }
            instep && /^[[:space:]]*version:[[:space:]]*/ {
                v = $0
                sub(/^[[:space:]]*version:[[:space:]]*/, "", v)
                sub(/[[:space:]]*#.*$/, "", v)
                sub(/[[:space:]]*$/, "", v)
                ver = v
                next
            }
            instep && /^[[:space:]]*-[[:space:]]/ {
                emit()
                instep = 0
                next
            }
            END { if (instep) emit() }
        ' "$f"
    done
}

# -> one line per trivy-action step describing whether its `version:` matches $TRIVY_VERSION, rc 0
# only if every file in $GATE_WORKFLOWS produced at least one trivy-action step AND every one of
# those steps' versions is EXACTLY `v$TRIVY_VERSION` — no loose `v`-stripped comparison, because
# the real chain (trivy-action -> setup-trivy -> trivy's own install.sh) builds its release URL
# from the declared value verbatim: a bare `0.74.0` 404s where `v0.74.0` resolves, so a bare value
# is a real mismatch, not a cosmetic one. A file that yields no step at all (missing file, or no
# trivy-action `uses:` line) is a failure on its own — a parity check that cannot find its target
# must go red, not silently skip it.
check_parity() {
    local gv f base lf lver fail=0 any
    gv="$(gate_versions)"

    for f in $GATE_WORKFLOWS; do
        base="$(basename "$f")"
        any=0
        while IFS=$'\t' read -r lf lver; do
            [ "$lf" = "$base" ] || continue
            [ "$lver" = "NOFILE" ] && continue
            any=1
            if [ "$lver" = "MISSING" ]; then
                echo "$base: MISSING — no version: input, trivy-action installs its own default (that is the #1290 defect)"
                fail=1
                continue
            fi
            if [ "$lver" = "v$TRIVY_VERSION" ]; then
                echo "$base: trivy-action version $lver matches the watch ($TRIVY_VERSION)"
            elif [ "$lver" = "$TRIVY_VERSION" ]; then
                echo "$base: MISMATCH — trivy-action version $lver is not v$TRIVY_VERSION (setup-trivy resolves the value verbatim; it must carry the v)"
                fail=1
            else
                echo "$base: MISMATCH — trivy-action version $lver, watch scans $TRIVY_VERSION"
                fail=1
            fi
        done <<<"$gv"

        if [ "$any" -eq 0 ]; then
            echo "$base: NO trivy-action step found — the parity check cannot see the gate"
            fail=1
        fi
    done

    if [ "$fail" -eq 1 ]; then
        echo "Fix: set every trivy-action version: to exactly v$TRIVY_VERSION (the leading v is required), or bump TRIVY_VERSION (and the pinned digest above) together."
    fi
    return "$fail"
}

# Gate the real run on both halves of the parity contract before it reports anything: the pinned
# image must measure as the version this script declares, and the gate's own workflows must be
# pinned to that same version. Either failing means an "obsolete mute" verdict would describe an
# engine the gate does not actually run — refuse rather than report.
preflight() {
    local measured
    if ! measured=$(engine_version); then
        echo "trivyignore-watch: BROKEN RUN — could not measure the pinned trivy image's version." >&2
        return 1
    fi
    if [ "$measured" != "$TRIVY_VERSION" ]; then
        echo "trivyignore-watch: BROKEN RUN — pinned image reports trivy $measured, script declares $TRIVY_VERSION; refusing to report." >&2
        return 1
    fi
    if ! check_parity >/dev/null; then
        echo "trivyignore-watch: BROKEN RUN — the gate scans with a different trivy than this watch; an obsolete verdict would describe an engine the gate never runs (#1295's caveat). Refusing to report." >&2
        return 1
    fi
    return 0
}

# --- the report ------------------------------------------------------------------------------------

# <ignorefile> -> markdown report on stdout. rc 1 on a broken run (nothing named obsolete); rc 0
# once the report is a real answer, even when it reports obsolete mutes — report-only.
report() {
    local ignorefile="$1"
    local name tag failed="" all_ids
    all_ids="$(mktemp)"
    : >"$all_ids"

    if [ -z "$IMAGES" ]; then
        echo "trivyignore-watch: BROKEN RUN — no images enumerated to scan. Refusing to report: an" >&2
        echo "empty image list would otherwise print an honest-looking 'no obsolete mutes found'." >&2
        rm -f "$all_ids"
        return 1
    fi

    for name in $IMAGES; do
        if ! tag=$(build_image "$name"); then
            failed="${failed}${failed:+, }$name (build)"
            continue
        fi
        if ! scan_image "$tag" >>"$all_ids"; then
            failed="${failed}${failed:+, }$name (scan)"
        fi
    done

    if [ -n "$failed" ]; then
        echo "trivyignore-watch: BROKEN RUN — could not build/scan: $failed." >&2
        echo "Refusing to name any mute obsolete off an incomplete scan — the ID this run couldn't" >&2
        echo "see might be the one thing keeping a mute honest (#1174's per-image trap, one level up)." >&2
        rm -f "$all_ids"
        return 1
    fi

    sort -u "$all_ids" -o "$all_ids"

    local id checked=0 obsolete=0 rows=""
    for id in $(ignored_ids "$ignorefile"); do
        checked=$((checked + 1))
        if grep -qxF "$id" "$all_ids"; then
            rows="${rows}| \`$id\` | yes | still live |"$'\n'
        else
            rows="${rows}| \`$id\` | no | **OBSOLETE — no covered image reports it** |"$'\n'
            obsolete=$((obsolete + 1))
        fi
    done
    rm -f "$all_ids"

    printf '%s\n\n' "Obsolete-.trivyignore-mute watch (#1174). Report-only — an obsolete mute is housekeeping, not a build failure."
    printf '%s\n\n' "Images scanned, no ignore file applied: $IMAGES"
    printf '%s\n\n' "Engine: trivy $TRIVY_VERSION — the version ci.yml and os-rootfs.yml pass to trivy-action (parity checked before this run)."
    printf '| finding ID | seen in any covered image | verdict |\n|---|---|---|\n%s' "$rows"
    if [ "$obsolete" -gt 0 ]; then
        printf '\n%s\n' "$obsolete of $checked mute(s) are OBSOLETE."
    else
        printf '\n%s\n' "No obsolete mutes. All $checked entries still match at least one covered image."
    fi
    printf '\n<!-- trivyignore-watch: obsolete=%s checked=%s -->\n' "$obsolete" "$checked"
    return 0
}

# --- self-test -------------------------------------------------------------------------------------
# The union-across-images rule is the whole product here; a real run is one `docker build` and one
# `docker run trivy` per image. Drives report()'s logic against stubbed build_image/scan_image —
# the same technique scripts/pin-watch.sh uses to stub `gh` — over fixture per-image findings that
# reproduce the trap verbatim: an ID present in exactly ONE of six covered images.
if [ "${1:-}" = "--self-test" ]; then
    st_fail=0
    st() { # <label> <got> <want>
        if [ "$2" = "$3" ]; then
            echo "  self-test ok: $1"
        else
            echo "  self-test FAIL: $1 (got [$2], want [$3])"
            st_fail=1
        fi
    }

    st "ignored_ids strips comments and blank lines" \
        "$(
            f=$(mktemp)
            printf '# a comment\n\nCVE-2026-1\n# another\nCVE-2026-2\n' >"$f"
            ignored_ids "$f" | tr '\n' ' '
            rm -f "$f"
        )" "CVE-2026-1 CVE-2026-2 "

    # Fixture per-image findings, keyed by the real image names. CVE-TRAP sits ONLY in the
    # dashboard image — the shape #1174 found for real: an appliance-only per-image check would
    # never see it and would call it obsolete. CVE-LIVE-ROOTFS sits only in the appliance rootfs,
    # the mirror case. CVE-PLANTED sits in NONE of them — the mutation the issue's Verification
    # section asks for: plant a mute for an ID no image reports and confirm the report names it.
    build_image() { printf '%s' "$1"; } # the "tag" is just the name; no docker involved
    scan_image() {
        case "$1" in
        pithead-dashboard) printf 'CVE-TRAP\n' ;;
        pithead-os-rootfs) printf 'CVE-LIVE-ROOTFS\n' ;;
        *) : ;;
        esac
    }

    fixture_ignorefile=$(mktemp)
    cat >"$fixture_ignorefile" <<'EOF'
# fixture .trivyignore for the self-test
CVE-TRAP
CVE-LIVE-ROOTFS
CVE-PLANTED
EOF

    out=$(report "$fixture_ignorefile")
    rc=$?
    st "a clean run (every image scanned) exits 0" "$rc" "0"
    st "an ID present in only ONE of six covered images is NOT called obsolete (the trap)" \
        "$(printf '%s' "$out" | grep -c '`CVE-TRAP` | yes | still live |')" "1"
    st "the mirror case (appliance-only) is also NOT called obsolete" \
        "$(printf '%s' "$out" | grep -c '`CVE-LIVE-ROOTFS` | yes | still live |')" "1"
    st "a mute planted for an ID no image reports IS named obsolete" \
        "$(printf '%s' "$out" | grep -c '`CVE-PLANTED` | no | \*\*OBSOLETE')" "1"
    st "the trailer counts exactly one obsolete mute" \
        "$(printf '%s' "$out" | grep -o 'obsolete=[0-9]*')" "obsolete=1"

    # Remove the planted mute (the second half of the issue's Verification: "then remove it and
    # confirm the report goes quiet") and confirm CVE-PLANTED no longer appears anywhere at all.
    cat >"$fixture_ignorefile" <<'EOF'
CVE-TRAP
CVE-LIVE-ROOTFS
EOF
    out2=$(report "$fixture_ignorefile")
    st "removing the planted mute makes the report go quiet on it" \
        "$(printf '%s' "$out2" | grep -c 'CVE-PLANTED')" "0"
    st "and the trailer drops back to zero obsolete" \
        "$(printf '%s' "$out2" | grep -o 'obsolete=[0-9]*')" "obsolete=0"
    rm -f "$fixture_ignorefile"

    # UNKNOWN MUST NOT READ AS CLEAN — the defect class this whole script is aimed at, one level up
    # from the sweep it reports on. A build/scan failure on ANY one image must refuse to name
    # anything obsolete, not just omit the failed image's contribution.
    build_image() {
        [ "$1" = "pithead-p2pool" ] && return 1
        printf '%s' "$1"
    }
    scan_image() { :; }
    f=$(mktemp)
    printf 'CVE-2026-1\n' >"$f"
    st "a build failure on one image fails the whole run, not just that image" \
        "$(
            report "$f" >/dev/null 2>&1
            echo $?
        )" "1"
    st "a broken run prints nothing to stdout — never a silent \"no obsolete mutes\"" \
        "$(report "$f" 2>/dev/null | wc -l | tr -d ' ')" "0"

    build_image() { printf '%s' "$1"; }
    scan_image() {
        [ "$1" = "pithead-tor" ] && return 1
        :
    }
    st "a scan failure on one image also fails the whole run" \
        "$(
            report "$f" >/dev/null 2>&1
            echo $?
        )" "1"
    rm -f "$f"

    # An empty enumeration is the same class of bug at one further remove — "found nothing to
    # check" must not print as "checked everything, found nothing wrong".
    IMAGES=""
    f=$(mktemp)
    printf 'CVE-2026-1\n' >"$f"
    st "an empty image list fails loudly rather than reporting clean" \
        "$(
            report "$f" >/dev/null 2>&1
            echo $?
        )" "1"
    rm -f "$f"

    # --- engine parity (#1290) --------------------------------------------------------------
    # Fixtures mimic the real step shape: a `- name:` step, the pinned trivy-action `uses:` line,
    # then a `with:` block with several keys.
    pt_dir=$(mktemp -d)
    pt_write() { # <path> <version-line-or-empty, no leading spaces> <has-trivy-step:0|1>
        local path="$1" verline="$2" has="$3"
        {
            printf '%s\n' "name: fixture" "jobs:" "  scan:" "    steps:" \
                "      - uses: actions/checkout@deadbeef # v7.0.1" \
                "        with:" \
                "          persist-credentials: false"
            if [ "$has" = "1" ]; then
                printf '%s\n' "      - name: Scan image for CVEs (Trivy)" \
                    "        uses: aquasecurity/trivy-action@deadbeef # v0.36.0" \
                    "        with:"
                [ -n "$verline" ] && printf '          %s\n' "$verline"
                printf '%s\n' "          image-ref: pithead-example:ci" \
                    "          scanners: vuln" \
                    "          severity: HIGH,CRITICAL" \
                    "          exit-code: \"1\""
            fi
            printf '%s\n' "      - name: Another step" "        run: echo done"
        } >"$path"
    }

    # (a) both at TRIVY_VERSION -> rc 0
    ci_a="$pt_dir/ci-a.yml"
    os_a="$pt_dir/os-a.yml"
    pt_write "$ci_a" "version: v0.74.0" 1
    pt_write "$os_a" "version: v0.74.0" 1
    GATE_WORKFLOWS="$ci_a $os_a"
    pp_rc=0
    check_parity >/dev/null || pp_rc=$?
    st "check_parity: both workflows at TRIVY_VERSION -> rc 0" "$pp_rc" "0"

    # (b) one at v0.70.0 -> rc 1, MISMATCH naming that file
    ci_b="$pt_dir/ci-b.yml"
    os_b="$pt_dir/os-b.yml"
    pt_write "$ci_b" "version: v0.70.0" 1
    pt_write "$os_b" "version: v0.74.0" 1
    GATE_WORKFLOWS="$ci_b $os_b"
    pp_rc=0
    pp_out=$(check_parity) || pp_rc=$?
    st "check_parity: one workflow at v0.70.0 -> rc 1" "$pp_rc" "1"
    st "check_parity: MISMATCH names the mismatched file" \
        "$(printf '%s' "$pp_out" | grep -c "ci-b.yml: MISMATCH")" "1"

    # (c) one omits version: -> rc 1, MISSING
    ci_c="$pt_dir/ci-c.yml"
    os_c="$pt_dir/os-c.yml"
    pt_write "$ci_c" "" 1
    pt_write "$os_c" "version: v0.74.0" 1
    GATE_WORKFLOWS="$ci_c $os_c"
    pp_rc=0
    pp_out=$(check_parity) || pp_rc=$?
    st "check_parity: one workflow omits version: -> rc 1" "$pp_rc" "1"
    st "check_parity: omitted version reports MISSING" \
        "$(printf '%s' "$pp_out" | grep -c "ci-c.yml: MISSING")" "1"

    # (d) a fixture with no trivy-action step at all -> rc 1, "NO trivy-action step found"
    ci_d="$pt_dir/ci-d.yml"
    os_d="$pt_dir/os-d.yml"
    pt_write "$ci_d" "" 0
    pt_write "$os_d" "version: v0.74.0" 1
    GATE_WORKFLOWS="$ci_d $os_d"
    pp_rc=0
    pp_out=$(check_parity) || pp_rc=$?
    st "check_parity: a workflow with no trivy-action step -> rc 1" "$pp_rc" "1"
    st "check_parity: names the step-less file" \
        "$(printf '%s' "$pp_out" | grep -c "ci-d.yml: NO trivy-action step found")" "1"

    # (e) a bare version value (no leading v) is a MISMATCH, not accepted (#1290 fix 3): the real
    # chain (trivy-action -> setup-trivy -> trivy's install.sh) builds its release URL from the
    # declared value verbatim, so bare "0.74.0" 404s where "v0.74.0" resolves.
    ci_e="$pt_dir/ci-e.yml"
    os_e="$pt_dir/os-e.yml"
    pt_write "$ci_e" "version: 0.74.0" 1
    pt_write "$os_e" "version: v0.74.0" 1
    GATE_WORKFLOWS="$ci_e $os_e"
    pp_rc=0
    pp_out=$(check_parity) || pp_rc=$?
    st "check_parity: a bare version value (no v) -> rc 1" "$pp_rc" "1"
    st "check_parity: bare-form MISMATCH names the reason" \
        "$(printf '%s' "$pp_out" | grep -c "must carry the v")" "1"

    # (f) a LATER step's version: must not be attributed to the trivy step
    ci_f="$pt_dir/ci-f.yml"
    {
        printf '%s\n' "name: fixture" "jobs:" "  scan:" "    steps:" \
            "      - name: Scan image for CVEs (Trivy)" \
            "        uses: aquasecurity/trivy-action@deadbeef # v0.36.0" \
            "        with:" \
            "          image-ref: pithead-example:ci" \
            "          scanners: vuln" \
            "      - name: Unrelated step that happens to also take a version input" \
            "        uses: some/other-action@deadbeef" \
            "        with:" \
            "          version: v0.74.0"
    } >"$ci_f"
    GATE_WORKFLOWS="$ci_f $os_a"
    pp_rc=0
    pp_out=$(check_parity) || pp_rc=$?
    st "check_parity: a later step's version: is not attributed to the trivy step" \
        "$(printf '%s' "$pp_out" | grep -c "ci-f.yml: MISSING")" "1"
    st "check_parity: (f) fails overall" "$pp_rc" "1"

    # (g) preflight, with engine_version stubbed
    GATE_WORKFLOWS="$ci_a $os_a" # both at TRIVY_VERSION, from case (a)

    engine_version() { printf '0.70.0'; }
    pf_rc=0
    preflight >/dev/null 2>&1 || pf_rc=$?
    st "preflight: measured engine != TRIVY_VERSION -> rc 1" "$pf_rc" "1"

    engine_version() { printf '0.74.0'; }
    pf_rc=0
    preflight >/dev/null 2>&1 || pf_rc=$?
    st "preflight: measured engine matches + parity OK -> rc 0" "$pf_rc" "0"

    engine_version() { return 1; }
    pf_rc=0
    preflight >/dev/null 2>&1 || pf_rc=$?
    st "preflight: engine_version failing -> rc 1" "$pf_rc" "1"

    # The check_parity half of preflight is a real guard, not dead code: engine matches exactly,
    # but the gate's own workflows are out of parity (ci_b is MISMATCHED at v0.70.0, from case b).
    engine_version() { printf '%s' "$TRIVY_VERSION"; }
    GATE_WORKFLOWS="$ci_b $os_a"
    pf_rc=0
    preflight >/dev/null 2>&1 || pf_rc=$?
    st "preflight: engine matches but the gate's own parity is broken -> rc 1" "$pf_rc" "1"

    # Restore the real engine_version (unset -f would remove it outright, since the stubs above
    # redefined the same top-level function rather than shadowing it) before testing its own
    # parsing below.
    engine_version() {
        local out ver
        out="$(docker run --rm "$TRIVY_IMAGE" --version 2>/dev/null)" || return 1
        ver="$(printf '%s\n' "$out" | awk '/^Version: /{print $2; exit}')"
        [ -n "$ver" ] || return 1
        printf '%s' "$ver"
    }
    rm -rf "$pt_dir"

    # (h) engine_version's own parsing of `docker ... --version` output
    docker() { printf 'Version: 0.74.0\nVulnerability DB:\n  Version: 2\n'; }
    st "engine_version parses the first top-level Version: line" \
        "$(engine_version)" "0.74.0"

    docker() { printf 'Vulnerability DB:\n  Version: 2\n'; }
    ev_rc=0
    engine_version >/dev/null 2>&1 || ev_rc=$?
    st "engine_version: no top-level Version: line -> rc 1" "$ev_rc" "1"

    unset -f docker

    [ "$st_fail" = 0 ] && echo "trivyignore-watch self-test OK"
    exit "$st_fail"
fi

# --- --check-parity mode ------------------------------------------------------------------------
# Standalone entry point for `make lint-trivy-parity`: just the parity check, no docker, no
# image builds.
if [ "${1:-}" = "--check-parity" ]; then
    check_parity
    exit $?
fi

# --- real run ----------------------------------------------------------------------------------

preflight || exit 1
report "$IGNOREFILE"
exit $?

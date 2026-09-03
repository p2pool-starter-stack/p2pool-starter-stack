# shellcheck shell=bash
#
# Shared by tests/os/run.sh's leg 4 (drives it against the checkout's VERSION before the guest's
# OS-update run) and tests/stack/test-harness-tooling.sh (drives `--self-test`, tier 1, no guest):
# the version leg 4 makes the guest CLAIM to be running, so that the bundle stamped with the real
# VERSION is a genuine update. Both images come from the one checkout and the dashboard door refuses
# an equal target on purpose, so without this the leg could never get past its first download.
#
# It has to be done on this side. The obvious move — stamp the BUNDLE one patch newer — produces a
# bundle whose manifest and payload disagree, and that breaks two things at once. pithead-boot
# writes the `rolled_back` verdict purely by comparing the in-flight target to the booted slot's
# VERSION, before the health gate runs at all, so a mismatch reports a rollback that never
# happened. And STACK_VERSION is derived from that same VERSION file and tags all five first-party
# images, so a payload rewritten to match would send the post-update boot hunting image tags that
# were never published — turning the fake rollback into a real one.
#
# #1676: the helper used to decrement only the PATCH component and give up at 0 — and every minor
# release-prep tip is x.y.0, so the release gate (#1651) could not age the version on exactly the
# tips it exists to prove. Any value the downgrade guard orders BELOW the bundle serves (the floor
# leg plants its own 99.0.0 floor separately), so this steps down the lowest non-zero component and
# zeroes the ones below it: 1.20.1 -> 1.20.0, 1.20.0 -> 1.19.0, 2.0.0 -> 1.0.0. Only 0.0.0 has
# nothing below it.

# $1 = a version as VERSION carries it: X.Y.Z, digits only, no "v".
# Prints the aged version on stdout; exit 0 = aged, 1 = nothing sorts below it, or not X.Y.Z. On 1
# it prints NOTHING — the caller must never write a half-parsed value into the guest.
aged_version() {
    local major minor patch
    [[ "${1:-}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    major=$((10#${BASH_REMATCH[1]}))
    minor=$((10#${BASH_REMATCH[2]}))
    patch=$((10#${BASH_REMATCH[3]}))
    if [ "$patch" -gt 0 ]; then
        printf '%s.%s.%s' "$major" "$minor" "$((patch - 1))"
    elif [ "$minor" -gt 0 ]; then
        printf '%s.%s.0' "$major" "$((minor - 1))"
    elif [ "$major" -gt 0 ]; then
        printf '%s.0.0' "$((major - 1))"
    else
        return 1
    fi
}

# --- self-test (#1676) -----------------------------------------------------------------------
#
# Driven by `tests/os/aged-version.sh --self-test`, tier 1, no guest: the three step-down shapes
# (patch, minor, major), the one version with nothing below it, and the malformed inputs the helper
# must refuse rather than half-parse. Every aged value is also checked against an INDEPENDENT
# ordering (`sort -V`), so a helper that printed something not strictly older cannot pass on its
# own say-so.
_av_case() { # <input> <want-output|NONE> <want-rc>
    local got rc
    got=$(aged_version "$1")
    rc=$?
    if [ "$rc" != "$3" ]; then
        printf '  FAIL %q: rc %s, want %s\n' "$1" "$rc" "$3"
        return 1
    fi
    if [ "$2" = NONE ]; then
        [ -z "$got" ] && return 0
        printf '  FAIL %q: printed %q on refusal, want nothing\n' "$1" "$got"
        return 1
    fi
    if [ "$got" != "$2" ]; then
        printf '  FAIL %q: got %q, want %s\n' "$1" "$got" "$2"
        return 1
    fi
    if [ "$got" = "$1" ] || [ "$(printf '%s\n%s\n' "$got" "$1" | sort -V | head -n 1)" != "$got" ]; then
        printf '  FAIL %q: %s does not sort strictly below it\n' "$1" "$got"
        return 1
    fi
}

_av_self_test() {
    local n=0 f=0 input want rc
    while read -r input want rc; do
        n=$((n + 1))
        _av_case "$input" "$want" "$rc" || f=$((f + 1))
    done <<'CASES'
1.20.1 1.20.0 0
1.20.10 1.20.9 0
1.20.0 1.19.0 0
0.1.0 0.0.0 0
2.0.0 1.0.0 0
1.0.0 0.0.0 0
0.0.1 0.0.0 0
0.0.0 NONE 1
v1.20.0 NONE 1
1.20 NONE 1
1.20.0.1 NONE 1
1.20.0-rc1 NONE 1
CASES
    # The empty input cannot ride the table (read collapses it), and it is the shape an unreadable
    # VERSION hands the caller.
    n=$((n + 1))
    _av_case "" NONE 1 || f=$((f + 1))
    if [ "$f" -gt 0 ]; then
        printf '#1676 aged-version self-test FAILED: %s of %s cases\n' "$f" "$n"
        return 1
    fi
    printf '#1676 aged-version self-test passed (%s cases)\n' "$n"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--self-test" ]; then
    _av_self_test
    exit $?
fi

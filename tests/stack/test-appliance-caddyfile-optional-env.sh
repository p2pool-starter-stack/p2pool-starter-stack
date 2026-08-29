# shellcheck shell=bash
#
# Optional .env keys under `set -u` (#1246): generate_caddyfile must DEGRADE when an optional key
# is absent from the sourced .env, not abort the command that sourced it. Sourced by run.sh.
#
# THE DEFECT. `pithead` runs under `set -Eeuo pipefail`. The auth block is optional by design —
# rendered only when a dashboard password is configured — and it was guarded by
# `[ -n "$DASHBOARD_AUTH_HASH_B64" ]`. That guard handles an EMPTY value and crashes on an UNSET
# one, so any .env that legitimately lacks the key turned "render no auth block" into a fatal
# `DASHBOARD_AUTH_HASH_B64: unbound variable` in whatever command sourced it (render/apply/doctor,
# and the rotate-dashboard-onion path at 32-onion-provisioning.sh:209, where it was first seen).
#
# SCOPE, stated so this is not read as a general .env-robustness suite. What is asserted is ONE
# key's absence behaviour on ONE function. It says nothing about whether other keys are optional —
# they are mostly NOT: DASHBOARD_SECURE, HOST_IP and NETWORK_PREFIX are required, and defaulting
# them would convert a loud abort into a silent misconfiguration (for DASHBOARD_SECURE, a silent
# HTTPS-to-HTTP downgrade, since `[ "$DASHBOARD_SECURE" == "true" ]` fails closed to the plaintext
# branch). Their bare reads are deliberate and are not a gap this file is covering for.
#
# THE FIXTURE PROVES ITSELF, which matters more here than usual. A hand-built .env that happened to
# omit some OTHER required key would crash too, and "it crashed" would go green off the wrong key —
# identical failure text across cases that should differ is exactly how that hides. Two guards: the
# absent-key case asserts rc 0 and a NON-EMPTY render, so a second missing key reddens it loudly
# rather than passing; and the mutant cases assert on the KEY NAME in the message, not on rc.
#
# THE MUTANT IS BUILT IN rather than left to a manual pass. #1246 names its own mutation — respell
# the default back off — so this file applies it to a COPY of $STACK, proves the copy really differs
# from the original (a replace that does not match writes an unchanged file and reads as a pass),
# and asserts the copy fails on the absent key and still succeeds on the present one. Without that
# pair the absent-key assertion is equally consistent with a guard that was never load-bearing.
#
# Re-derivations: $SANDBOX, $STACK and the assert_* helpers come from lib.sh. Every other name is
# assigned here under a COE/coe_ prefix — every domain file is sourced into ONE shell, so an
# unprefixed name would collide. coe_render deliberately does NOT reuse lib.sh's run_sourced: that
# helper sources $STACK only, and the whole point of #1246 is the context that sources a partial
# .env FIRST, so the .env step has to be inside the same subshell.

: "${SANDBOX:?}"
: "${STACK:?}"

COE="$SANDBOX/caddyfile-optional-env"
mkdir -p "$COE"

# A .env carrying every key generate_caddyfile reads. `with-auth` appends the auth PAIR — 33-render-
# env.sh emits DASHBOARD_AUTH_USER (:479) and DASHBOARD_AUTH_HASH_B64 (:480) adjacently and
# unconditionally, so a .env predating the feature lacks both, and no realistic file splits them.
coe_write_env() { # <path> [with-auth]
    cat >"$1" <<'EOF'
DASHBOARD_SECURE=false
HOST_IP=192.168.1.50
NETWORK_PREFIX=172.28.0
HOST_PORT=
DASHBOARD_HOST=
DASHBOARD_ONION=
CADDY_LOG_DIR=/var/log/caddy
EOF
    if [ "${2:-}" = "with-auth" ]; then
        printf 'DASHBOARD_AUTH_USER=admin\nDASHBOARD_AUTH_HASH_B64=%s\n' \
            "$(printf '%s' '$2y$14$examplebcrypthashvalue' | openssl base64 -A)" >>"$1"
    fi
}

# Render with <stack> after sourcing <envfile>, in one subshell, exactly as a real caller does.
# Prints stdout+stderr; the Caddyfile is left in $COE for inspection.
coe_render() { # <stack> <envfile>
    (
        cd "$COE" || exit 127
        rm -f Caddyfile
        set -a
        # shellcheck disable=SC1090  # fixture path is dynamic by design
        . "$2"
        set +a
        # shellcheck disable=SC1090  # STACK path is dynamic by design
        . "$1"
        set +e
        generate_caddyfile
    ) 2>&1
}

coe_partial="$COE/env-partial"
coe_full="$COE/env-full"
coe_write_env "$coe_partial"
coe_write_env "$coe_full" with-auth

# THREE states, not two. A plain "does the Caddyfile contain basic_auth" is vacuous on a render
# that DIED, because the absent file trivially satisfies it — measured, not theorised: an earlier
# two-state form of this file scored that assertion GREEN against the pre-fix artifact for exactly
# that reason. Classifying `missing` apart from `no-auth` is what makes each case below able to
# fail; `reverse_proxy` is the marker because every vhost the function can emit carries one.
coe_state() {
    local f="$COE/Caddyfile"
    grep -q 'reverse_proxy 127.0.0.1:8000' "$f" 2>/dev/null || {
        printf 'missing'
        return
    }
    if grep -q 'basic_auth' "$f" 2>/dev/null; then printf 'with-auth'; else printf 'no-auth'; fi
}

echo "== black-box: the shipped pithead renders without the optional dashboard auth key (#1246) =="
coe_out="$(coe_render "$STACK" "$coe_partial")"
coe_rc=$?
assert_rc "#1246: render survives a .env with no DASHBOARD_AUTH_HASH_B64" "$coe_rc" 0
assert_eq "#1246: it renders a real Caddyfile and degrades to no auth block" "$(coe_state)" "no-auth"

# Positive control for the classifier: it MUST report with-auth when the key is present. "no-auth"
# is worth nothing until the same instrument has been shown finding an auth block that is there.
coe_render "$STACK" "$coe_full" >/dev/null 2>&1
assert_eq "#1246 control: the auth block IS rendered when the key is present" "$(coe_state)" "with-auth"

echo "== black-box: the same render with the default respelled off aborts instead (#1246) =="
coe_mutant="$COE/pithead-mutant"
sed 's|\${DASHBOARD_AUTH_HASH_B64:-}|$DASHBOARD_AUTH_HASH_B64|' "$STACK" >"$coe_mutant"
chmod +x "$coe_mutant"
# A sed that matched nothing writes an unchanged file, and every assertion below would then be
# testing the shipped artifact twice while reading as a mutation battery.
if cmp -s "$STACK" "$coe_mutant"; then
    bad "#1246 mutant applied" "sed matched nothing: \${DASHBOARD_AUTH_HASH_B64:-} not found in \$STACK"
else
    ok "#1246 mutant applied"
fi

coe_out="$(coe_render "$coe_mutant" "$coe_partial")"
coe_rc=$?
# Assert on the KEY NAME, not on rc: any other missing key would also produce a non-zero rc, and
# that is the failure this whole file is built to not mistake for the one it is looking for.
assert_contains "#1246 mutant: without the default, the absent key aborts the render" \
    "$coe_out" "DASHBOARD_AUTH_HASH_B64: unbound variable"
assert_eq "#1246 mutant: and the abort leaves no Caddyfile at all" "$(coe_state)" "missing"

# The mutation must be targeted. If the mutant failed on the PRESENT key too, the cases above would
# be reporting a broken copy of pithead rather than the guard being load-bearing.
coe_render "$coe_mutant" "$coe_full" >/dev/null 2>&1
coe_rc=$?
assert_rc "#1246 mutant: still renders fine when the key IS present" "$coe_rc" 0
assert_eq "#1246 mutant: and that render still carries the auth block" "$(coe_state)" "with-auth"

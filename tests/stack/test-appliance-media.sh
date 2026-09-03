# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Appliance media domain (#1105 Phase 1, develop-v2 lane): the physical-presence config channel
# (#786 sub-issue D) — a FAT stick carrying pithead-config.json, consumed on the boot leg by
# os/overlay/pithead-media-config. Nine sections cover removable-partition discovery, finding and
# merging the staged file (settings the stick does not name keep their running values), validating
# it through the same engine the pre-seed path uses, the masked diff that still shows the wallet in
# full, the abort/apply confirm gate with no real 60s wait, consuming the file off the medium
# (deleted, never renamed), and main()'s identical-config short-circuit against a real apply.
# Sourced by tests/stack/run.sh.
#
# The block is contiguous and its source stanza sits at its exact former position, so execution
# order is unchanged — a pure relocation, not a regrouping.
#
# Re-derivations: none. $SANDBOX, $ROOT and the VALID_* address fixtures come from lib.sh; every
# other name is assigned here — $MC and the seven $STICK* trees beneath it, $RUN_CFG, $MOUNT_SRC,
# $MOUNT_LOG — and the media_* and _secret_paths_json functions come from
# $ROOT/os/overlay/pithead-media-config, which each section sources for itself rather than relying
# on an ambient one. Every write in the file lands under $MC ($SANDBOX/media-config): nothing
# touches the ambient $V, $C or $STACK, and nothing outside this file reads what it creates.

echo "== unit: pithead-media-config — physical-presence media channel (#786 sub-issue D) =="
# Source the boot leg (functions only — its main is guarded) and drive its pieces with stubbed
# lsblk/mount/umount and a real (sandboxed) copy of pithead for validation — the same two-layer
# style pithead-data-reset's block above uses: fake the hardware, keep the decision logic real.
MC="$SANDBOX/media-config"
mkdir -p "$MC/bin"
cp "$ROOT/pithead" "$ROOT/config.reference.json" "$ROOT/config.core-keys.json" "$MC/"

# lsblk stub: prints whatever TSV the test staged, so _removable_fat_partitions' own awk filter
# runs for real against controlled input.
cat >"$MC/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
cat "${LSBLK_OUT:?}"
EOF
# mount stub: simulates `mount -o <ro|rw> <device> <mountpoint>` by copying $MOUNT_SRC's contents
# into the mountpoint (refusing any device but the one under test) and logging the mountpoint so
# a test can inspect what ended up there after an in-script `rm` — real bind semantics are a KVM
# concern; the decision logic (which device, which flag, what gets removed) is not.
cat >"$MC/bin/mount" <<'EOF'
#!/usr/bin/env bash
# Flag-agnostic: the channel mounts with pinned-type/hardening options (-t vfat -o ro,nosuid,...),
# so device and mountpoint are simply the last two arguments.
argv=("$@")
n=${#argv[@]}
dev="${argv[n - 2]}" mnt="${argv[n - 1]}"
[ "$dev" = "${MOUNT_DEVICE:-/dev/fake1}" ] || exit 1
mkdir -p "$mnt"
cp -a "${MOUNT_SRC:-/dev/null}"/. "$mnt"/ 2>/dev/null
[ -n "${MOUNT_LOG:-}" ] && printf '%s\n' "$mnt" >>"$MOUNT_LOG"
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$MC/bin/umount"
chmod +x "$MC/bin/lsblk" "$MC/bin/mount" "$MC/bin/umount"

# A merged config that carries dashboard.auth.password sends media_validate_config's fresh bash
# into parse_and_validate_config's caddy hash branch, which greps docker-compose.yml at CWD for
# the pinned image and shells out to `docker run`. Give this section the #8 auth tests' hash-
# answering docker stub plus a caddy-pinned one-line compose fixture, and run those legs from
# $MC — the hash lands on the stub, never on a real (network-reaching) docker or the repo's
# compose file.
make_stubs "$MC/bin"
printf 'image: caddy:0.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000\n' >"$MC/docker-compose.yml"

printf 'sda\tdisk\t0\t\nsda1\tpart\t0\text4\nsdb\tdisk\t1\t\nsdb1\tpart\t1\tvfat\n' >"$MC/lsblk-out"

echo "== unit: _removable_fat_partitions =="
out=$(
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    source "$ROOT/os/overlay/pithead-media-config"
    _removable_fat_partitions
)
assert_eq "removable FAT partitions filtered from lsblk (skips internal disk + a non-FAT removable)" "$out" "/dev/sdb1"

echo "== unit: media_find_config =="
STICK="$MC/stick"
mkdir -p "$STICK"
printf '{"staged":true}' >"$STICK/pithead-config.json"
result=$(
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$STICK"
    source "$ROOT/os/overlay/pithead-media-config"
    media_find_config
)
assert_eq "media_find_config names the carrying partition" "${result%%$'\t'*}" "/dev/sdb1"
found_copy="${result#*$'\t'}"
if [ -s "$found_copy" ] && cmp -s "$found_copy" "$STICK/pithead-config.json"; then
    ok "media_find_config copies the staged file out unmodified"
else
    bad "media_find_config copies the staged file out unmodified" "missing or altered: $found_copy"
fi
rm -f "$found_copy"

rc=$(
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$MC/empty-stick"
    mkdir -p "$MOUNT_SRC"
    source "$ROOT/os/overlay/pithead-media-config"
    media_find_config >/dev/null 2>&1
    echo $?
)
assert_eq "media_find_config returns 1 when no candidate carries the file" "$rc" "1"

echo "== unit: media_merge_config (settings the stick does not name keep their running values) =="
cat >"$MC/running-full.json" <<EOF
{"monero":{"wallet_address":"$VALID_PRIMARY","node_username":"admin","node_password":"a-generated-password-1"},"tari":{"wallet_address":"$VALID_TARI"},"p2pool":{"pool":"mini","stratum_password":"auto"},"dashboard":{"auth":{"password":"the-firstboot-password"},"control":{"enabled":true}},"tor":{"auto_heal":true}}
EOF
printf '{"p2pool":{"pool":"nano"}}' >"$MC/minimal-stick.json"
merged=$(
    source "$ROOT/os/overlay/pithead-media-config"
    media_merge_config "$MC/running-full.json" "$MC/minimal-stick.json"
)
assert_eq "the named setting changes" "$(jq -r '.p2pool.pool' "$merged")" "nano"
# THE assertion that separates a deep merge from a shallow one. Every other check below reads a
# key in a top-level object the stick never names, and `.[0] + .[1]` preserves those too — so the
# suite stayed byte-identical under the one-character mutation that reverts the merge and re-opens
# #965. stratum_password is the sibling of the key the stick DOES name: a shallow merge replaces
# the whole p2pool object and takes the secret with it.
assert_eq "a secret beside the named key survives — the merge is deep, not a shallow replace" \
    "$(jq -r '.p2pool.stratum_password' "$merged")" "auto"
assert_eq "the unnamed dashboard password is preserved, not dropped" \
    "$(jq -r '.dashboard.auth.password' "$merged")" "the-firstboot-password"
assert_eq "the unnamed appliance defaults are preserved (control.enabled)" \
    "$(jq -r '.dashboard.control.enabled' "$merged")" "true"
assert_eq "the unnamed appliance defaults are preserved (tor.auto_heal)" \
    "$(jq -r '.tor.auto_heal' "$merged")" "true"
assert_eq "unnamed node credentials carry forward — validation has nothing left to regenerate" \
    "$(jq -r '.monero.node_password' "$merged")" "a-generated-password-1"
rm -f "$merged"

printf '{"tor":{"auto_heal":null}}' >"$MC/null-stick.json"
merged=$(
    source "$ROOT/os/overlay/pithead-media-config"
    media_merge_config "$MC/running-full.json" "$MC/null-stick.json"
)
assert_eq "naming a setting null clears it — the documented unset spelling" \
    "$(jq -r '.tor.auto_heal == null' "$merged")" "true"
rm -f "$merged"

printf 'not json at all' >"$MC/broken-stick.json"
merged=$(
    source "$ROOT/os/overlay/pithead-media-config"
    media_merge_config "$MC/running-full.json" "$MC/broken-stick.json"
)
if cmp -s "$MC/broken-stick.json" "$merged"; then
    ok "an unmergeable stick file passes through as-is, so validation reports ITS error"
else
    bad "an unmergeable stick file passes through as-is" "merge altered or dropped it"
fi
rm -f "$merged"

echo "== unit: media_validate_config (reuses the pre-seed validation engine) =="
cat >"$MC/good.json" <<EOF
{"monero":{"wallet_address":"$VALID_PRIMARY","node_username":"admin","node_password":"a-generated-password-1"},"tari":{"wallet_address":"$VALID_TARI"},"p2pool":{"pool":"mini","stratum_password":"auto"}}
EOF
cat >"$MC/bad.json" <<'EOF'
{"monero":{"wallet_address":"nope"},"tari":{"wallet_address":"t"}}
EOF
validated=$(
    export PITHEAD_MEDIA_BIN="$MC/pithead"
    source "$ROOT/os/overlay/pithead-media-config"
    media_validate_config "$MC/good.json"
)
if [ -s "$validated" ]; then
    ok "a valid candidate validates and yields a scratch file"
else
    bad "a valid candidate validates and yields a scratch file" "no output"
fi
if cmp -s "$MC/good.json" "$validated"; then
    ok "a candidate that already carries its node credentials validates byte-identical"
else
    bad "a candidate that already carries its node credentials validates byte-identical" "$(diff "$MC/good.json" "$validated" 2>&1 | head -3)"
fi
rm -f "$validated"

rc=$(
    export PITHEAD_MEDIA_BIN="$MC/pithead"
    source "$ROOT/os/overlay/pithead-media-config"
    media_validate_config "$MC/bad.json" >/dev/null 2>&1
    echo $?
)
assert_eq "an invalid candidate is rejected, not installed" "$rc" "1"

echo "== unit: media_config_diff / media_config_identical (masked, wallet shown in full) =="
cat >"$MC/changed.json" <<EOF
{"monero":{"wallet_address":"44MnN1f3Eto8DZYUWuE5XZNUtE3vcRzt2j6PzqWpPau34e6Cf4fAxt6X2MBmrm6F9YMEiMNjN6W4Shn4pLcfNAja621jwyg","node_username":"admin","node_password":"a-generated-password-1"},"tari":{"wallet_address":"$VALID_TARI"},"p2pool":{"pool":"mini","stratum_password":"auto"},"dashboard":{"auth":{"password":"a-new-dashboard-password"}}}
EOF
diffout=$(
    export PITHEAD_MEDIA_BIN="$MC/pithead"
    source "$ROOT/os/overlay/pithead-media-config"
    SECRET_PATHS_JSON=$(_secret_paths_json) # the real fetch, against the sandboxed pithead copy
    media_config_diff "$MC/good.json" "$MC/changed.json"
)
assert_contains "the payout wallet change shows old -> new in full (that IS the point)" "$diffout" "$VALID_PRIMARY -> 44MnN1f3Eto8DZYUWuE5XZNUtE3vcRzt2j6PzqWpPau34e6Cf4fAxt6X2MBmrm6F9YMEiMNjN6W4Shn4pLcfNAja621jwyg"
assert_contains "a changed secret (dashboard password) names the path" "$diffout" "dashboard.auth.password"
assert_not_contains "a changed secret never shows the new value" "$diffout" "a-new-dashboard-password"

rc=$(
    export PITHEAD_MEDIA_BIN="$MC/pithead"
    source "$ROOT/os/overlay/pithead-media-config"
    SECRET_PATHS_JSON=$(_secret_paths_json)
    media_config_identical "$MC/good.json" "$MC/good.json"
    echo $?
)
assert_eq "identical configs -> media_config_identical true" "$rc" "0"
rc=$(
    export PITHEAD_MEDIA_BIN="$MC/pithead"
    source "$ROOT/os/overlay/pithead-media-config"
    # shellcheck disable=SC2034 # read by the sourced media_config_* functions, not directly here
    SECRET_PATHS_JSON=$(_secret_paths_json)
    media_config_identical "$MC/good.json" "$MC/changed.json"
    echo $?
)
assert_eq "a real change -> media_config_identical false" "$rc" "1"

# Masking fails CLOSED: with no secret-path list there is no diff and no "identical" verdict —
# an earlier draft fell back to an empty list, which printed raw secret values to the console.
rc=$(
    export PITHEAD_MEDIA_BIN="$MC/does-not-exist"
    source "$ROOT/os/overlay/pithead-media-config"
    _secret_paths_json >/dev/null 2>&1
    echo $?
)
assert_eq "an unreadable host program -> _secret_paths_json refuses (rc 1, never '[]')" "$rc" "1"
out=$(
    source "$ROOT/os/overlay/pithead-media-config"
    SECRET_PATHS_JSON="" media_config_diff "$MC/good.json" "$MC/changed.json"
    echo "rc=$?"
)
assert_eq "no secret list -> no diff output, distinct rc" "$out" "rc=2"
rc=$(
    source "$ROOT/os/overlay/pithead-media-config"
    SECRET_PATHS_JSON="" media_config_identical "$MC/good.json" "$MC/good.json"
    echo $?
)
assert_eq "no secret list -> identical is NOT assumed (fail closed)" "$rc" "1"

echo "== unit: media_confirm_gate (abort/apply state machine, no real 60s wait) =="
gate() { # $1 device-present override rc, $2 key sequence (space-separated, 'timeout' = no key)
    # shellcheck disable=SC2206  # deliberate word-splitting: $2 is a space-separated key sequence
    local present_rc="$1" keys=($2) i=0
    (
        source "$ROOT/os/overlay/pithead-media-config"
        media_device_present() { return "$present_rc"; }
        media_read_key() {
            local k="${keys[$i]:-timeout}"
            i=$((i + 1))
            [ "$k" = "timeout" ] && return 1
            printf '%s' "$k"
        }
        media_confirm_gate /dev/fake 3
    )
}
assert_eq "countdown exhausted with no keypress -> apply" "$(gate 0 'timeout timeout timeout')" "apply"
assert_eq "media removed mid-countdown -> abort" "$(gate 1 '')" "abort"
assert_eq "'a' keypress -> apply immediately, before the countdown ends" "$(gate 0 a)" "apply"
assert_eq "'n' keypress -> abort immediately" "$(gate 0 n)" "abort"
assert_eq "an unrecognized key is ignored, not treated as abort" "$(gate 0 'x x apply')" "apply"

echo "== unit: media_consume (deletes the staged file on the medium, never renames it) =="
STICK2="$MC/stick2"
mkdir -p "$STICK2"
printf '{"staged":true}' >"$STICK2/pithead-config.json"
: >"$MC/mount.log"
(
    export PATH="$MC/bin:$PATH"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$STICK2" MOUNT_LOG="$MC/mount.log"
    source "$ROOT/os/overlay/pithead-media-config"
    media_consume "/dev/sdb1"
)
mounted_at=$(tail -1 "$MC/mount.log")
if [ -n "$mounted_at" ] && [ ! -f "$mounted_at/pithead-config.json" ]; then
    ok "the consumed configuration is removed from the medium (installer's own hygiene, not a renamed copy)"
else
    bad "the consumed configuration is removed from the medium" "still present at ${mounted_at:-<no mount>}"
fi

echo "== unit: pithead-media-config main() — identical short-circuit vs. a real apply =="
RUN_CFG="$MC/running.json"
cp "$MC/good.json" "$RUN_CFG"
STICK3="$MC/stick-identical"
mkdir -p "$STICK3"
cp "$MC/good.json" "$STICK3/pithead-config.json"
: >"$MC/mount.log"
(
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$STICK3" MOUNT_LOG="$MC/mount.log"
    export PITHEAD_MEDIA_BIN="$MC/pithead" PITHEAD_MEDIA_CONFIG="$RUN_CFG" PITHEAD_MEDIA_DIR="$MC"
    source "$ROOT/os/overlay/pithead-media-config"
    media_confirm_gate() {
        echo "media_confirm_gate must not be called for an identical config" >&2
        echo apply
    }
    main
) >"$MC/identical.out" 2>&1
if cmp -s "$MC/good.json" "$RUN_CFG"; then
    ok "an identical staged config never touches the running config.json"
else
    bad "an identical staged config never touches the running config.json" "it was rewritten"
fi
assert_not_contains "an identical config never reaches the confirm gate (no ceremony)" "$(cat "$MC/identical.out")" "must not be called"
assert_contains "an identical config says so on the console" "$(cat "$MC/identical.out")" "would change nothing"
[ -f "$STICK3/pithead-config.json" ] && ok "an identical config is not consumed — nothing was applied" ||
    bad "an identical config is not consumed" "the stick's file was removed anyway"

STICK4="$MC/stick-apply"
mkdir -p "$STICK4"
cp "$MC/changed.json" "$STICK4/pithead-config.json"
: >"$MC/mount.log"
(
    cd "$MC" || exit 1 # changed.json carries dashboard.auth.password — the hash branch needs $MC's compose fixture + docker stub
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$STICK4" MOUNT_LOG="$MC/mount.log"
    export PITHEAD_MEDIA_BIN="$MC/pithead" PITHEAD_MEDIA_CONFIG="$RUN_CFG" PITHEAD_MEDIA_DIR="$MC"
    source "$ROOT/os/overlay/pithead-media-config"
    media_confirm_gate() { echo apply; }
    main
) >"$MC/apply.out" 2>&1
# jq-level equality, not cmp: the merge stage reformats, and changed.json names every key
# good.json has, so the merged result must equal changed.json setting-for-setting.
if [ "$(jq -S . "$MC/changed.json")" = "$(jq -S . "$RUN_CFG")" ]; then
    ok "a confirmed change is written to the running config.json — the changed setting took effect"
else
    bad "a confirmed change is written to the running config.json" "$(diff <(jq -S . "$MC/changed.json") <(jq -S . "$RUN_CFG") 2>&1 | head -3)"
fi
mounted_at=$(tail -1 "$MC/mount.log")
[ -n "$mounted_at" ] && [ ! -f "$mounted_at/pithead-config.json" ] &&
    ok "the applied stick is consumed so it cannot re-apply next boot" ||
    bad "the applied stick is consumed" "still present"
assert_contains "the applied change is announced on the console" "$(cat "$MC/apply.out")" "applied"

STICK5="$MC/stick-abort"
mkdir -p "$STICK5"
cp "$MC/changed.json" "$STICK5/pithead-config.json"
cp "$MC/good.json" "$RUN_CFG"
: >"$MC/mount.log"
(
    cd "$MC" || exit 1 # changed.json carries dashboard.auth.password — see the stub note above
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$STICK5" MOUNT_LOG="$MC/mount.log"
    export PITHEAD_MEDIA_BIN="$MC/pithead" PITHEAD_MEDIA_CONFIG="$RUN_CFG" PITHEAD_MEDIA_DIR="$MC"
    source "$ROOT/os/overlay/pithead-media-config"
    media_confirm_gate() { echo abort; }
    main
) >"$MC/abort.out" 2>&1
if cmp -s "$MC/good.json" "$RUN_CFG"; then
    ok "a cancelled change never touches the running config.json"
else
    bad "a cancelled change never touches the running config.json" "it was rewritten"
fi
[ -f "$STICK5/pithead-config.json" ] && ok "a cancelled change is not consumed — the stick still carries it" ||
    bad "a cancelled change is not consumed" "the stick's file was removed anyway"
# #1061: the running config staying untouched is not proof the operator was ever told — a
# cancelled change looks identical to a silent one from that assertion alone. This is the one
# that would have caught the console promising a confirmation that never appeared.
assert_contains "the cancelled change is announced on the console" "$(cat "$MC/abort.out")" \
    "Media configuration channel: cancelled — no changes applied."

# main() must FAIL CLOSED end to end when the secret-path list can't be read: with a broken host
# program, no diff (which could leak raw secret values) is ever shown and no config is applied.
STICK6="$MC/stick-nosecrets"
mkdir -p "$STICK6"
cp "$MC/changed.json" "$STICK6/pithead-config.json"
cp "$MC/good.json" "$RUN_CFG"
: >"$MC/mount.log"
(
    cd "$MC" || exit 1 # changed.json carries dashboard.auth.password — see the stub note above
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$STICK6" MOUNT_LOG="$MC/mount.log"
    # Validation still works (real pithead), but the secret-path fetch reads a DIFFERENT, broken
    # binary — the one place masking could silently turn off.
    export PITHEAD_MEDIA_BIN="$MC/pithead" PITHEAD_MEDIA_CONFIG="$RUN_CFG" PITHEAD_MEDIA_DIR="$MC"
    source "$ROOT/os/overlay/pithead-media-config"
    _secret_paths_json() { return 1; }             # simulate an unreadable/broken host program
    media_config_diff() { echo "DIFF-WAS-SHOWN"; } # would leak values if ever reached
    media_confirm_gate() { echo apply; }
    main
) >"$MC/nosecrets.out" 2>&1
assert_eq "no secret list -> the running config is never rewritten" "$(cmp -s "$MC/good.json" "$RUN_CFG" && echo same)" "same"
assert_not_contains "no secret list -> no diff is ever displayed" "$(cat "$MC/nosecrets.out")" "DIFF-WAS-SHOWN"
assert_contains "no secret list -> the stage refuses out loud" "$(cat "$MC/nosecrets.out")" "cannot read the secret-path list"

# The issue-965 shape end to end: a stick naming ONLY the pool tier must change the pool tier
# and NOTHING else — the generated dashboard login, the appliance defaults and the node
# credentials all survive, and none of them appear in the console diff as a change.
STICK7="$MC/stick-minimal"
mkdir -p "$STICK7"
cp "$MC/minimal-stick.json" "$STICK7/pithead-config.json"
cp "$MC/running-full.json" "$RUN_CFG"
: >"$MC/mount.log"
(
    cd "$MC" || exit 1 # the merged config carries the running dashboard.auth.password — see the stub note above
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$STICK7" MOUNT_LOG="$MC/mount.log"
    export PITHEAD_MEDIA_BIN="$MC/pithead" PITHEAD_MEDIA_CONFIG="$RUN_CFG" PITHEAD_MEDIA_DIR="$MC"
    source "$ROOT/os/overlay/pithead-media-config"
    media_confirm_gate() { echo apply; }
    main
) >"$MC/minimal.out" 2>&1
assert_eq "minimal stick: the named setting applies (p2pool.pool)" "$(jq -r '.p2pool.pool' "$RUN_CFG")" "nano"
assert_eq "minimal stick: the dashboard password it never named is kept, not dropped or regenerated" \
    "$(jq -r '.dashboard.auth.password' "$RUN_CFG")" "the-firstboot-password"
assert_eq "minimal stick: dashboard.control.enabled survives" "$(jq -r '.dashboard.control.enabled' "$RUN_CFG")" "true"
assert_eq "minimal stick: tor.auto_heal survives" "$(jq -r '.tor.auto_heal' "$RUN_CFG")" "true"
assert_eq "minimal stick: node credentials do not churn" "$(jq -r '.monero.node_password' "$RUN_CFG")" "a-generated-password-1"
assert_contains "minimal stick: the diff names the one real change" "$(cat "$MC/minimal.out")" "p2pool.pool: mini -> nano"
assert_not_contains "minimal stick: nothing unnamed shows up as changed" "$(cat "$MC/minimal.out")" "dashboard.auth.password"
assert_contains "minimal stick: the console states the keep-what-you-do-not-name rule" \
    "$(cat "$MC/minimal.out")" "Settings the file does not name keep their current values."

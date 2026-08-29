# shellcheck shell=bash
#
# Unit-helper domain (#1105 Phase 1, develop-v2 lane): the cluster of small helper tests that sat
# at the head of run.sh. Four of them drive a pithead function through run_sourced and assert its
# return code or its stdout — docker_boot_enabled (a systemctl stub on PATH decides which unit
# reports enabled, and docker.service or docker.socket each count on their own), config_bool (a
# config value written explicitly false must stay false rather than be coerced by jq's // default,
# the #294 regression that silently re-enabled the firewall opt-out), env_get_file and
# env_changed_keys (a value containing an "=" survives intact, and only the keys that differ are
# reported), and export_build_provenance (the VERSION file is read and whitespace-trimmed, and an
# absent VERSION yields an empty version rather than an error). The fifth block is a drift guard
# rather than a unit test: it pins the XvB tier thresholds in the dashboard's config.py against the
# human forms written in docs/architecture.md, so the user-facing table cannot fall out of sync
# with TIER_DEFAULTS unnoticed.
# Sourced by tests/stack/run.sh.
#
# NAMED FOR WHAT IT HOLDS. The cut map filed this range under "config-helpers"; of the five blocks
# only config_bool is a config helper, the XvB block is not a helper test at all, and
# tests/stack/test-config.sh already exists — a near-identical neighbour name would send a reader
# to the wrong file.
#
# THIS CUT REORDERS, and saying so is the point. The range is NOT contiguous: domain source
# stanzas are interleaved between these blocks, and every one of them is EXCLUDED from the cut
# rather than nested. (Nesting a stanza would leave the outer domain_ran guard reading the value
# the nested stanza set, so the extracted content would carry zero zero-assertion coverage — not
# narrowed coverage, zero.) Excluding them leaves three pieces, so one vacated position takes the
# source stanza and the others close up. The anchor is the last piece's position, chosen because it
# leaves the most sections standing: the XvB, env-helper and provenance blocks execute exactly
# where they always did, and only the docker_boot_enabled and config_bool blocks move later. They
# do not cross the same set. docker_boot_enabled now runs after test-control-upgrade.sh,
# test-release-signing.sh, test-dashboard.sh, test-dashboard-onion.sh and test-release.sh;
# config_bool after the last three of those. Every other domain file keeps its position.
#
# WHY THAT REORDER IS SAFE, argued in both directions.
#   Outward: the names these blocks assign — $BOOT, $tier_cfg, $tier_doc, $changed, $PROV, $NOVER,
#   $ver and the drift loop's own $tier, $t_name, $t_rest, $t_val and $t_human — are read nowhere
#   else, in run.sh or anywhere else under tests/stack. Swept per name over every tests/stack/*.sh
#   with comments stripped first, because a comment naming a variable is not a read and this lane
#   has been bitten by that three times; the surviving hits were then read individually rather than
#   counted. The
#   one shared name is $CB: this file's config_bool block and tests/stack/test-monero-tari.sh both
#   work in $SANDBOX/cb. That file assigns $CB, mkdir -p's it and writes its own config.json, so it
#   inherits nothing from here — and its stanza is sourced after this file's stanza both before and
#   after the cut.
#   Inward: these blocks read only $SANDBOX, $ROOT and $STACK, each assigned at COLUMN 1 at top
#   level in lib.sh, outside every function body — so none of them is the ordering dependency the
#   $WALLET case turned out to be. (Re-derive by grepping lib.sh for the assignment and reading the
#   indent, not by line number: a citation into another file is the perishable part of any claim
#   here.) The domain files the two moved blocks now run after reassign none of those three and
#   create no systemctl stub that could shadow this file's own; every PATH replacement and every cd
#   in them is confined to a subshell or to a function whose whole body is a subshell. Every path
#   this file writes or reads is anchored on $SANDBOX, $ROOT or $STACK, or is reached by an
#   explicit cd inside a command substitution, so a leaked working directory could not reach them
#   either.
#   The provider functions called are run_sourced, assert_rc, assert_eq, ok and bad.

: "${ROOT:?}" "${SANDBOX:?}" "${STACK:?}"

echo "== unit: docker_boot_enabled (#137) =="
# A systemctl stub on PATH; FAKE_BOOT picks which unit reports "enabled". Docker counts as
# boot-enabled if EITHER docker.service or docker.socket is enabled.
BOOT="$SANDBOX/boot"
mkdir -p "$BOOT/bin"
cat >"$BOOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "is-enabled docker.service") [ "${FAKE_BOOT:-}" = "service" ] && exit 0 || exit 1 ;;
  "is-enabled docker.socket")  [ "${FAKE_BOOT:-}" = "socket"  ] && exit 0 || exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BOOT/bin/systemctl"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=service run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "docker.service enabled -> 0" "$?" "0"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=socket run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "docker.socket enabled -> 0" "$?" "0"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=none run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "neither enabled -> 1" "$?" "1"

echo "== unit: config_bool honours an explicit false (jq // false-coercion guard, #294) =="
# Regression for #294: `.x // true` returns true even when x is explicitly false (jq treats false as
# empty), which silently broke the #270 firewall opt-out (config false → .env stayed true) and
# xvb.tor=false. config_bool null-checks instead. CONFIG_FILE is the relative "config.json", so a
# fixture in the cwd is what the sourced helper reads.
CB="$SANDBOX/cb"
mkdir -p "$CB"
printf '{"network":{"tor_egress_firewall":false},"xvb":{"tor":false}}' >"$CB/config.json"
assert_eq "explicit false honoured (firewall)" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "false"
assert_eq "explicit false honoured (xvb.tor)" "$(run_sourced "$CB" config_bool '.xvb.tor' true)" "false"
printf '{"network":{"tor_egress_firewall":true}}' >"$CB/config.json"
assert_eq "explicit true honoured" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "true"
printf '{}' >"$CB/config.json"
assert_eq "absent -> default true" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "true"
assert_eq "absent -> default false" "$(run_sourced "$CB" config_bool '.xvb.tor' false)" "false"

# The XvB tier thresholds are hard-coded in config.py (TIER_DEFAULTS) and stated explicitly in
# docs/architecture.md. Drift guard: each config value must match the doc's human form, so the
# user-facing table can't silently fall out of sync if TIER_DEFAULTS ever changes.
tier_cfg="$ROOT/dashboard/mining_dashboard/config/config.py"
tier_doc="$ROOT/docs/architecture.md"
for tier in "donor:1_000:1 kH/s" "vip:10_000:10 kH/s" "whale:100_000:100 kH/s" "mega:1_000_000:1 MH/s"; do
    t_name="${tier%%:*}"
    t_rest="${tier#*:}"
    t_val="${t_rest%%:*}"
    t_human="${t_rest#*:}"
    if grep -qE ": ${t_val}[ ,]" "$tier_cfg" && grep -qF "$t_human" "$tier_doc"; then
        ok "XvB $t_name tier: config.py $t_val matches docs '$t_human'"
    else
        bad "XvB $t_name tier docs match TIER_DEFAULTS" "config $t_val / doc '$t_human' out of sync"
    fi
done

echo "== unit: env helpers =="
printf 'A=1\nB=two\nPROXY_AUTH_TOKEN=keep=me\n' >"$SANDBOX/old.env"
printf 'A=1\nB=three\nC=4\nPROXY_AUTH_TOKEN=keep=me\n' >"$SANDBOX/new.env"
assert_eq "env_get_file reads value" "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/old.env" B)" "two"
assert_eq "env_get_file value with =" "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/old.env" PROXY_AUTH_TOKEN)" "keep=me"
changed="$(run_sourced "$SANDBOX" env_changed_keys "$SANDBOX/old.env" "$SANDBOX/new.env" | sort | tr '\n' ' ')"
assert_eq "env_changed_keys finds B and C" "$changed" "B C "

echo "== unit: export_build_provenance (Issue #58) =="
# Exports the stack version (from the top-level VERSION file, whitespace-trimmed) plus git
# branch/commit for the dashboard build args — deliberately NOT written into .env, since the
# volatile commit would otherwise churn `apply`. The sandbox isn't a git repo, so branch/commit
# come back empty here; the release/dev split is unit-tested in dashboard/tests/test_version.py.
PROV="$SANDBOX/prov"
mkdir -p "$PROV"
printf '  9.9.9 \n' >"$PROV/VERSION"
# shellcheck disable=SC1090  # STACK path is dynamic by design
ver="$(cd "$PROV" && source "$STACK" && set +e && export_build_provenance && printf '%s' "$PITHEAD_VERSION")"
assert_eq "export_build_provenance reads VERSION (trimmed)" "$ver" "9.9.9"
NOVER="$SANDBOX/nover"
mkdir -p "$NOVER"
# shellcheck disable=SC1090  # STACK path is dynamic by design
ver="$(cd "$NOVER" && source "$STACK" && set +e && export_build_provenance && printf '%s' "$PITHEAD_VERSION")"
assert_eq "export_build_provenance empty when no VERSION" "$ver" ""

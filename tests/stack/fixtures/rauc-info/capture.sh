#!/usr/bin/env bash
# Regenerates the two committed fixtures beside this script (#1093):
#
#   rauc-info-migration.shell.txt  — real `rauc info --output-format=shell` output
#   rauc-info-migration.json.txt   — real `rauc info --output-format=json`  output
#
# Both come from ONE genuine bundle built by the real `rauc` binary from the SAME manifest
# os/rauc/mkbundle.sh renders in production (`render_bundle_manifest`, os/rauc/populate-slot.sh)
# for a migrating release — variant=release, data_migration=true, minimum_os_version=1.18.0. The
# stack tests' fake rauc (tests/stack/run.sh) serves these two files back to `os_bundle_meta`
# depending on which --output-format the caller actually asked for, so a caller that regresses to
# --output-format=json (the shape RAUC 1.11 ships, which omits [meta.*] entirely — the drift that
# prompted this fixture) sees the real omission instead of a hand-written stand-in that was
# invented to already match the parser.
#
# No loop mount, no root, no image build: `rauc bundle` accepts any content directory and a
# 'plain'-format bundle needs no squashfs, so this captures the exact manifest text real RAUC
# parses without the multi-minute rootfs build the KVM battery needs. It does NOT stand in for
# that battery — it only pins the [meta.*] TEXT SHAPE, not signature/slot/image handling.
#
# Refresh when the RAUC pin moves (the Debian package version os/rootfs/Dockerfile installs):
#   tests/stack/fixtures/rauc-info/capture.sh
# then diff the two .txt files and commit if the shape changed. Requires `rauc` on PATH — this
# script is a maintenance tool, not part of any test run (tests/stack/run.sh never executes it).
set -euo pipefail
cd "$(dirname "$0")/../../../.." # repo root

command -v rauc >/dev/null 2>&1 || {
    echo "capture.sh needs the real 'rauc' binary on PATH (only for refreshing fixtures — tests" \
        "themselves never run it)" >&2
    exit 1
}

FIXDIR="tests/stack/fixtures/rauc-info"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/content"
# shellcheck source=os/rauc/populate-slot.sh
. os/rauc/populate-slot.sh
render_bundle_manifest 1.18.0 release true 1.18.0 >"$WORK/content/manifest.raucm"
# Payload content is never inspected by `rauc info` — a placeholder is honest here, unlike the
# manifest text, which is the one thing this fixture exists to pin.
printf 'placeholder rootfs payload — rauc-info-fixture capture only, never booted\n' \
    >"$WORK/content/rootfs.ext4"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=pithead-fixture-capture" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1

rauc --cert "$WORK/cert.pem" --key "$WORK/key.pem" bundle "$WORK/content" "$WORK/out.raucb" >&2

{
    echo "# Captured $(date -u +%Y-%m-%dT%H:%M:%SZ) by tests/stack/fixtures/rauc-info/capture.sh"
    echo "# rauc --version: $(rauc --version 2>&1 | tr -d '\r')"
    echo "# Real 'rauc info --no-verify --output-format=shell' on a bundle built from the real"
    echo "# render_bundle_manifest(1.18.0, release, true, 1.18.0) — a migrating release."
    rauc info --no-verify --output-format=shell "$WORK/out.raucb" 2>/dev/null
} >"$FIXDIR/rauc-info-migration.shell.txt"

{
    echo "# Captured $(date -u +%Y-%m-%dT%H:%M:%SZ) by tests/stack/fixtures/rauc-info/capture.sh"
    echo "# rauc --version: $(rauc --version 2>&1 | tr -d '\r')"
    echo "# Real 'rauc info --no-verify --output-format=json' on the SAME bundle. This is RAUC"
    echo "# 1.11's shape: [meta.*] is entirely absent from the JSON output (#1093) — the fake rauc"
    echo "# in tests/stack/run.sh serves THIS file when a caller asks for json, so a regression"
    echo "# back to --output-format=json degrades to fail-closed 'unstamped', for real, in the test."
    rauc info --no-verify --output-format=json "$WORK/out.raucb" 2>/dev/null
} >"$FIXDIR/rauc-info-migration.json.txt"

echo "wrote $FIXDIR/rauc-info-migration.shell.txt and .json.txt" >&2

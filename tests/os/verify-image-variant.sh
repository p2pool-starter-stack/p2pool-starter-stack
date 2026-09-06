# shellcheck shell=bash
# Sourced by verify-image.sh: the variant material — what a debug image must carry and a release
# image must not (#1892 split it out for the file budget). Runs with the caller's $ROOT, $MODE and
# chk; a debug build's test-registry pin and trust are asserted from the same PITHEAD_REGISTRY /
# PITHEAD_REGISTRY_CA the builder was given.

echo "==> test material"
# The variant stamp must MATCH the material, not just exist: a debug image stamped "release"
# defeats the os-update guard that keeps a debug box from silently dropping its own SSH.
if [ "$MODE" = "--test" ]; then
    chk "test SSH key present (harness build)" '[ -s "$ROOT/root/.ssh/authorized_keys" ]'
    chk "variant stamp says debug" '[ "$(cat "$ROOT/etc/pithead-variant")" = "debug" ]'
    # #1892: built against a non-default registry, the boot units must carry it AND podman must trust it — one without the other is a first boot that cannot find its wizard image, or a provision that refuses the pull.
    if [ -n "${PITHEAD_REGISTRY:-}" ] && [ "$PITHEAD_REGISTRY" != ghcr.io/p2pool-starter-stack ]; then
        chk "all three boot units pinned to the test registry" '[ "$(grep -lxF "Environment=PITHEAD_REGISTRY=$PITHEAD_REGISTRY" "$ROOT"/etc/systemd/system/{pithead-boot,pithead-firstboot,pithead-setup-again}.service.d/pithead-test-registry.conf 2>/dev/null | wc -l)" = 3 ]'
        # #1931: a PAM login (an SSH shell running ./pithead by hand) reads /etc/environment, not the drop-ins; the engine pin beside it proves the file was appended to, not replaced.
        chk "/etc/environment pinned to the test registry, engine pin kept" 'grep -qxF "PITHEAD_REGISTRY=$PITHEAD_REGISTRY" "$ROOT/etc/environment" && grep -qxF "PITHEAD_ENGINE=podman" "$ROOT/etc/environment"'
        # The trust half is whichever the builder chose: the CA it was handed, byte for byte, or the insecure entry.
        if [ -n "${PITHEAD_REGISTRY_CA:-}" ]; then
            chk "podman trusts the test registry's CA, and no insecure entry" 'cmp -s "$PITHEAD_REGISTRY_CA" "$ROOT/etc/containers/certs.d/${PITHEAD_REGISTRY%%/*}/ca.crt" && [ ! -e "$ROOT/etc/containers/registries.conf.d/pithead-test-registry.conf" ]'
        else
            chk "podman told the test registry is insecure, and no CA" 'grep -qF "location = \"${PITHEAD_REGISTRY%%/*}\"" "$ROOT/etc/containers/registries.conf.d/pithead-test-registry.conf" && grep -qxF "insecure = true" "$ROOT/etc/containers/registries.conf.d/pithead-test-registry.conf" && [ ! -e "$ROOT/etc/containers/certs.d" ]'
        fi
    fi
else
    # The reason this script exists in versioned form: a leaked test key on a release image is a
    # backdoor, and ad-hoc eyeballing is how one ships.
    chk "NO test marker, NO test registry pin or trust (#1892)" '[ ! -e "$ROOT/etc/pithead-test-marker" ] && [ ! -e "$ROOT/etc/containers/registries.conf.d/pithead-test-registry.conf" ] && [ ! -e "$ROOT/etc/containers/certs.d" ] && ! ls "$ROOT"/etc/systemd/system/*/pithead-test-registry.conf >/dev/null 2>&1 && ! grep -q "^PITHEAD_REGISTRY=" "$ROOT/etc/environment"'
    chk "NO SSH authorized_keys" '[ ! -s "$ROOT/root/.ssh/authorized_keys" ]'
    chk "ssh service disabled" '! ls "$ROOT"/etc/systemd/system/multi-user.target.wants/ssh.service'
    chk "variant stamp says release" '[ "$(cat "$ROOT/etc/pithead-variant")" = "release" ]'
    # The keyring is the fleet's update trust root. A dev build auto-generates a CN=pithead-dev
    # cert; if that baked as the release keyring, every device would trust a throwaway,
    # unencrypted key with no offline backup — a backdoor of the same class as a leaked SSH key,
    # so it is a hard fail here (the build guard should stop it upstream, this catches a slip at
    # the artifact). A legitimately self-signed release root is fine — only the known dev CN is
    # refused, so this never false-positives on a real single-cert keyring.
    chk "keyring is NOT the dev signing cert (CN=pithead-dev)" \
        '! openssl x509 -in "$ROOT/etc/rauc/keyring.pem" -noout -subject 2>/dev/null | grep -q "pithead-dev"'
fi

# shellcheck shell=bash
#
# The boot menu's rows for tests/os/verify-image.sh (#1838 the titles, #1318 the way back to setup).
# Sourced after the ESP and slot A are mounted, with chk/ok/bad, $ESP and $ROOT in scope. A sibling
# rather than more rows in verify-image.sh, which sits at the 400-line target: one subject, one file.
echo "==> boot menu (titles for a person, #1838; the way back to setup, #1318)"
# shellcheck disable=SC2034  # read inside chk's eval'd conditions
GRUBCFG="$ESP/grub/grub.cfg"
chk "the menu waits 5 s — long enough to choose an entry" 'grep -q "^timeout=5$" "$GRUBCFG"'
chk "entries name what they boot: slot A, slot B" 'grep -q "^menuentry \"Pithead OS - slot A\"" "$GRUBCFG" && grep -q "^menuentry \"Pithead OS - slot B\"" "$GRUBCFG"'
# Index 0 boots slot A byte for byte as entry 1 does; it recovers nothing and its TITLE must not say so
# (grub.cfg's comment records the old name, so the sweep reads entries, not the file).
chk "the fallback entry says fallback, and no entry says Recovery" 'grep -q "^menuentry \"Pithead OS - slot A (fallback)\"" "$GRUBCFG" && ! grep "^menuentry" "$GRUBCFG" | grep -qi "recovery"'
chk "no bootloader counters in any title" '! grep "^menuentry" "$GRUBCFG" | grep -qE "OK=|TRY="'
chk "a Set up again entry, carrying the flag on its kernel line" 'grep -q "^menuentry \"Set up again (opens the setup wizard; keeps the saved settings)\"" "$GRUBCFG" && [ "$(grep -c "^ *linux .*pithead.setup=1" "$GRUBCFG")" -eq 1 ]'
# The entry is the default boot plus one flag: it must follow the slot counting, never pin a slot.
chk "the setup entry boots the slot the counting chose" 'grep -q "rauc.slot=\$SETUP_SLOT pithead.setup=1" "$GRUBCFG" && grep -q "^set SETUP_SLOT=A$" "$GRUBCFG" && grep -q "SETUP_SLOT=B" "$GRUBCFG"'
# grub-reboot's mechanism: the running system names an entry for ONE boot, and grub.cfg consumes it.
chk "next_entry is honoured for one boot and consumed" 'grep -q "set default=\"\$next_entry\"" "$GRUBCFG" && grep -q "^    save_env next_entry$" "$GRUBCFG"'
# shellcheck disable=SC2034  # read inside chk's eval'd conditions
SAU="$ROOT/etc/systemd/system/pithead-setup-again.service"
chk "the setup-again unit ships and is enabled" '[ -s "$SAU" ] && [ -L "$ROOT/etc/systemd/system/multi-user.target.wants/pithead-setup-again.service" ]'
chk "it runs only on a boot carrying the flag" 'grep -q "^ConditionKernelCommandLine=pithead.setup=1$" "$SAU"'
chk "…and only on a provisioned machine, either shape" 'grep -q "^ConditionPathExists=|/data/pithead/config.json$" "$SAU" && grep -q "^ConditionPathExists=|/data/pithead/machine-role$" "$SAU"'
chk "it holds the normal boot behind the page" 'grep -q "^Before=pithead-boot.service$" "$SAU"'
chk "it runs the wizard in set-up-again mode, on the console" 'grep -q "^Environment=PITHEAD_SETUP_AGAIN=1$" "$SAU" && grep -q "^ExecStart=/data/pithead/pithead firstboot-wizard$" "$SAU" && grep -q "^StandardOutput=journal+console$" "$SAU"'
# The switch's three readers in the baked CLI: the mode test, the page's signal, the page's keep.
chk "the baked pithead honours the switch (mode, saved-role.json, keep-role)" 'grep -q "setup_again_mode" "$ROOT/opt/pithead/pithead" && grep -q "saved-role.json" "$ROOT/opt/pithead/pithead" && grep -q "keep-role" "$ROOT/opt/pithead/pithead"'
chk "pithead-boot does not read the flag (the unit is its only reader)" '! grep -q "pithead.setup" "$ROOT/usr/local/sbin/pithead-boot"'

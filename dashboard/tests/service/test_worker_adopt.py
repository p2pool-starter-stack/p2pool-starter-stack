"""Click-to-adopt (#893): the dashboard-side mirror of pithead's per-entry shape validation and
the add-only diff it pre-checks before ``handle_control_preview`` ever spools a proposal.

Each test names the guard it kills so a later change that quietly weakens one shows up as a
specific broken test, not a vague coverage drop:
  - a REMOVED check (the ``if`` deleted, or the function always returning "") would let every
    bad case in this file through as if it were valid — the "malformed X refused" tests kill that.
  - an INVERTED check (``==`` for ``!=``, a dropped ``not``) would refuse every GOOD case instead
    — the "well-formed entry accepted" tests kill that.
  - a widened/narrowed diff boundary (off-by-one on the prefix length) would misclassify an edit
    to an existing entry as "new", or lose a genuinely new tail entry — the prefix-boundary tests
    kill that.
"""

import pytest

from mining_dashboard.service.worker_adopt import (
    DEFAULT_CONTROL_PORT,
    HOST_RE,
    NAME_RE,
    TOKEN_RE,
    host_is_internal,
    new_worker_entries,
    validate_new_worker_entries,
    validate_worker_descriptor,
)

VALID_ENTRY = {"name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-123"}


def test_regexes_have_no_intra_repo_drift():
    """This module's docstring claims its host/name/token charset guards mirror pithead's own
    ``validate_worker_endpoints`` byte for byte (the #122 SSRF guard in particular) — prove it
    instead of trusting the comment. Same pattern as ``test_control_service.py``'s
    ``test_writable_key_allowlist_has_no_intra_repo_drift``: skip where the CLI isn't checked out
    (the dashboard-only Docker test image), verify where it is."""
    from pathlib import Path

    here = Path(__file__).resolve()
    pithead_path = next((p / "pithead" for p in here.parents if (p / "pithead").is_file()), None)
    if pithead_path is None:
        pytest.skip("pithead CLI not present in this test context (dashboard-only image)")
    pithead = pithead_path.read_text()

    def _find(needle):
        idx = pithead.find(needle)
        assert idx != -1, f"could not find {needle!r} in pithead's validate_worker_endpoints"

    # The literal jq test() regex source strings, unmodified from pithead's own guard.
    _find('test("^[!-~]{1,128}$")')  # name AND token both use this charset (checked separately)
    _find('test("^[A-Za-z0-9._-]{1,253}$")')  # the #122 host charset guard
    assert NAME_RE.pattern == r"^[!-~]{1,128}$"
    assert TOKEN_RE.pattern == r"^[!-~]{1,128}$"
    assert HOST_RE.pattern == r"^[A-Za-z0-9._-]{1,253}$"


class TestValidateWorkerDescriptor:
    def test_well_formed_entry_accepted(self):
        assert validate_worker_descriptor(VALID_ENTRY) == ""

    def test_control_port_defaults_when_absent(self):
        # DEFAULT_CONTROL_PORT (8082) must be accepted when the operator left it blank in the
        # form — a guard that forgot the default would refuse every adopt submission that omits it.
        entry = {k: v for k, v in VALID_ENTRY.items() if k != "control_port"}
        assert validate_worker_descriptor(entry) == ""
        assert DEFAULT_CONTROL_PORT == 8082

    def test_non_object_entry_refused(self):
        assert validate_worker_descriptor("not-an-object") != ""

    def test_missing_name_refused(self):
        entry = dict(VALID_ENTRY)
        del entry["name"]
        assert validate_worker_descriptor(entry) != ""

    def test_name_with_space_refused(self):
        # NAME_RE is `^[!-~]{1,128}$` — a space is outside the printable-non-space class.
        assert validate_worker_descriptor({**VALID_ENTRY, "name": "rig 1"}) != ""

    def test_host_with_embedded_port_refused(self):
        # The #122 guard: a host string carrying a port must never reach a probe URL unparsed.
        err = validate_worker_descriptor({**VALID_ENTRY, "host": "10.0.0.9:9999"})
        assert err != "" and "rig1" in err

    def test_host_with_path_refused(self):
        assert validate_worker_descriptor({**VALID_ENTRY, "host": "10.0.0.9/../etc"}) != ""

    def test_host_with_userinfo_refused(self):
        assert validate_worker_descriptor({**VALID_ENTRY, "host": "user@10.0.0.9"}) != ""

    def test_missing_host_refused(self):
        entry = {k: v for k, v in VALID_ENTRY.items() if k != "host"}
        assert validate_worker_descriptor(entry) != ""

    def test_control_port_zero_refused(self):
        assert validate_worker_descriptor({**VALID_ENTRY, "control_port": 0}) != ""

    def test_control_port_over_max_refused(self):
        assert validate_worker_descriptor({**VALID_ENTRY, "control_port": 65536}) != ""

    def test_control_port_bool_refused(self):
        # bool is an int subclass in Python — must be excluded explicitly (mirrors pithead's guard).
        assert validate_worker_descriptor({**VALID_ENTRY, "control_port": True}) != ""

    def test_control_port_non_integer_refused(self):
        assert validate_worker_descriptor({**VALID_ENTRY, "control_port": 8082.5}) != ""

    def test_missing_token_refused(self):
        # Bearer-mandatory: a descriptor with no token can never be a write target.
        entry = {k: v for k, v in VALID_ENTRY.items() if k != "token"}
        assert validate_worker_descriptor(entry) != ""

    def test_token_with_space_refused(self):
        assert validate_worker_descriptor({**VALID_ENTRY, "token": "has space"}) != ""


class TestNewWorkerEntries:
    def test_empty_live_makes_every_staged_entry_new(self):
        live = {}
        staged = {"workers": {"list": [VALID_ENTRY]}}
        assert new_worker_entries(live, staged) == [VALID_ENTRY]

    def test_pure_append_returns_only_the_tail(self):
        rig2 = {"name": "rig2", "host": "10.0.0.10", "token": "tok-456"}
        live = {"workers": {"list": [VALID_ENTRY]}}
        staged = {"workers": {"list": [VALID_ENTRY, rig2]}}
        assert new_worker_entries(live, staged) == [rig2]

    def test_no_change_returns_nothing_new(self):
        live = {"workers": {"list": [VALID_ENTRY]}}
        assert new_worker_entries(live, dict(live)) == []

    def test_edited_existing_entry_is_not_new(self):
        # A repoint of rig1's host is NOT a "new entry" to validate — it's a non-append change the
        # host's own add-only gate refuses outright. Misclassifying it as "new" would validate its
        # SHAPE (which can pass) and never flag that it touches an existing descriptor at all.
        live = {"workers": {"list": [VALID_ENTRY]}}
        staged = {"workers": {"list": [{**VALID_ENTRY, "host": "ATTACKER"}]}}
        assert new_worker_entries(live, staged) == []

    def test_removed_entry_is_not_new(self):
        rig2 = {"name": "rig2", "host": "10.0.0.10", "token": "tok-456"}
        live = {"workers": {"list": [VALID_ENTRY, rig2]}}
        staged = {"workers": {"list": [VALID_ENTRY]}}
        assert new_worker_entries(live, staged) == []

    def test_reordered_entries_not_new(self):
        rig2 = {"name": "rig2", "host": "10.0.0.10", "token": "tok-456"}
        live = {"workers": {"list": [VALID_ENTRY, rig2]}}
        staged = {"workers": {"list": [rig2, VALID_ENTRY]}}
        assert new_worker_entries(live, staged) == []

    def test_non_list_staged_workers_list_returns_nothing(self):
        live = {}
        assert new_worker_entries(live, {"workers": {"list": "not-a-list"}}) == []


class TestValidateNewWorkerEntries:
    def test_no_new_entries_is_clean(self):
        live = {"workers": {"list": [VALID_ENTRY]}}
        assert validate_new_worker_entries(live, dict(live)) == ""

    def test_valid_new_entry_is_clean(self):
        rig2 = {"name": "rig2", "host": "10.0.0.10", "token": "tok-456"}
        live = {"workers": {"list": [VALID_ENTRY]}}
        staged = {"workers": {"list": [VALID_ENTRY, rig2]}}
        assert validate_new_worker_entries(live, staged) == ""

    def test_malformed_new_entry_refused(self):
        bad = {"name": "rig2", "host": "10.0.0.10:9999", "token": "tok-456"}
        live = {"workers": {"list": [VALID_ENTRY]}}
        staged = {"workers": {"list": [VALID_ENTRY, bad]}}
        assert validate_new_worker_entries(live, staged) != ""

    def test_new_entry_pointed_at_loopback_refused(self):
        # The critical SSRF case: a well-SHAPED but internally-addressed new entry must still be
        # refused, not just a malformed-charset one — a compromised dashboard could otherwise
        # append a phantom descriptor at its own host's loopback services and immediately dial it
        # via worker-apply/worker-upgrade (resolve_worker_target resolves strictly from config.json,
        # so whatever lands here becomes a real dial target).
        evil = {"name": "evil", "host": "127.0.0.1", "control_port": 8000, "token": "attacker"}
        live = {"workers": {"list": [VALID_ENTRY]}}
        staged = {"workers": {"list": [VALID_ENTRY, evil]}}
        err = validate_new_worker_entries(live, staged)
        assert err != "" and "evil" in err

    def test_new_entry_pointed_at_the_stacks_own_docker_bridge_refused(self):
        # Same class of escalation, aimed at a SIBLING container (monerod, the docker-proxy socket,
        # tor) instead of the host's own loopback.
        evil = {"name": "evil", "host": "172.28.0.5", "control_port": 18081, "token": "attacker"}
        live = {"workers": {"list": [VALID_ENTRY]}, "network": {"subnet": "172.28.0.0/24"}}
        staged = {
            "workers": {"list": [VALID_ENTRY, evil]},
            "network": {"subnet": "172.28.0.0/24"},
        }
        assert validate_new_worker_entries(live, staged) != ""

    def test_new_entry_on_ordinary_lan_address_is_unaffected(self):
        # The fix must not break the feature: a real rig at a real LAN address still adopts fine.
        rig2 = {"name": "rig2", "host": "192.168.1.50", "token": "tok-456"}
        live = {"workers": {"list": [VALID_ENTRY]}}
        staged = {"workers": {"list": [VALID_ENTRY, rig2]}}
        assert validate_new_worker_entries(live, staged) == ""


class TestHostIsInternal:
    """Mirrors pithead's ``_control_host_is_internal`` — see
    ``test_regexes_have_no_intra_repo_drift``-style intent, but this class is a semantic mirror
    (bash has no ``ipaddress`` module to diff against byte-for-byte); the bash-side battery of
    cases was hand-verified during development (see the PR description)."""

    @pytest.mark.parametrize(
        "host",
        [
            "127.0.0.1",
            "localhost",
            "LOCALHOST",
            "sub.localhost",
            "0.0.0.0",
            "169.254.169.254",  # cloud-metadata-shaped link-local
            "224.0.0.1",  # multicast
            "240.0.0.1",  # reserved
            "::1",  # loopback, IPv6
            "localhost.",  # DNS "FQDN root" dot; curl resolves it identically to "localhost"
            "LOCALHOST.",
            "localhost.localdomain",  # the standard /etc/hosts loopback alias (RHEL-family)
            "ip6-localhost",  # the standard /etc/hosts ::1 alias (Debian-family)
            "ip6-loopback",
            "IP6-LOOPBACK.",  # case + trailing-dot combined
        ],
    )
    def test_internal_classes_refused(self, host):
        assert host_is_internal(host, {}) is True

    @pytest.mark.parametrize("host", ["192.168.1.50", "10.0.0.9", "8.8.8.8", "rig1.example.com"])
    def test_ordinary_addresses_and_hostnames_pass(self, host):
        assert host_is_internal(host, {}) is False

    def test_default_docker_bridge_subnet_refused_with_no_network_config(self):
        assert host_is_internal("172.28.0.5", {}) is True

    def test_custom_docker_bridge_subnet_is_read_from_live_config(self):
        live = {"network": {"subnet": "172.30.0.0/24"}}
        assert host_is_internal("172.30.0.5", live) is True
        # Off the CUSTOM subnet, the default's own range is no longer special on this install.
        assert host_is_internal("172.28.0.5", live) is False

    def test_malformed_subnet_in_live_config_fails_closed_to_the_default(self):
        live = {"network": {"subnet": "not-a-subnet"}}
        assert host_is_internal("172.28.0.5", live) is True

    def test_trailing_dot_alone_does_not_clear_the_localhost_class(self):
        # Round-4 finding: dropping the `h = h[:-1]` trailing-dot strip (or reordering it after the
        # alias-set membership check) reopens "localhost." / "LOCALHOST." as an unrecognized,
        # letter-containing "hostname" that clears every check below — verified live: curl resolves
        # "localhost." to 127.0.0.1/::1 identically to "localhost".
        assert host_is_internal("localhost.", {}) is True
        assert host_is_internal("LOCALHOST.", {}) is True

    def test_etc_hosts_loopback_aliases_are_not_missed(self):
        # Round-4 finding: narrowing _LOOPBACK_ALIASES back down to just {"localhost"} (or
        # reverting to the old `h == "localhost" or h.endswith(".localhost")` check) reopens
        # localhost.localdomain / ip6-localhost / ip6-loopback — real /etc/hosts entries on this
        # stack's own target OS, verified to resolve to loopback via `getent hosts` + live curl.
        for alias in ("localhost.localdomain", "ip6-localhost", "ip6-loopback"):
            assert host_is_internal(alias, {}) is True

    def test_a_subdomain_of_an_alias_is_not_itself_aliased(self):
        # The alias set is bare-name membership, not a suffix match like ".localhost" — confirms
        # the fix didn't overreach into refusing every hostname that merely contains "ip6-localhost".
        assert host_is_internal("sub.ip6-localhost", {}) is False

    @pytest.mark.parametrize(
        "host",
        [
            "2130706433",  # bare decimal integer == 127.0.0.1; curl dials it as loopback
            "2852039166",  # bare decimal integer == 169.254.169.254 (cloud metadata)
            "0177.0.0.1",  # octal-leading-zero octet == 127.0.0.1
            "0x7f000001",  # hex == 127.0.0.1
            "0x7f.0x0.0x0.0x1",  # per-octet hex == 127.0.0.1
            "127.1",  # short/collapsed form == 127.0.0.1
            "010.0.0.1",  # octal-leading-zero first octet == 8.0.0.1 (still refused: numeric-shaped
            # but non-canonical, refused outright rather than resolved)
            "000.1.2.3",
        ],
    )
    def test_alternate_ip_encodings_are_refused_not_waved_through_as_hostnames(self, host):
        # The actual bypass a security review found: is_ipv4-style strict parsing correctly
        # refuses each of these AS an address, but the original bug then fell through to "must be
        # a hostname, therefore safe" — exactly the class curl's own numeric-address parser (and
        # bash's leading-zero-as-octal arithmetic) still resolves to a real, dangerous address.
        # Refusing outright (never "clears the class") is what this test pins.
        assert host_is_internal(host, {}) is True

    def test_this_network_block_refused_beyond_the_single_unspecified_address(self):
        # ipaddress.is_unspecified only covers the literal 0.0.0.0 — the whole 0.0.0.0/8
        # "this network" block needs its own check, or 0.1.2.3 sails through unclassified.
        assert host_is_internal("0.1.2.3", {}) is True

    def test_hex_literal_is_refused_even_though_it_contains_letters(self):
        # The "contains a letter -> real hostname" shortcut must not blanket-clear a hex IP
        # attempt just because hex digits look alphabetic.
        assert host_is_internal("0xc0.0xa8.0x01.0x32", {}) is True

    @pytest.mark.parametrize("host", ["rig-1.lan", "a.b.c.d", "rig01.example.com"])
    def test_ordinary_hostnames_with_digits_still_pass(self, host):
        assert host_is_internal(host, {}) is False

    def test_hostname_containing_a_literal_0x_substring_is_an_accepted_false_positive(self):
        # A vanishingly rare real hostname that happens to contain "0x" gets refused too — a
        # deliberate, accepted trade-off (no one names a rig "my0x1"), not a regression to chase.
        assert host_is_internal("my0x1.example.com", {}) is True

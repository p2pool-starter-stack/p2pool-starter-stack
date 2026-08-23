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

from mining_dashboard.service.worker_adopt import (
    DEFAULT_CONTROL_PORT,
    new_worker_entries,
    validate_new_worker_entries,
    validate_worker_descriptor,
)

VALID_ENTRY = {"name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-123"}


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

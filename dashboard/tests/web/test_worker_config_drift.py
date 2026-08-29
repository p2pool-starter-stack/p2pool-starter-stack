"""Value-level config drift for Worker Inspect (#1367).

``config_origin`` (#1345) reports the last change RigForge *recorded*. A config edited underneath
RigForge records nothing, so on a rig where this dashboard applied the previous change the line
keeps reading "Last changed from this dashboard" while the rig runs something else — a false
reassurance, the one direction that feature exists to avoid. ``config_drift`` catches that by
comparing the two values already in the payload.

The bulk of what is tested here is the TYPE discipline, because that is where a value comparison
re-opens the very false-positive the issue rejects the revision-hash fix for. RigForge fixes the
JSON type of every writable scalar as it serves it; nothing on this side coerces anything, and four
reachable editor paths store a string where the rig serves a number. Comparing those raw reports
drift on a rig running exactly what we applied.
"""

import pytest

from mining_dashboard.web.worker_detail import (
    _comparable,
    _has_unsettled_apply,
    config_drift,
)


class TestTypeDiscipline:
    """A stored string must not read as drift against the number RigForge serves."""

    @pytest.mark.parametrize(
        "key,applied,rig",
        [
            # Route 1: rig serves max_temp_c: null, so the editor row is a free-form JSON box and
            # an operator typing "80" (quoted) stores a string.
            ("max_temp_c", "80", 80),
            # Route 3: last_applied already holds a string, so the row types as text and every
            # later edit stays one. This is the self-perpetuating case.
            ("max_temp_c", "101", 101),
            # Route 4: JSON mode does no per-key typing at all.
            ("DONATION", "1", 1),
            ("watchdog_interval_min", "5", 5),
            # And the mirror image, since nothing guarantees which side is which.
            ("DONATION", 1, "1"),
            # A float against the int the rig serves is the same value, not drift.
            ("max_temp_c", 80.0, 80),
        ],
    )
    def test_string_and_number_forms_of_the_same_value_are_not_drift(self, key, applied, rig):
        assert config_drift({key: applied}, {key: rig}) == []

    @pytest.mark.parametrize(
        "key,applied,rig",
        [
            ("autotune", "disabled", "disabled"),
            ("watchdog", "enabled", "enabled"),
        ],
    )
    def test_the_string_typed_keys_compare_as_strings(self, key, applied, rig):
        assert config_drift({key: applied}, {key: rig}) == []

    def test_a_number_stored_for_a_string_typed_key_is_not_drift(self):
        # RigForge serves autotune/watchdog through ``--arg``, so they are ALWAYS strings on the
        # rig side. JSON mode does no per-key typing, so an operator can store a number for one.
        # Without the string canonicalisation this reports drift on a rig running what we set.
        assert config_drift({"autotune": 1}, {"autotune": "1"}) == []
        assert config_drift({"watchdog": 0}, {"watchdog": "0"}) == []

    def test_a_value_that_will_not_coerce_is_real_drift(self):
        # The editor lets a non-numeric string through deliberately, for the rig to reject. The rig
        # is then running something else, so this MUST report — coercion must not swallow it.
        drift = config_drift({"max_temp_c": "80c"}, {"max_temp_c": 80})
        assert drift == [{"key": "max_temp_c", "applied": "80c", "rig": 80}]

    def test_a_genuinely_different_number_is_drift(self):
        drift = config_drift({"max_temp_c": 75}, {"max_temp_c": 80})
        assert drift == [{"key": "max_temp_c", "applied": 75, "rig": 80}]

    def test_a_bool_is_not_laundered_into_the_number_it_equals(self):
        # bool is an int in Python, so a naive float() would turn True into 1.0 and call a rig
        # running DONATION 1 a match. It is not a value the rig would ever serve for this key.
        drift = config_drift({"DONATION": True}, {"DONATION": 1})
        assert drift == [{"key": "DONATION", "applied": True, "rig": 1}]

    def test_a_scalar_under_a_non_canonical_key_keeps_its_own_shape(self):
        # pools is the only writable key with no canonical scalar type, so a scalar arriving there
        # is a malformed shape from a rig that picks its own response. It must stay comparable
        # rather than being coerced toward either canonical form.
        assert _comparable("pools", "not-a-list") == ("raw", "not-a-list")
        assert config_drift({"pools": "x"}, {"pools": "x"}) == []

    def test_comparable_leaves_an_unknown_key_alone(self):
        # pools passes through RigForge's canonical form verbatim; nothing to normalise.
        assert _comparable("pools", [{"url": "a"}]) == ("raw", [{"url": "a"}])


class TestWhatItRefusesToClaim:
    def test_an_absent_key_is_skipped_but_an_explicit_none_is_compared(self):
        # These are different answers. A rig with no thermal cutoff serves max_temp_c: null — real
        # drift if we set one — whereas a key missing outright is a rig too old to report it.
        assert config_drift({"max_temp_c": 75}, {"DONATION": 1}) == []
        assert config_drift({"max_temp_c": 75}, {"max_temp_c": None}) == [
            {"key": "max_temp_c", "applied": 75, "rig": None}
        ]

    def test_only_keys_we_applied_are_compared(self):
        # last_applied is a merge of DIFFS, so a rig key we never set is not ours to judge.
        assert config_drift({"DONATION": 1}, {"DONATION": 1, "max_temp_c": 90}) == []

    def test_pool_credentials_are_stripped_from_our_side_too(self):
        # RigForge deletes pass/tls-fingerprint before serving. A password we once applied would
        # otherwise be permanent, uncloseable drift on a rig that has none.
        applied = {"pools": [{"url": "a", "pass": "secret", "tls-fingerprint": "ff"}]}
        rig = {"pools": [{"url": "a"}]}
        assert config_drift(applied, rig) == []

    def test_a_real_pool_change_still_reports(self):
        applied = {"pools": [{"url": "a", "pass": "secret"}]}
        rig = {"pools": [{"url": "b"}]}
        drift = config_drift(applied, rig)
        assert [d["key"] for d in drift] == ["pools"]
        # The reported value must be the STRIPPED one — this lands in an API payload.
        assert "pass" not in drift[0]["applied"][0]

    def test_an_unsettled_change_suppresses_the_whole_comparison(self):
        # A submitted change is not in last_applied while the rig may already be running it, so
        # comparing inside that window reports drift on a key we ourselves just set.
        assert config_drift({"DONATION": 1}, {"DONATION": 2}, unsettled=True) is None

    @pytest.mark.parametrize("rig_config", [None, "not-a-dict", 42, []])
    def test_an_unreadable_rig_config_is_silence_not_a_finding(self, rig_config):
        # None and [] must stay apart: [] is "checked, agrees", None is "could not check".
        assert config_drift({"DONATION": 1}, rig_config) is None

    def test_an_unreadable_last_applied_is_silence_too(self):
        assert config_drift(None, {"DONATION": 1}) is None

    def test_agreement_returns_an_empty_list_not_none(self):
        assert config_drift({"DONATION": 1}, {"DONATION": 1}) == []


class TestUnsettledDetection:
    def test_the_newest_apply_row_governs(self):
        history = [{"type": "apply", "status": "accepted"}, {"type": "apply", "status": "applied"}]
        assert _has_unsettled_apply(history) is True

    def test_a_stale_unsettled_row_behind_a_settled_one_does_not_suppress(self):
        # An old accepted row that never settled is a stuck record, not a change in flight. Letting
        # one suppress this check forever would trade a false alarm for permanent silence.
        history = [{"type": "apply", "status": "applied"}, {"type": "apply", "status": "accepted"}]
        assert _has_unsettled_apply(history) is False

    def test_upgrade_rows_are_not_config_applies(self):
        # An upgrade row's changes is a {"version": ...} marker, never writable-key config.
        history = [
            {"type": "upgrade", "status": "accepted"},
            {"type": "apply", "status": "applied"},
        ]
        assert _has_unsettled_apply(history) is False

    def test_an_unrecognised_status_is_not_read_as_settled(self):
        # The list is the complement of a terminal outcome deliberately: a status we do not know is
        # not evidence that a change settled.
        assert _has_unsettled_apply([{"type": "apply", "status": "running"}]) is True

    @pytest.mark.parametrize("history", [None, [], [{"type": "upgrade", "status": "applied"}]])
    def test_no_apply_row_at_all_is_not_unsettled(self, history):
        assert _has_unsettled_apply(history) is False

    def test_a_row_without_a_type_is_an_apply(self):
        # worker_config defaults type to 'apply'; rows predating #1014 have it absent.
        assert _has_unsettled_apply([{"status": "accepted"}]) is True


class TestThroughTheWholePayload:
    """The wiring, not the function: a unit test of ``config_drift`` proves nothing about whether
    ``build_worker_detail`` reaches it with the two values it needs, or publishes the answer."""

    @staticmethod
    def _detail(monkeypatch, rig_config, *, applied=None, status="applied"):
        from mining_dashboard.service.storage_service import StateManager
        from mining_dashboard.web import views
        from mining_dashboard.web.worker_detail import build_worker_detail

        # setattr on the shared ``config`` module object, never on ``views`` itself — a rebinding
        # in views' own globals would patch the wrong module the moment anything here moves.
        monkeypatch.setattr(
            views.config, "DASHBOARD_WORKERS", [{"name": "rig1", "host": "10.0.0.9"}]
        )
        monkeypatch.setattr(views.config, "DASHBOARD_CONTROL_ENABLED", True)
        sm = StateManager(db_path=":memory:")
        try:
            if applied is not None:
                sm.add_worker_config_version("rig1", "cid1", status, applied, None)
            workers = [
                {"name": "rig1", "status": "online", "h60": 1, "rigforge": {"config": rig_config}}
            ]
            return build_worker_detail("rig1", {"workers": workers}, sm)
        finally:
            sm.close()

    def test_a_stored_string_does_not_read_as_drift_against_the_number_the_rig_serves(
        self, monkeypatch
    ):
        # The whole point of the type discipline, proven through the real store and the real
        # payload rather than against config_drift directly. Nothing between the editor and the DB
        # coerces anything, so this is the shape a real row can hold.
        d = self._detail(monkeypatch, {"max_temp_c": 80}, applied={"max_temp_c": "80"})
        assert d["last_applied"] == {"max_temp_c": "80"}
        assert d["config_drift"] == []

    def test_a_real_disagreement_reaches_the_payload(self, monkeypatch):
        d = self._detail(monkeypatch, {"max_temp_c": 80}, applied={"max_temp_c": 75})
        assert d["config_drift"] == [{"key": "max_temp_c", "applied": 75, "rig": 80}]

    def test_a_change_still_in_flight_publishes_silence_not_a_finding(self, monkeypatch):
        # 'accepted' keeps the row out of last_applied while the rig may already be running it.
        d = self._detail(
            monkeypatch, {"max_temp_c": 80}, applied={"max_temp_c": 75}, status="accepted"
        )
        assert d["config_drift"] is None

    def test_a_rig_that_serves_no_config_publishes_silence(self, monkeypatch):
        d = self._detail(monkeypatch, None, applied={"max_temp_c": 75})
        assert d["config_drift"] is None

    def test_the_key_is_always_present_so_the_client_can_tell_silence_from_agreement(
        self, monkeypatch
    ):
        d = self._detail(monkeypatch, {"max_temp_c": 80})
        assert "config_drift" in d

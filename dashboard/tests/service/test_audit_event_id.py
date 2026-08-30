"""The audit row id is sanitized like every other field the Security panel serves (#1561).

``_record_audit_event`` cleans five fields through ``audit_service._clean`` and used to pass the
sixth — ``id``, the ``audit_events`` PRIMARY KEY — through untouched. On the rig-edit path that id
is built from an unauthenticated worker's ``change_id``, validated upstream only as a non-empty
``str`` inside a body capped at 1 MiB, and ``audit_events`` has no retention prune, so an oversized
id is permanent.

Both halves are here because they are one behaviour and either alone is a false pass: the contract
tests would stay green if ``_record_audit_event`` never called the helper, and the wiring test would
stay green against a naive truncation that silently merges two detections.
"""

import types
import uuid

import pytest

from mining_dashboard.service import audit_service
from mining_dashboard.service.data_service import DataService

# The longest id this repo legitimately constructs: "rig-drift-" + a worker name at the
# _WORKER_NAME_RE bound (128) + "-" + a revision at the parse_config_meta bound (64) = 203.
LONGEST_REAL_ID = f"rig-drift-{'w' * 128}-{'r' * 64}"

HOSTILE = "rig-edit-miner1-" + "A" * 5000 + "\x00\n<script>"


class TestCleanEventIdContract:
    def test_real_ids_pass_through_verbatim(self):
        """Every id the repo builds today keeps the key it already has — no row is orphaned by
        this change, and ids stay readable in the table. A blanket digest would fail this."""
        assert len(LONGEST_REAL_ID) == 203
        for real in (
            "11111111-1111-4111-8111-111111111111",
            "host-edit-11111111-1111-4111-8111-111111111111",
            "rig-edit-miner1-chg-2026-08-30T01:00:00Z",
            "rig-edit-ratelimited-miner1-1756515600",
            LONGEST_REAL_ID,
        ):
            assert audit_service.clean_event_id(real) == real

    def test_oversized_is_bounded(self):
        """The literal 256 is deliberate. Asserting only against ``MAX_EVENT_ID_LEN`` would source
        the assertion from the thing under test — widening the constant would widen the assertion
        with it, and the test could never fail on a cap regression."""
        out = audit_service.clean_event_id(HOSTILE)
        assert len(HOSTILE) > 5000
        assert len(out) <= 256
        assert len(out) == audit_service.MAX_EVENT_ID_LEN

    def test_hostile_charset_is_stripped(self):
        """Only the charset is guaranteed here, so only the charset is asserted. An earlier draft
        also asserted ``"script" not in out``, which passed because the cap cut before reaching it
        rather than because anything strips it — a length accident wearing a charset claim. The
        seeded id puts the hostile bytes FIRST so the assertion cannot pass by truncation."""
        seeded = "<script>\x00\n" + "A" * 5000
        out = audit_service.clean_event_id(seeded)
        for bad in ("<", ">", "\x00", "\n"):
            assert bad not in out
        assert "script" in out  # strip, don't blank — the same contract _clean holds to

    def test_distinct_long_ids_sharing_a_prefix_stay_distinct(self):
        """The anti-truncation control, and the reason this is a digest and not a slice.

        Two rigs reporting different change_ids that agree on a long prefix must land on two rows.
        Under a plain truncation both collapse to one id, ``INSERT OR IGNORE`` drops the second,
        and a real detection is lost silently. This test goes RED against that fix."""
        prefix = "rig-edit-miner1-" + "c" * 4000
        a = audit_service.clean_event_id(prefix + "AAA")
        b = audit_service.clean_event_id(prefix + "BBB")
        assert a != b
        assert len(a) <= audit_service.MAX_EVENT_ID_LEN
        assert len(b) <= audit_service.MAX_EVENT_ID_LEN

    def test_deterministic_so_repeat_reports_still_dedupe(self):
        """A rig re-reports its last change_id every poll; INSERT OR IGNORE collapses those to one
        row only while the id is a pure function of the input."""
        assert audit_service.clean_event_id(HOSTILE) == audit_service.clean_event_id(HOSTILE)

    def test_a_lone_surrogate_does_not_crash_the_poll_loop(self):
        """A rig's JSON can carry ``\\ud800``, and ``json.loads`` hands it over as a lone
        surrogate that plain ``str.encode("utf-8")`` refuses — which would raise inside the poll
        loop rather than record a row. The digest encodes with ``surrogatepass`` for exactly this.
        The first assertion is the control: it pins that the input really is un-encodable, so this
        test cannot pass by accident on an ordinary string."""
        lone = "rig-edit-miner1-" + "\ud800" + "x" * 300
        with pytest.raises(UnicodeEncodeError):
            lone.encode("utf-8")
        out = audit_service.clean_event_id(lone)
        assert len(out) <= audit_service.MAX_EVENT_ID_LEN
        assert out == audit_service.clean_event_id(lone)

    @pytest.mark.parametrize("empty", [None, "", 42, b"bytes", {"a": 1}])
    def test_absent_or_non_str_is_falsy(self, empty):
        """The caller's ``or f"{source}-{uuid4()}"`` fallback is written against a falsy return —
        a host-edit passes None and must still get a random id."""
        assert audit_service.clean_event_id(empty) == ""


class TestSinkActuallyUsesIt:
    """Proves consumption, not just existence. Without these, every test above could pass while
    ``_record_audit_event`` still wrote the raw value."""

    @staticmethod
    def _svc(recorded):
        def add_audit_event(**kwargs):
            recorded.append(kwargs)

        return types.SimpleNamespace(
            state_manager=types.SimpleNamespace(add_audit_event=add_audit_event)
        )

    async def test_hostile_event_id_reaches_the_writer_bounded_and_clean(self):
        recorded = []
        await DataService._record_audit_event(
            self._svc(recorded),
            "rig-edit",
            "miner1",
            "rig-edit",
            "applied",
            "change_id=x",
            event_id=HOSTILE,
        )
        assert len(recorded) == 1
        written = recorded[0]["id"]
        assert len(written) <= audit_service.MAX_EVENT_ID_LEN
        assert "<" not in written and "\x00" not in written and "\n" not in written
        assert written == audit_service.clean_event_id(HOSTILE)

    async def test_none_event_id_still_gets_a_random_id(self):
        """The did-not-break-the-feature half: a host-edit is a genuinely distinct event each
        time, so it must keep falling through to a uuid rather than to an empty primary key."""
        recorded = []
        svc = self._svc(recorded)
        for _ in range(2):
            await DataService._record_audit_event(
                svc, "host-edit", "host", "host-edit", "detected", "keys=A", event_id=None
            )
        ids = [r["id"] for r in recorded]
        assert len(set(ids)) == 2
        for got in ids:
            assert got.startswith("host-edit-")
            uuid.UUID(got.removeprefix("host-edit-"))

"""The audit row id is sanitized (#1561) and is a one-to-one function of its parts (#1566).

``_record_audit_event`` cleans five fields through ``audit_service._clean`` and used to pass the
sixth — ``id``, the ``audit_events`` PRIMARY KEY — through untouched. On the rig-edit path that id
is built from an unauthenticated worker's ``change_id``, validated upstream only as a non-empty
``str`` inside a body capped at 1 MiB, and ``audit_events`` has no retention prune, so an oversized
id is permanent.

``build_event_id`` is the other half and the same stake: the id is the ``audit_events`` PRIMARY KEY
under ``INSERT OR IGNORE``, so two distinct detections that mint the same id do not become two rows
or an error — the second is DROPPED. #1561 bounds how large that field can be; #1566 makes the
mapping into it one-to-one.

Both halves are here because they are one behaviour and either alone is a false pass: the contract
tests would stay green if ``_record_audit_event`` never called the helper, and the wiring test would
stay green against a naive truncation that silently merges two detections.
"""

import types
import uuid
from urllib.parse import unquote

import pytest

from mining_dashboard.service import audit_service
from mining_dashboard.service.data_service import DataService

# The longest id this repo constructs for a WELL-BEHAVED rig: "rig-drift" + ":" + a worker name at
# the _WORKER_NAME_RE length (128) + ":" + a revision at the parse_config_meta bound (64) = 203 —
# the same 203 the "-" join gave, since one separator became one separator. It is not a BOUND:
# _WORKER_NAME_RE governs config/worker_endpoints.py and not this feed, and escaping can triple a
# part. The cap, not this figure, is what makes an oversized id impossible.
LONGEST_REAL_ID = f"rig-drift:{'w' * 128}:{'r' * 64}"

HOSTILE = "rig-edit-miner1-" + "A" * 5000 + "\x00\n<script>"


class TestCleanEventIdContract:
    # What the builder emits today, pinned as LITERALS so a scheme change reddens this test rather
    # than sliding through it. The assertion below ties each literal back to build_event_id, which
    # is what keeps the pair honest: the literal alone could drift out of date, and deriving them
    # from the builder alone would source the assertion from the thing under test.
    BUILT_TODAY = {
        ("rig-edit", "miner1", "chg1"): "rig-edit:miner1:chg1",
        ("rig-edit", "miner1", "chg-2026-08-30T01:00:00Z"): (
            "rig-edit:miner1:chg%2D2026%2D08%2D30T01%3A00%3A00Z"
        ),
        ("rig-edit-ratelimited", "miner1", 1756515600): "rig-edit-ratelimited:miner1:1756515600",
    }

    # Ids written under the pre-#1566 "-" join. Nothing builds these any more; deployed databases
    # are full of them, and clean_event_id must keep resolving each to itself or the row it keys is
    # orphaned the first time anything reads it back.
    ALREADY_IN_DEPLOYED_DATABASES = (
        "11111111-1111-4111-8111-111111111111",
        "host-edit-11111111-1111-4111-8111-111111111111",
        "rig-edit-miner1-chg-2026-08-30T01:00:00Z",
        "rig-edit-ratelimited-miner1-1756515600",
    )

    def test_real_ids_pass_through_verbatim(self):
        """Ids stay readable in the table rather than collapsing to digests, across BOTH
        populations: the ids already written under the old join, and the ids built today. A blanket
        digest would fail this, and so would a fix that only considered ids it mints itself."""
        assert len(LONGEST_REAL_ID) == 203
        for parts, expected in self.BUILT_TODAY.items():
            assert audit_service.build_event_id(*parts) == expected
        for real in (
            *self.ALREADY_IN_DEPLOYED_DATABASES,
            *self.BUILT_TODAY.values(),
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


def _old_join(namespace, *parts):
    """The pre-#1566 id scheme, kept HERE as the control rather than imported.

    Every test below that claims a collision was real has to show it against something. Reading
    "these two used to collide" proves nothing; a pair that does not actually collide under the old
    rule would make the new-scheme assertion pass for the wrong reason."""
    return "-".join([namespace, *(str(p) for p in parts)])


class TestBuildEventIdIsOneToOne:
    """#1566. A collision in this field is a LOST DETECTION, not a duplicate row."""

    # Pairs a rig can present that the bare "-" join maps onto ONE id. The first is the pair
    # measured against the real caller in the issue; the rest are the same ambiguity moved around.
    COLLIDING = [
        (("victim-chg1", "extra"), ("victim", "chg1-extra")),
        (("a", "b-c"), ("a-b", "c")),
        (("rig-1", "x-y"), ("rig", "1-x-y")),
        (("w", "1-2-3"), ("w-1-2", "3")),
    ]

    def test_the_old_join_really_did_collapse_these_pairs(self):
        """The firing control, and it comes first deliberately. If this goes green trivially the
        pairs are not colliding pairs and the test below says nothing about #1566."""
        for left, right in self.COLLIDING:
            assert _old_join("rig-edit", *left) == _old_join("rig-edit", *right)

    def test_and_the_new_scheme_keeps_them_apart(self):
        build = audit_service.build_event_id
        for left, right in self.COLLIDING:
            assert build("rig-edit", *left) != build("rig-edit", *right)

    def test_distinct_pairs_that_never_collided_still_get_distinct_ids(self):
        """The other direction: a scheme that hashed everything to one constant would pass every
        assertion above. This is what stops "keeps them apart" from being satisfiable by a bug."""
        a = audit_service.build_event_id("rig-edit", "minerA", "chg1")
        b = audit_service.build_event_id("rig-edit", "minerB", "chg1")
        assert a != b
        assert a == "rig-edit:minerA:chg1"

    def test_the_id_decodes_back_to_exactly_the_parts_it_was_built_from(self):
        """The general proof; the pairs above are only samples. A decoder existing IS injectivity —
        no finite list of colliding inputs can establish that, and no future one can refute it."""
        for worker, change_id in (
            ("victim-chg1", "extra"),
            ("rig:1", "chg-2"),
            ("100% rig", "a b"),
            ("~tilde~", "%2D"),
            ("<script>", "\x00\n"),
            ("w" * 128, "r" * 64),
        ):
            eid = audit_service.build_event_id("rig-drift", worker, change_id)
            namespace, *parts = eid.split(":")
            assert namespace == "rig-drift"
            assert [unquote(p) for p in parts] == [worker, change_id]

    def test_a_rig_edit_row_can_no_longer_forge_the_rate_limited_marker(self):
        """Shape 1 as the issue states it: a device presenting as ``ratelimited-{victim}`` and
        reporting the victim's window start used to mint the victim's OWN marker id, so the
        victim's marker was dropped and the flood lost its Security-panel row."""
        window = 1756515600
        marker = audit_service.build_event_id("rig-edit-ratelimited", "victim", window)
        forged = audit_service.build_event_id("rig-edit", "ratelimited-victim", window)
        assert _old_join("rig-edit-ratelimited", "victim", window) == _old_join(
            "rig-edit", "ratelimited-victim", window
        )  # the control: it really was forgeable
        assert marker != forged

    def test_an_escaped_id_still_survives_the_sink_verbatim(self):
        """Escaping is only worth having if it lands INSIDE ``_SAFE_CHARS``. Outside it, every id
        carrying an unusual character would take ``clean_event_id``'s digest branch — still
        collision-free, but every such row's key becomes unreadable. This is the check that the
        fix did not quietly trade one property for the other."""
        for hostile in ("a-b", "a~b", "a%b", "a b", "a:b", "a<b", "a\x00b", "\u00e9"):
            eid = audit_service.build_event_id("rig-edit", hostile, "chg1")
            assert audit_service.clean_event_id(eid) == eid

    def test_a_lone_surrogate_is_escaped_rather_than_raising(self):
        """The escape runs INSIDE the poll loop, upstream of every sanitizer. A rig's JSON can
        carry U+D800 and ``json.loads`` hands it back as a lone surrogate, which ``quote``'s
        default strict UTF-8 encode REFUSES — a raise the old bare join never had, because it
        encoded nothing at all.

        ``TestCleanEventIdContract`` has a same-named test and it does NOT cover this: that one
        calls ``clean_event_id``, which sits downstream of the escape and so never sees the input
        that raises. The first assertion is the control, pinning that this input really is
        un-encodable so the test cannot pass by accident on an ordinary string."""
        lone = "\ud800"
        with pytest.raises(UnicodeEncodeError):
            lone.encode("utf-8")
        eid = audit_service.build_event_id("rig-edit", "miner1", lone)
        assert eid == "rig-edit:miner1:%ED%A0%80"
        assert audit_service.clean_event_id(eid) == eid

    def test_a_built_id_can_never_equal_a_uuid_fallback_or_a_mirrored_control_id(self):
        """``_record_audit_event`` falls back to ``f"{source}-{uuid4()}"`` and
        ``_mirror_control_audit`` writes the #33 log's own id. Neither carries a ``:`` and every
        built id does, so a rig cannot mint a key in either space however it names itself. The old
        scheme had this only as a reading of the call sites."""
        built = audit_service.build_event_id("rig-edit", "miner1", "chg1")
        assert ":" in built
        for other in (
            "host-edit-11111111-1111-4111-8111-111111111111",
            "rig-edit-11111111-1111-4111-8111-111111111111",
            "11111111-1111-4111-8111-111111111111",
        ):
            assert ":" not in other
            assert built != other


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

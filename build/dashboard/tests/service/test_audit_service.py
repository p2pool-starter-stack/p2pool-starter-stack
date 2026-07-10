"""audit_service (#349): sanitized read-only views over the host-written security logs.

The core property under test is the hostile-input posture: every string read from either log is
attacker-influenceable (the access log echoes request URIs and attempted usernames verbatim), so
anything outside the whitelisted charset must be stripped before it can reach the browser —
a raw ``<script>`` surviving to the API is stored XSS against the operator.
"""

import json

import pytest

from mining_dashboard.service import audit_service

XSS = "<script>alert(1)</script>"


def audit_line(**overrides):
    entry = {
        "ts": "2026-07-10T12:00:00Z",
        "id": "11111111-1111-4111-8111-111111111111",
        "actor": "admin",
        "action": "commit",
        "status": "applied",
        "keys": "XVB_ENABLED P2POOL_PORT",
    }
    entry.update(overrides)
    return json.dumps(entry)


def access_line(ts=1000.0, status=200, method="GET", uri="/api/state", user="admin"):
    return json.dumps(
        {"ts": ts, "status": status, "user_id": user, "request": {"method": method, "uri": uri}}
    )


@pytest.fixture
def audit_log(tmp_path, monkeypatch):
    path = tmp_path / "control.log"
    monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", str(path))
    return path


@pytest.fixture
def access_log(tmp_path, monkeypatch):
    path = tmp_path / "access.log"
    monkeypatch.setattr(audit_service.config, "ACCESS_LOG_PATH", str(path))
    return path


class TestClean:
    def test_strips_markup_and_quotes(self):
        assert "<" not in audit_service._clean(XSS)
        assert ">" not in audit_service._clean(XSS)
        # The readable remainder survives — strip, don't blank.
        assert "script" in audit_service._clean(XSS)
        assert audit_service._clean("a\"b'c\\d\x1b[31m") == "abcd31m"

    def test_non_strings_coerced(self):
        assert audit_service._clean(None) == ""
        assert audit_service._clean(42) == "42"

    def test_length_capped(self):
        assert len(audit_service._clean("a" * 500, 200)) == 200


class TestRecentChanges:
    def test_missing_file_is_empty(self, audit_log):
        assert audit_service.recent_changes() == []

    def test_entries_newest_first_and_whitelisted_fields(self, audit_log):
        audit_log.write_text(
            audit_line(status="previewed", action="preview")
            + "\n"
            + audit_line(status="applied", secret_extra="LEAKME")
            + "\n"
        )
        entries = audit_service.recent_changes()
        assert [e["status"] for e in entries] == ["applied", "previewed"]
        assert entries[0]["keys"] == "XVB_ENABLED P2POOL_PORT"
        # Field whitelist: a foreign key in the log never reaches the API payload.
        assert "secret_extra" not in entries[0]
        assert "LEAKME" not in json.dumps(entries)

    def test_hostile_content_is_neutralized(self, audit_log):
        # RED-THEN-GREEN guard: with _clean removed this test fails — the exact stored-XSS
        # (attacker -> operator) direction #33's reviews cared about.
        audit_log.write_text(audit_line(actor=XSS, keys='"><img src=x onerror=alert(1)>') + "\n")
        payload = json.dumps(audit_service.recent_changes())
        assert "<" not in payload and ">" not in payload
        assert "onerror=alert1" in payload  # readable remainder, but inert

    def test_garbage_lines_skipped(self, audit_log):
        audit_log.write_text('not json\n[1,2,3]\n"str"\n' + audit_line() + "\n")
        entries = audit_service.recent_changes()
        assert len(entries) == 1
        assert entries[0]["actor"] == "admin"

    def test_limit_applies(self, audit_log):
        audit_log.write_text("".join(audit_line(actor=f"u{i}") + "\n" for i in range(60)))
        entries = audit_service.recent_changes(limit=50)
        assert len(entries) == 50
        assert entries[0]["actor"] == "u59"  # newest first

    def test_reads_only_a_bounded_tail(self, audit_log, monkeypatch):
        # A large log costs one bounded read; the partial line cut at the window edge is dropped.
        monkeypatch.setattr(audit_service, "_TAIL_BYTES", 4096)
        audit_log.write_text("".join(audit_line(actor=f"user{i:06d}") + "\n" for i in range(200)))
        entries = audit_service.recent_changes(limit=200)
        assert 0 < len(entries) < 200
        assert entries[0]["actor"] == "user000199"


class TestAccessSummary:
    def test_missing_file_reports_unavailable(self, access_log):
        summary = audit_service.access_summary()
        assert summary == {
            "available": False,
            "entries": [],
            "failures_24h": 0,
            "last_failure_ts": None,
            "rotate_hint": False,
        }

    def test_counts_401s_inside_24h_only(self, access_log):
        now = 200000.0
        lines = [
            access_line(ts=now - 90000, status=401),  # outside the window — not counted
            access_line(ts=now - 100, status=200),
            access_line(ts=now - 50, status=401, user=""),
            access_line(ts=now - 10, status=401, user=""),
        ]
        access_log.write_text("\n".join(lines) + "\n")
        summary = audit_service.access_summary(now=now)
        assert summary["available"] is True
        assert summary["failures_24h"] == 2
        assert summary["last_failure_ts"] == now - 10
        assert summary["rotate_hint"] is False  # 2 < threshold

    def test_rotate_hint_at_threshold(self, access_log):
        now = 200000.0
        lines = [access_line(ts=now - i, status=401) for i in range(audit_service.ROTATE_HINT_401S)]
        access_log.write_text("\n".join(lines) + "\n")
        assert audit_service.access_summary(now=now)["rotate_hint"] is True

    def test_hostile_uri_and_user_neutralized(self, access_log):
        # RED-THEN-GREEN guard: the URI and attempted username are attacker-chosen bytes.
        access_log.write_text(access_line(uri="/%3Cscript%3E" + XSS, user=XSS) + "\n")
        payload = json.dumps(audit_service.access_summary(now=2000.0))
        assert "<" not in payload and ">" not in payload

    def test_fields_clamped_and_whitelisted(self, access_log):
        access_log.write_text(
            json.dumps({"ts": "garbage", "status": 9999, "user_id": None, "request": "not-a-dict"})
            + "\n"
            + json.dumps({"ts": 1.0, "status": "junk", "request": {}})
            + "\n"
            + access_line(method="EVILVERB")
            + "\n"
        )
        entries = audit_service.access_summary(now=2000.0)["entries"]
        assert entries[0]["method"] == "?"  # unknown verb collapses
        assert entries[1]["status"] == 0  # non-numeric status clamps to 0
        assert entries[2] == {"ts": 0.0, "status": 0, "method": "?", "uri": "", "user": ""}

    def test_entries_newest_first_and_limited(self, access_log):
        access_log.write_text(
            "".join(access_line(ts=float(i), uri=f"/p{i}") + "\n" for i in range(60))
        )
        entries = audit_service.access_summary(limit=50, now=100.0)["entries"]
        assert len(entries) == 50
        assert entries[0]["uri"] == "/p59"

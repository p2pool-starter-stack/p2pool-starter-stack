"""Pool credentials must not survive into the ``worker_config`` record, or out of any read of it
(#1543).

``pools`` is on the worker writable allowlist and a pool entry carries ``pass``, so the operator's
own POSTed ``changes`` used to be stored verbatim and served back on every load of that rig's
Inspect view. The defence is in two places and this module pins both, because they close different
halves and only together close the issue:

* ``add_worker_config_version`` strips before the INSERT, so a credential stops landing in the DB
  (and therefore in any backup of it) at all. The raw-column assertions below are the only ones
  that can see that half -- every reader would look clean under the read-side strip alone.
* ``_shaped`` strips on the way back out, which is what covers a row an OLDER build already wrote.
  Those rows are still in the table under any fix, so without this half the disclosure survives a
  deploy. ``_seed_legacy_row`` writes that shape on purpose, by going around the store's own
  writer, and ``test_the_legacy_seed_really_carries_the_credential`` is the control proving the
  seed armed -- a strip test whose fixture never held a credential passes for the wrong reason.

``strip_credentials``' own shape-agnosticism is NOT re-proved here: it is already covered at the
function's own unit (``tests/client/test_rigforge_config.py``, dict-shaped ``pools``, a credential
nested one level deeper, and a depth-bomb). Re-testing it through a DB round-trip would prove the
same behaviour at a more expensive tier.

The narrowness assertions (``url``/``user``/``keepalive`` still present) are load-bearing rather
than decorative: a strip that returned ``{}`` would pass every "the password is gone" assertion in
this file.
"""

import json

_PASSWORD = "s3cret-pool-password"
_FINGERPRINT = "aa:bb:cc:dd"


def _pools_with_credentials():
    """The writable-key diff an operator POSTs when they edit a pool -- credentials and all."""
    return {
        "pools": [
            {
                "url": "pool.example:3333",
                "user": "wallet.rig1",
                "pass": _PASSWORD,
                "tls-fingerprint": _FINGERPRINT,
                "keepalive": True,
            }
        ],
        "DONATION": 1,
    }


def _seed_legacy_row(state_manager, worker="rig1", change_id="chg-legacy", status="applied"):
    """A row exactly as a build BEFORE this fix wrote it: the credential in the stored JSON.

    Deliberately bypasses ``add_worker_config_version`` -- that writer now strips, so using it
    could not produce the row this half of the fix exists to defend against.
    """
    state_manager._conn.execute(
        "INSERT INTO worker_config (worker, change_id, ts, status, changes, reason, type) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (worker, change_id, 1000.0, status, json.dumps(_pools_with_credentials()), None, "apply"),
    )
    state_manager._conn.commit()


def _raw_changes(state_manager, worker="rig1"):
    """The ``changes`` column as bytes-on-disk, never through ``_shaped``."""
    cur = state_manager._conn.execute(
        "SELECT changes FROM worker_config WHERE worker = ? ORDER BY id DESC LIMIT 1", (worker,)
    )
    return cur.fetchone()[0]


class TestNothingCredentialShapedIsStored:
    """The write half: the credential never reaches the DB, so it is not in a backup either."""

    def test_the_stored_json_has_no_password(self, state_manager):
        state_manager.add_worker_config_version(
            "rig1", "chg-1", "applied", _pools_with_credentials(), None
        )
        raw = _raw_changes(state_manager)
        assert _PASSWORD not in raw
        assert _FINGERPRINT not in raw
        assert "pass" not in json.loads(raw)["pools"][0]
        assert "tls-fingerprint" not in json.loads(raw)["pools"][0]

    def test_the_stored_json_keeps_everything_else(self, state_manager):
        # Narrowness. A writer that stored `{}` would pass the test above and lose the audit row.
        state_manager.add_worker_config_version(
            "rig1", "chg-1", "applied", _pools_with_credentials(), None
        )
        stored = json.loads(_raw_changes(state_manager))
        assert stored["DONATION"] == 1
        assert stored["pools"][0] == {
            "url": "pool.example:3333",
            "user": "wallet.rig1",
            "keepalive": True,
        }

    def test_the_callers_own_dict_is_not_mutated(self, state_manager):
        # handle_worker_apply sends `changes` to the rig and passes the SAME object here. If the
        # strip mutated in place, the ordering of those two calls would decide whether the pool
        # password ever reached the pool -- a coupling nothing in either function declares.
        changes = _pools_with_credentials()
        state_manager.add_worker_config_version("rig1", "chg-1", "applied", changes, None)
        assert changes["pools"][0]["pass"] == _PASSWORD
        assert changes["pools"][0]["tls-fingerprint"] == _FINGERPRINT


class TestRowsAnOlderBuildWroteAreNotServed:
    """The read half: rows already in the table are stripped on the way out, no migration needed."""

    def test_the_legacy_seed_really_carries_the_credential(self, state_manager):
        # THE CONTROL. Everything below asserts an absence; this is the one assertion that proves
        # the absence is the strip working rather than the seed never having armed.
        _seed_legacy_row(state_manager)
        assert _PASSWORD in _raw_changes(state_manager)
        assert _FINGERPRINT in _raw_changes(state_manager)

    def test_history_read_is_stripped(self, state_manager):
        _seed_legacy_row(state_manager)
        pool = state_manager.get_worker_config_history("rig1")[0]["changes"]["pools"][0]
        assert "pass" not in pool
        assert "tls-fingerprint" not in pool
        assert pool["url"] == "pool.example:3333"

    def test_exact_id_read_is_stripped(self, state_manager):
        # get_worker_config_change is the OTHER row-returning read (#1369). It has its own query,
        # so a strip bolted onto get_worker_config_history alone would miss it.
        _seed_legacy_row(state_manager)
        pool = state_manager.get_worker_config_change("rig1", "chg-legacy")["changes"]["pools"][0]
        assert "pass" not in pool
        assert "tls-fingerprint" not in pool
        assert pool["user"] == "wallet.rig1"

    def test_last_applied_prefill_is_stripped(self, state_manager):
        # The field the issue names. It reads through get_worker_config_history, so it is covered
        # by the same edit rather than by a second one.
        _seed_legacy_row(state_manager)
        merged = state_manager.get_last_applied_worker_config("rig1")
        assert "pass" not in merged["pools"][0]
        assert "tls-fingerprint" not in merged["pools"][0]
        assert merged["DONATION"] == 1

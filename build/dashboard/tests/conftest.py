"""Shared pytest fixtures for the mining_dashboard test suite.

Everything here keeps tests hermetic: no real database on disk, no network, no containers.
"""

import pytest

from mining_dashboard.service.storage_service import StateManager


@pytest.fixture(autouse=True)
def _isolate_db(tmp_path, monkeypatch):
    """Safety net: any StateManager() built without an explicit path uses a throwaway temp
    file instead of the production /data location."""
    db_file = str(tmp_path / "test.db")
    monkeypatch.setattr(
        "mining_dashboard.service.storage_service.DB_FILE_PATH", db_file, raising=False
    )


@pytest.fixture
def state_manager():
    """A real StateManager backed by an in-memory SQLite database."""
    sm = StateManager(db_path=":memory:")
    yield sm
    sm.close()

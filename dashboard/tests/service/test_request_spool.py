"""The shared requests-spool writer (#1732).

These assert the property the four duplicated copies existed to maintain, which no test asserted
directly before: the request becomes visible under its final name ATOMICALLY, and the dotted temp
file it was staged through does not survive. The callers' own tests cover what each intent CARRIES;
this covers how it LANDS."""

import json
import os

import pytest

from mining_dashboard.service import request_spool


@pytest.fixture
def spool(tmp_path, monkeypatch):
    """Patch the attribute on the shared config object, not an import-time binding — the same
    shape every control test uses, and the reason `request_spool` reads it per call."""
    monkeypatch.setattr(request_spool.config, "CONTROL_REQUESTS_DIR", str(tmp_path))
    return tmp_path


class TestWrite:
    def test_lands_under_the_id_as_its_filename(self, spool):
        rid = request_spool.write({"id": "abc", "action": "diag-doctor"})
        assert rid == "abc"
        assert json.loads((spool / "abc.json").read_text()) == {
            "id": "abc",
            "action": "diag-doctor",
        }

    def test_no_temp_file_survives_a_successful_write(self, spool):
        request_spool.write({"id": "abc", "action": "diag-doctor"})
        # The dotted temp is the staging name. A leftover would be read by nothing, but its
        # presence would mean the rename did not happen and the visible file is a second write.
        assert [p.name for p in spool.iterdir()] == ["abc.json"]

    def test_the_visible_name_is_only_ever_created_by_a_rename(self, spool, monkeypatch):
        # THE ATOMICITY PROPERTY, and the reason the cleanup test above is not enough: a direct
        # in-place write leaves exactly ["abc.json"] too, so that test cannot tell the two shapes
        # apart. What distinguishes them is that the name the host runner watches for is only ever
        # brought into existence by a rename, so the runner can never observe a partial request.
        #
        # This matters more now than it did as four copies: one writer means a single future edit
        # removes the property for every intent type at once. Without this assertion that edit
        # leaves the suite green.
        seen = []
        real_replace = os.replace

        def recording_replace(src, dst):
            seen.append((os.path.basename(src), os.path.basename(dst), os.path.exists(dst)))
            return real_replace(src, dst)

        monkeypatch.setattr(os, "replace", recording_replace)
        request_spool.write({"id": "abc", "action": "diag-doctor"})
        # Staged under the dotted temp, and the final name did not exist before the rename made it.
        assert seen == [(".abc.tmp", "abc.json", False)]

    def test_an_unwritable_spool_raises_rather_than_dropping_the_request(self, monkeypatch):
        monkeypatch.setattr(request_spool.config, "CONTROL_REQUESTS_DIR", "/nonexistent/requests")
        with pytest.raises(OSError):
            request_spool.write({"id": "abc", "action": "diag-doctor"})

    def test_a_request_without_an_id_raises_before_writing_anything(self, spool):
        # The id is the caller's to mint; this writer must not invent one and must not leave a
        # half-named artefact behind when it is missing.
        with pytest.raises(KeyError):
            request_spool.write({"action": "diag-doctor"})
        assert list(spool.iterdir()) == []

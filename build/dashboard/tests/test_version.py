"""Unit tests for the build-version resolver (mining_dashboard/version.py, Issue #58).

The resolver turns build-baked env vars into the ``{text, title, dev}`` the dashboard header
badge renders. A clean release must show ``vX.Y.Z``; anything else must show an unmistakable
dev indicator (branch + short hash) so a working-tree build is never read as a release.
"""

from mining_dashboard.version import resolve_version


class TestRelease:
    def test_version_with_no_git_metadata_is_a_release(self):
        # A release tarball builds without a working tree: version present, no commit.
        info = resolve_version({"PITHEAD_VERSION": "1.3.0"})
        assert info == {"text": "v1.3.0", "title": "Pithead release v1.3.0", "dev": False}

    def test_leading_v_in_version_is_not_doubled(self):
        assert resolve_version({"PITHEAD_VERSION": "v2.0.1"})["text"] == "v2.0.1"

    def test_explicit_release_flag_wins_over_git_metadata(self):
        # The (future) release pipeline can force a release even with git info present.
        info = resolve_version(
            {
                "PITHEAD_VERSION": "1.3.0",
                "PITHEAD_RELEASE": "1",
                "PITHEAD_GIT_BRANCH": "main",
                "PITHEAD_GIT_COMMIT": "a1b2c3d",
            }
        )
        assert info["text"] == "v1.3.0"
        assert info["dev"] is False

    def test_release_flag_accepts_common_truthy_spellings(self):
        for val in ("1", "true", "TRUE", "yes", "on"):
            assert (
                resolve_version(
                    {
                        "PITHEAD_VERSION": "1.0.0",
                        "PITHEAD_RELEASE": val,
                        "PITHEAD_GIT_COMMIT": "deadbee",
                    }
                )["dev"]
                is False
            )


class TestDev:
    def test_branch_and_commit(self):
        info = resolve_version(
            {
                "PITHEAD_VERSION": "1.3.0",
                "PITHEAD_GIT_BRANCH": "feature/x",
                "PITHEAD_GIT_COMMIT": "a1b2c3d",
            }
        )
        assert info["text"] == "dev · feature/x @ a1b2c3d"
        assert info["dev"] is True
        assert "feature/x" in info["title"] and "a1b2c3d" in info["title"]

    def test_commit_only(self):
        assert resolve_version({"PITHEAD_GIT_COMMIT": "a1b2c3d"})["text"] == "dev · a1b2c3d"

    def test_branch_only(self):
        assert resolve_version({"PITHEAD_GIT_BRANCH": "main"})["text"] == "dev · main"

    def test_dirty_marker_passes_through(self):
        # render_env appends -dirty for uncommitted changes; it must reach the badge verbatim.
        info = resolve_version(
            {"PITHEAD_GIT_BRANCH": "main", "PITHEAD_GIT_COMMIT": "a1b2c3d-dirty"}
        )
        assert info["text"] == "dev · main @ a1b2c3d-dirty"
        assert info["dev"] is True

    def test_a_versioned_build_with_a_commit_is_still_dev(self):
        # The decisive signal is the commit: a normal `docker compose build` bakes both VERSION
        # and the git commit, and must read as dev — never as the release named in VERSION.
        info = resolve_version({"PITHEAD_VERSION": "1.3.0", "PITHEAD_GIT_COMMIT": "a1b2c3d"})
        assert info["dev"] is True
        assert info["text"] == "dev · a1b2c3d"

    def test_no_metadata_falls_back_to_generic_dev(self):
        info = resolve_version({})
        assert info == {"text": "dev build", "title": "Development build", "dev": True}

    def test_blank_values_treated_as_absent(self):
        info = resolve_version(
            {"PITHEAD_VERSION": "  ", "PITHEAD_GIT_BRANCH": "", "PITHEAD_GIT_COMMIT": "  "}
        )
        assert info["text"] == "dev build"

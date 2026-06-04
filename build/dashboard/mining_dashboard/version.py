"""Resolve the running stack's version for the dashboard header badge (Issue #58).

Nothing else in the UI says *which build is running*. This surfaces it: a clean release
shows ``vX.Y.Z``; any other build shows an unmistakable dev indicator (branch + short
commit), so a working-tree build is never read as a release.

The values are baked into the image at build time as environment variables (see the
dashboard ``Dockerfile`` build-args, fed by ``pithead`` from the top-level ``VERSION`` file
— the single source of truth — and ``git``). Reading only the environment keeps the
container self-describing and this resolver a pure, unit-testable function of its inputs.
"""
import os


def _flag(value):
    """Truthy interpretation of an env flag string."""
    return (value or "").strip().lower() in ("1", "true", "yes", "on")


def resolve_version(env=None):
    """Return ``{"text", "title", "dev"}`` describing the running build.

    - Released build   -> ``{"text": "v1.3.0", "dev": False}``
    - Dev/working tree -> ``{"text": "dev · main @ a1b2c3d", "dev": True}``

    ``text`` is the badge label, ``title`` its hover tooltip, and ``dev`` lets the client
    tell a release from a working-tree build. Source of truth is the top-level ``VERSION``
    file, surfaced as ``PITHEAD_VERSION``. A build counts as a release when
    ``PITHEAD_RELEASE`` is set, or when a version is present with no git metadata (a release
    tarball built without a working tree); otherwise it's a dev build.
    """
    env = os.environ if env is None else env
    version = (env.get("PITHEAD_VERSION") or "").strip()
    if version.startswith("v"):
        version = version[1:]
    branch = (env.get("PITHEAD_GIT_BRANCH") or "").strip()
    commit = (env.get("PITHEAD_GIT_COMMIT") or "").strip()

    is_release = _flag(env.get("PITHEAD_RELEASE")) or (bool(version) and not commit)
    if is_release and version:
        return {"text": f"v{version}", "title": f"Pithead release v{version}", "dev": False}

    # Dev / working-tree build: branch + short hash, so it's unmistakably not a release.
    if branch and commit:
        text = f"dev · {branch} @ {commit}"
    elif commit:
        text = f"dev · {commit}"
    elif branch:
        text = f"dev · {branch}"
    else:
        text = "dev build"

    detail = ", ".join(p for p in (f"branch {branch}" if branch else "",
                                   f"commit {commit}" if commit else "") if p)
    title = f"Development build ({detail})" if detail else "Development build"
    return {"text": text, "title": title, "dev": True}

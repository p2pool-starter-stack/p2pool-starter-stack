# ==========================================================================
# Shared base: system deps + package metadata + source. Deliberately has NO uv —
# the production image must not ship the build tool (a runtime image with uv pulls
# uv's own CVEs into image scans, #282). uv lives only in the build/test stages.
# ==========================================================================
# Pinned by digest (#135) so the python:3.11-slim tag can't be silently re-pointed.
FROM python:3.11-slim@sha256:9c900dea9e8fb7e16277c179b555cc72d29a352dbc33cff48ad5a0412fd5bfc7 AS base

# Run from a project venv on PATH (so entrypoint.sh's `python3` resolves to it); use the
# digest-pinned base interpreter (never let uv download a different Python); compile bytecode and
# copy (not hardlink) from the BuildKit cache mount used on the sync steps below.
ENV UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PATH="/app/.venv/bin:$PATH"

# System dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Lock + metadata first (better layer caching), then the source.
COPY pyproject.toml uv.lock ./
COPY mining_dashboard/ ./mining_dashboard/

# ==========================================================================
# Build stage: uv resolves the locked runtime deps into /app/.venv. uv is COPYed in
# here (and in test) but never into production.
# ==========================================================================
FROM base AS build
COPY --from=ghcr.io/astral-sh/uv:0.10.10@sha256:cbe0a44ba994e327b8fe7ed72beef1aaa7d2c4c795fd406d1dbf328bacb2f1c5 /uv /bin/
RUN --mount=type=cache,target=/root/.cache/uv uv sync --locked

# ==========================================================================
# Test stage: add the test extras to the venv and run the suite with coverage.
# Build explicitly with `docker build --target test .` (CI does this);
# a normal `docker compose build` targets the production stage and skips it.
# ==========================================================================
FROM build AS test
RUN --mount=type=cache,target=/root/.cache/uv uv sync --locked --extra test
COPY tests/ ./tests/
RUN python -m pytest --cov=mining_dashboard --cov-report=term-missing --cov-fail-under=80

# ==========================================================================
# Production stage: copy ONLY the resolved venv from `build` (no uv binary) and run it.
# ==========================================================================
FROM base AS production
COPY --from=build /app/.venv /app/.venv
# entrypoint runs the app; healthcheck.sh (#904) HEADs /api/state with the venv's own python3
# (the slim image ships no curl/wget).
COPY entrypoint.sh healthcheck.sh ./
RUN chmod +x entrypoint.sh healthcheck.sh

# Stack version, baked at build so the running container is self-describing (Issue #58).
# PITHEAD_VERSION comes from the top-level VERSION file (the source of truth); the git args
# mark a dev/working-tree build. pithead's render_env feeds these via docker-compose build args.
# The dashboard reads them at runtime (mining_dashboard/version.py) for the header badge; the OCI
# labels make the same info readable with `docker inspect`.
ARG PITHEAD_VERSION=""
ARG PITHEAD_GIT_COMMIT=""
ARG PITHEAD_GIT_BRANCH=""
ARG PITHEAD_RELEASE=""
ENV PITHEAD_VERSION=$PITHEAD_VERSION \
    PITHEAD_GIT_COMMIT=$PITHEAD_GIT_COMMIT \
    PITHEAD_GIT_BRANCH=$PITHEAD_GIT_BRANCH \
    PITHEAD_RELEASE=$PITHEAD_RELEASE
LABEL org.opencontainers.image.title="Pithead Dashboard" \
      org.opencontainers.image.version=$PITHEAD_VERSION \
      org.opencontainers.image.revision=$PITHEAD_GIT_COMMIT

# Run non-root (#255). debian-slim has no stock uid-1000 user, so create 'pithead' (uid:gid
# 1000:1000) to match the uid pithead chowns ${DASHBOARD_DATA_DIR} (/data) to. /app + the venv stay
# root-owned and are only read/executed at runtime; the SQLite history is written to /data and the
# clearnet-state marker to /clearnet-state. Create both in-image owned by pithead: with a host
# bind-mount (the real stack) the mount masks them and pithead's chown governs ownership; with a
# NAMED volume (the integration mini-stack) Docker seeds the empty volume from the image dir's
# ownership, so this is what makes /data writable there. This lets compose finally cap_drop:[ALL]
# the dashboard — it no longer needs root's CAP_DAC_OVERRIDE to write the host-user-owned data dir.
RUN groupadd -g 1000 pithead && useradd -u 1000 -g 1000 -m -s /usr/sbin/nologin pithead \
    && install -d -o pithead -g pithead /data /clearnet-state
USER pithead

ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]

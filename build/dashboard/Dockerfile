# ==========================================================================
# Shared base: system deps + package metadata + source.
# ==========================================================================
# Pinned by digest (#135) so the python:3.11-slim tag can't be silently re-pointed.
FROM python:3.11-slim@sha256:a3ab0b966bc4e91546a033e22093cb840908979487a9fc0e6e38295747e49ac0 AS base

# uv for reproducible, hash-locked installs from uv.lock (#283). The uv binary is copied from the
# official image, pinned by digest (same posture as the base image, #135).
COPY --from=ghcr.io/astral-sh/uv:0.10.10@sha256:cbe0a44ba994e327b8fe7ed72beef1aaa7d2c4c795fd406d1dbf328bacb2f1c5 /uv /uvx /bin/

# Install into a project venv on PATH (so entrypoint.sh's `python3` resolves to it); use the
# digest-pinned base interpreter (never let uv download a different Python); compile bytecode and
# copy (not hardlink) since the cache and target may be on different layers.
ENV UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_NO_CACHE=1 \
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
# Test stage: install with test extras and run the suite with coverage.
# Build explicitly with `docker build --target test .` (CI does this);
# a normal `docker compose build` targets the production stage and skips it.
# ==========================================================================
FROM base AS test
RUN uv sync --locked --extra test
COPY tests/ ./tests/
RUN python -m pytest --cov=mining_dashboard --cov-report=term-missing --cov-fail-under=80

# ==========================================================================
# Production stage: install the package (runtime deps only) and run it.
# ==========================================================================
FROM base AS production
# Runtime deps + the package only (no test/dev extras).
RUN uv sync --locked
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

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

ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]

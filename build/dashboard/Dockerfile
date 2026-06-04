# ==========================================================================
# Shared base: system deps + package metadata + source.
# ==========================================================================
FROM python:3.11-slim AS base

# System dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Package metadata first (better layer caching), then the source.
COPY pyproject.toml ./
COPY mining_dashboard/ ./mining_dashboard/

# ==========================================================================
# Test stage: install with test extras and run the suite with coverage.
# Build explicitly with `docker build --target test .` (CI does this);
# a normal `docker compose build` targets the production stage and skips it.
# ==========================================================================
FROM base AS test
RUN pip install --no-cache-dir -e ".[test]"
COPY tests/ ./tests/
RUN python -m pytest --cov=mining_dashboard --cov-report=term-missing --cov-fail-under=80

# ==========================================================================
# Production stage: install the package (runtime deps only) and run it.
# ==========================================================================
FROM base AS production
RUN pip install --no-cache-dir -e .
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

# ==========================================================================
# Shared base: system deps + package metadata + source.
# ==========================================================================
FROM python:3.11-slim AS base

# System dependencies for network discovery (mDNS/Avahi) and routing.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    libnss-mdns \
    avahi-utils \
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
ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]

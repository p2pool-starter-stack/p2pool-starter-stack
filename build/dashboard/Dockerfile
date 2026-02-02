FROM python:3.11-slim

# Install system dependencies required for network discovery (mDNS/Avahi) and routing
RUN apt-get update && apt-get install -y \
    bash \
    libnss-mdns \
    avahi-utils \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python runtime dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source code and entrypoint script
COPY mining_dashboard/ ./mining_dashboard/
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# Expose the web server port (Default: 8000)
EXPOSE 8000

ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]
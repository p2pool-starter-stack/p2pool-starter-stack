FROM python:3.11-slim

# Install system deps (Required for mDNS/Avahi to find miners on .local)
RUN apt-get update && apt-get install -y \
    bash \
    libnss-mdns \
    avahi-utils \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python Dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the entire dashboard module
COPY mining_dashboard/ ./mining_dashboard/
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# Expose the new port (8080 is defined in config.py)
EXPOSE 8080

ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]
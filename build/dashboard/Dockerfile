FROM python:3.11-slim

# Install system deps
RUN apt-get update && apt-get install -y \
    bash \
    libnss-mdns \
    avahi-utils \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY mining_status.py .
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

EXPOSE 8000
ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]
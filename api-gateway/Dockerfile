FROM python:3.11-slim

WORKDIR /app

# Install curl for Docker health check
# python:3.11-slim does not include it by default
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY api-gateway/gateway.py /app/gateway.py
COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

# Health check — Docker marks container unhealthy if this fails 3 times
# Interval: check every 10 seconds
# Timeout: fail if no response within 5 seconds
# Retries: 3 failures = unhealthy
# Start period: give the app 10 seconds to start before checking
HEALTHCHECK --interval=10s --timeout=5s --retries=3 --start-period=15s \
  CMD curl -f http://localhost:80/health/live || exit 1

CMD ["uvicorn", "gateway:app", "--host", "0.0.0.0", "--port", "80"]

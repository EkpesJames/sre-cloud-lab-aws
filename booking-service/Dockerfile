FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

RUN adduser --disabled-password --gecos "" appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY booking-service/booking.py .

RUN chown -R appuser:appuser /app
USER appuser

HEALTHCHECK --interval=10s --timeout=5s --retries=3 --start-period=15s \
  CMD curl -f http://localhost:80/health/live || exit 1

CMD ["uvicorn", "booking:app", "--host", "0.0.0.0", "--port", "80"]

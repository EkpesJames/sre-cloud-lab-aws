from fastapi import FastAPI, Response, Request
from fastapi.responses import JSONResponse
from prometheus_client import Counter, Histogram, Gauge, generate_latest
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.propagate import extract
from contextlib import asynccontextmanager
import time
import random
import os
import json
import logging
import sys

# ── Structured logging ────────────────────────────────────────────────────────
class JsonFormatter(logging.Formatter):
    def format(self, record):
        log = {
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "service": "payment-service",
            "message": record.getMessage(),
        }
        if hasattr(record, "extra"):
            log.update(record.extra)
        return json.dumps(log)

handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logger = logging.getLogger("payment-service")
logger.addHandler(handler)
logger.setLevel(logging.INFO)

# ── Config ────────────────────────────────────────────────────────────────────
ERROR_RATE      = float(os.getenv("APP_ERROR_RATE", "0.05"))   # 5% — tightest SLO
LATENCY_SECONDS = float(os.getenv("APP_LATENCY_SECONDS", "0.1"))  # 100ms
JAEGER_ENDPOINT = os.getenv("JAEGER_ENDPOINT", "http://jaeger:4317")
SERVICE_NAME    = "payment-service"

# ── OpenTelemetry ─────────────────────────────────────────────────────────────
resource = Resource.create({"service.name": SERVICE_NAME, "service.version": "1.0.0"})
provider = TracerProvider(resource=resource)
try:
    provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=JAEGER_ENDPOINT, insecure=True))
    )
except Exception as e:
    logger.warning("Jaeger unavailable", extra={"error": str(e)})
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(SERVICE_NAME)

# ── Metrics ───────────────────────────────────────────────────────────────────
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status", "service"]
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "Request latency",
    ["endpoint", "service"],
    buckets=[0.01, 0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 2.0]
)
PAYMENTS_PROCESSED = Counter(
    "payments_processed_total",
    "Total payments processed",
    ["status", "method"]
)
PAYMENT_AMOUNT = Histogram(
    "payment_amount_pounds",
    "Payment amounts in GBP",
    buckets=[10, 25, 50, 100, 200, 500, 1000]
)
APP_INFO = Gauge("app_info", "App metadata", ["version", "service"])
APP_INFO.labels(version="1.0.0", service=SERVICE_NAME).set(1)

for status in ["success", "error"]:
    REQUEST_COUNT.labels(method="POST", endpoint="/payments", status=status, service=SERVICE_NAME)

# ── Lifespan ──────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Payment service starting")
    yield
    logger.info("Payment service shutting down gracefully")

app = FastAPI(title="Payment Service", version="1.0.0", lifespan=lifespan)
FastAPIInstrumentor.instrument_app(app)

# ── Payment methods ───────────────────────────────────────────────────────────
PAYMENT_METHODS = ["card", "bank_transfer", "wallet"]

# ── Main payment endpoint ─────────────────────────────────────────────────────
@app.post("/payments")
async def process_payment(request: Request):
    start = time.time()
    body = await request.json()

    span = trace.get_current_span()
    trace_id = format(span.get_span_context().trace_id, "032x") \
        if span.get_span_context().is_valid else "no-trace"

    amount   = body.get("amount", round(random.uniform(10, 500), 2))
    method   = body.get("method", random.choice(PAYMENT_METHODS))
    booking_id = body.get("booking_id", "unknown")

    with tracer.start_as_current_span("process-payment") as payment_span:
        payment_span.set_attribute("payment.amount", amount)
        payment_span.set_attribute("payment.method", method)
        payment_span.set_attribute("booking.id", booking_id)

        # Simulate payment processing latency
        time.sleep(LATENCY_SECONDS)

        # Simulate payment failures (5% — strict SLO)
        if random.random() < ERROR_RATE:
            duration = time.time() - start
            REQUEST_COUNT.labels(
                method="POST", endpoint="/payments",
                status="error", service=SERVICE_NAME
            ).inc()
            REQUEST_LATENCY.labels(
                endpoint="/payments", service=SERVICE_NAME
            ).observe(duration)
            PAYMENTS_PROCESSED.labels(status="failed", method=method).inc()
            payment_span.set_attribute("error", True)

            logger.error("Payment failed", extra={
                "trace_id": trace_id,
                "booking_id": booking_id,
                "amount": amount,
                "method": method,
            })
            return JSONResponse(status_code=500, content={
                "error": "Payment processing failed",
                "booking_id": booking_id,
                "trace_id": trace_id,
            })

        # Success
        payment_id = f"PAY-{int(time.time())}-{random.randint(1000,9999)}"
        duration   = time.time() - start

        REQUEST_COUNT.labels(
            method="POST", endpoint="/payments",
            status="success", service=SERVICE_NAME
        ).inc()
        REQUEST_LATENCY.labels(
            endpoint="/payments", service=SERVICE_NAME
        ).observe(duration)
        PAYMENTS_PROCESSED.labels(status="success", method=method).inc()
        PAYMENT_AMOUNT.observe(amount)

        logger.info("Payment processed", extra={
            "trace_id": trace_id,
            "payment_id": payment_id,
            "booking_id": booking_id,
            "amount": amount,
            "method": method,
            "duration_ms": round(duration * 1000, 2),
        })

        return JSONResponse(status_code=200, content={
            "payment_id": payment_id,
            "booking_id": booking_id,
            "amount": amount,
            "method": method,
            "status": "approved",
            "trace_id": trace_id,
        })

# ── Health endpoints ──────────────────────────────────────────────────────────
@app.get("/health/live")
def liveness():
    return JSONResponse(status_code=200, content= {"status": "alive", "service": SERVICE_NAME})

@app.get("/health/ready")
def readiness():
    return JSONResponse(status_code=200, content= {"status": "ready", "service": SERVICE_NAME})

# ── Metrics ───────────────────────────────────────────────────────────────────
@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type="text/plain")

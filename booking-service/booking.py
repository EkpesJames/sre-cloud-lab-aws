from fastapi import FastAPI, Response, Request
from fastapi.responses import JSONResponse
from prometheus_client import Counter, Histogram, Gauge, generate_latest
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.propagate import inject
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type
from contextlib import asynccontextmanager
import time
import random
import os
import json
import logging
import sys
import threading
import httpx

# ── Structured logging ────────────────────────────────────────────────────────
class JsonFormatter(logging.Formatter):
    def format(self, record):
        log = {
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "service": "booking-service",
            "message": record.getMessage(),
        }
        if hasattr(record, "extra"):
            log.update(record.extra)
        return json.dumps(log)

handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logger = logging.getLogger("booking-service")
logger.addHandler(handler)
logger.setLevel(logging.INFO)

# ── Config ────────────────────────────────────────────────────────────────────
ERROR_RATE       = float(os.getenv("APP_ERROR_RATE", "0.10"))
LATENCY_SECONDS  = float(os.getenv("APP_LATENCY_SECONDS", "0.15"))
JAEGER_ENDPOINT  = os.getenv("JAEGER_ENDPOINT", "http://jaeger:4317")
PAYMENT_SERVICE  = os.getenv("PAYMENT_SERVICE_URL", "http://payment-service:80")
SERVICE_NAME     = "booking-service"
CIRCUIT_THRESHOLD = float(os.getenv("CIRCUIT_THRESHOLD", "0.50"))
CIRCUIT_TIMEOUT   = int(os.getenv("CIRCUIT_TIMEOUT", "30"))

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

# ── Circuit breaker ───────────────────────────────────────────────────────────
class CircuitBreaker:
    CLOSED = "closed"
    OPEN = "open"
    HALF_OPEN = "half_open"

    def __init__(self, threshold, timeout):
        self.threshold = threshold
        self.timeout   = timeout
        self.state     = self.CLOSED
        self.error_count = 0
        self.total_count = 0
        self.opened_at   = None
        self._lock       = threading.Lock()

    def record_success(self):
        with self._lock:
            self.total_count += 1
            if self.state == self.HALF_OPEN:
                self.state = self.CLOSED
                self.error_count = 0
                self.total_count = 0

    def record_failure(self):
        with self._lock:
            self.total_count += 1
            self.error_count += 1
            if self.state == self.HALF_OPEN:
                self.state = self.OPEN
                self.opened_at = time.time()
                return
            if self.total_count >= 10:
                if self.error_count / self.total_count >= self.threshold:
                    if self.state == self.CLOSED:
                        self.state = self.OPEN
                        self.opened_at = time.time()

    def allow_request(self):
        with self._lock:
            if self.state == self.CLOSED:
                return True
            if self.state == self.OPEN:
                if time.time() - self.opened_at >= self.timeout:
                    self.state = self.HALF_OPEN
                    return True
                return False
            return True

circuit_breaker = CircuitBreaker(CIRCUIT_THRESHOLD, CIRCUIT_TIMEOUT)

# ── Metrics ───────────────────────────────────────────────────────────────────
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total requests",
    ["method", "endpoint", "status", "service"]
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "Request latency",
    ["endpoint", "service"],
    buckets=[0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 2.0, 5.0]
)
BOOKINGS_CREATED = Counter(
    "bookings_created_total",
    "Total bookings",
    ["status", "event_type"]
)
PAYMENT_CALL_DURATION = Histogram(
    "payment_call_duration_seconds",
    "Time spent calling payment service",
    buckets=[0.05, 0.1, 0.2, 0.5, 1.0, 2.0]
)
CIRCUIT_STATE = Gauge(
    "circuit_breaker_state",
    "Circuit breaker state",
    ["state", "service"]
)
APP_INFO = Gauge("app_info", "App metadata", ["version", "service"])
APP_INFO.labels(version="1.0.0", service=SERVICE_NAME).set(1)

for state in ["closed", "open", "half_open"]:
    CIRCUIT_STATE.labels(state=state, service=SERVICE_NAME).set(1 if state == "closed" else 0)

EVENT_TYPES = ["concert", "theatre", "sports", "conference", "comedy"]

# ── Call payment service with retry ──────────────────────────────────────────
@retry(
    stop=stop_after_attempt(2),
    wait=wait_exponential(multiplier=1, min=1, max=3),
    retry=retry_if_exception_type(Exception),
    reraise=True
)
def call_payment_service(booking_id: str, amount: float, headers: dict) -> dict:
    with tracer.start_as_current_span("call-payment-service") as span:
        span.set_attribute("payment.service.url", PAYMENT_SERVICE)
        span.set_attribute("booking.id", booking_id)

        # Inject trace context into outgoing headers for cross-service tracing
        inject(headers)

        start = time.time()
        response = httpx.post(
            f"{PAYMENT_SERVICE}/payments",
            json={"booking_id": booking_id, "amount": amount},
            headers=headers,
            timeout=5.0
        )
        PAYMENT_CALL_DURATION.observe(time.time() - start)

        if response.status_code != 200:
            raise Exception(f"Payment failed: {response.status_code}")

        return response.json()

# ── Lifespan ──────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Booking service starting")
    yield
    logger.info("Booking service shutting down gracefully")

app = FastAPI(title="Booking Service", version="1.0.0", lifespan=lifespan)
FastAPIInstrumentor.instrument_app(app)

# ── Create booking endpoint ───────────────────────────────────────────────────
@app.post("/bookings")
async def create_booking(request: Request):
    start = time.time()
    body  = await request.json()

    span = trace.get_current_span()
    trace_id = format(span.get_span_context().trace_id, "032x") \
        if span.get_span_context().is_valid else "no-trace"

    event_type = body.get("event_type", random.choice(EVENT_TYPES))
    seats      = body.get("seats", random.randint(1, 4))
    amount     = round(seats * random.uniform(25, 150), 2)
    booking_id = f"BK-{int(time.time())}-{random.randint(1000,9999)}"

    # Circuit breaker check
    if not circuit_breaker.allow_request():
        REQUEST_COUNT.labels(
            method="POST", endpoint="/bookings",
            status="rejected", service=SERVICE_NAME
        ).inc()
        return JSONResponse(status_code=503, content={
            "error": "Booking service temporarily unavailable",
            "reason": "circuit_breaker_open",
            "trace_id": trace_id,
        })

    # Simulate booking processing
    time.sleep(LATENCY_SECONDS)

    # Simulate booking-layer error
    if random.random() < ERROR_RATE:
        circuit_breaker.record_failure()
        duration = time.time() - start
        REQUEST_COUNT.labels(
            method="POST", endpoint="/bookings",
            status="error", service=SERVICE_NAME
        ).inc()
        REQUEST_LATENCY.labels(endpoint="/bookings", service=SERVICE_NAME).observe(duration)
        BOOKINGS_CREATED.labels(status="failed", event_type=event_type).inc()
        return JSONResponse(status_code=500, content={
            "error": "Booking creation failed",
            "trace_id": trace_id,
        })

    # Call payment service — propagates trace context
    headers = {}
    try:
        payment_result = call_payment_service(booking_id, amount, headers)
        circuit_breaker.record_success()
    except Exception as e:
        circuit_breaker.record_failure()
        duration = time.time() - start
        REQUEST_COUNT.labels(
            method="POST", endpoint="/bookings",
            status="error", service=SERVICE_NAME
        ).inc()
        REQUEST_LATENCY.labels(endpoint="/bookings", service=SERVICE_NAME).observe(duration)
        BOOKINGS_CREATED.labels(status="payment_failed", event_type=event_type).inc()
        logger.error("Payment call failed", extra={
            "trace_id": trace_id,
            "booking_id": booking_id,
            "error": str(e)
        })
        return JSONResponse(status_code=502, content={
            "error": "Payment processing failed",
            "booking_id": booking_id,
            "trace_id": trace_id,
        })

    # Success
    duration = time.time() - start
    REQUEST_COUNT.labels(
        method="POST", endpoint="/bookings",
        status="success", service=SERVICE_NAME
    ).inc()
    REQUEST_LATENCY.labels(endpoint="/bookings", service=SERVICE_NAME).observe(duration)
    BOOKINGS_CREATED.labels(status="confirmed", event_type=event_type).inc()

    logger.info("Booking confirmed", extra={
        "trace_id": trace_id,
        "booking_id": booking_id,
        "event_type": event_type,
        "seats": seats,
        "amount": amount,
        "duration_ms": round(duration * 1000, 2),
    })

    return JSONResponse(status_code=200, content={
        "booking_id": booking_id,
        "event_type": event_type,
        "seats": seats,
        "amount": amount,
        "payment": payment_result,
        "status": "confirmed",
        "trace_id": trace_id,
    })

# ── Health endpoints ──────────────────────────────────────────────────────────
@app.get("/health/live")
def liveness():
    return JSONResponse(status_code=200, content= {"status": "alive", "service": SERVICE_NAME})

@app.get("/health/ready")
def readiness():
    if circuit_breaker.state == CircuitBreaker.OPEN:
        return JSONResponse(status_code=503, content= {"status": "not_ready", "reason": "circuit_breaker_open"})
    return JSONResponse(status_code=200, content= {"status": "ready", "service": SERVICE_NAME,
                               "circuit_breaker": circuit_breaker.state})

@app.get("/health/circuit")
def circuit_status():
    return JSONResponse(status_code=200, content= {
        "state": circuit_breaker.state,
        "error_count": circuit_breaker.error_count,
        "total_count": circuit_breaker.total_count,
        "threshold": circuit_breaker.threshold,
        "service": SERVICE_NAME,
    })

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type="text/plain")

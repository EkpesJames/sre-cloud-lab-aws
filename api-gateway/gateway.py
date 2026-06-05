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
            "service": "api-gateway",
            "message": record.getMessage(),
        }
        if hasattr(record, "extra"):
            log.update(record.extra)
        return json.dumps(log)

handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logger = logging.getLogger("api-gateway")
logger.addHandler(handler)
logger.setLevel(logging.INFO)

# ── Config ────────────────────────────────────────────────────────────────────
ERROR_RATE        = float(os.getenv("APP_ERROR_RATE", "0.30"))
LATENCY_SECONDS   = float(os.getenv("APP_LATENCY_SECONDS", "0.2"))
JAEGER_ENDPOINT   = os.getenv("JAEGER_ENDPOINT", "http://jaeger:4317")
BOOKING_SERVICE   = os.getenv("BOOKING_SERVICE_URL", "http://booking-service:80")
SERVICE_NAME      = "api-gateway"
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
BOOKING_CALL_DURATION = Histogram(
    "booking_call_duration_seconds",
    "Time spent calling booking service",
    buckets=[0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0]
)
CIRCUIT_STATE = Gauge(
    "circuit_breaker_state",
    "Circuit breaker state",
    ["state", "service"]
)
APP_INFO = Gauge("app_info", "App metadata", ["version", "service"])
APP_INFO.labels(version="1.0.0", service=SERVICE_NAME).set(1)
DEPENDENCY_UP = Gauge("dependency_up", "Dependency health", ["dependency"])
DEPENDENCY_UP.labels(dependency="booking-service").set(1)

for state in ["closed", "open", "half_open"]:
    CIRCUIT_STATE.labels(state=state, service=SERVICE_NAME).set(1 if state == "closed" else 0)
for status in ["success", "error", "rejected"]:
    REQUEST_COUNT.labels(method="GET", endpoint="/", status=status, service=SERVICE_NAME)

dependency_healthy = True

# ── Call booking service ──────────────────────────────────────────────────────
@retry(
    stop=stop_after_attempt(2),
    wait=wait_exponential(multiplier=1, min=1, max=3),
    retry=retry_if_exception_type(Exception),
    reraise=True
)
def call_booking_service(event_type: str, seats: int, headers: dict) -> dict:
    with tracer.start_as_current_span("call-booking-service") as span:
        span.set_attribute("booking.event_type", event_type)
        span.set_attribute("booking.seats", seats)
        inject(headers)

        start = time.time()
        response = httpx.post(
            f"{BOOKING_SERVICE}/bookings",
            json={"event_type": event_type, "seats": seats},
            headers=headers,
            timeout=10.0
        )
        BOOKING_CALL_DURATION.observe(time.time() - start)

        if response.status_code != 200:
            raise Exception(f"Booking failed: {response.status_code}")

        return response.json()

# ── Lifespan ──────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("API Gateway starting")
    yield
    logger.info("API Gateway shutting down gracefully")

app = FastAPI(title="Cloud SRE Lab — API Gateway", version="1.0.0", lifespan=lifespan)
FastAPIInstrumentor.instrument_app(app)

# ── Root endpoint (legacy — still works for health testing) ───────────────────
@app.get("/")
def root(request: Request):
    start = time.time()
    span = trace.get_current_span()
    trace_id = format(span.get_span_context().trace_id, "032x") \
        if span.get_span_context().is_valid else "no-trace"

    if not circuit_breaker.allow_request():
        REQUEST_COUNT.labels(method="GET", endpoint="/", status="rejected", service=SERVICE_NAME).inc()
        return JSONResponse(status_code=503, content={
            "error": "Service temporarily unavailable",
            "reason": "circuit_breaker_open",
            "trace_id": trace_id,
        })

    if random.random() < ERROR_RATE:
        circuit_breaker.record_failure()
        REQUEST_COUNT.labels(method="GET", endpoint="/", status="error", service=SERVICE_NAME).inc()
        REQUEST_LATENCY.labels(endpoint="/", service=SERVICE_NAME).observe(time.time() - start)
        raise Exception("Simulated failure")

    time.sleep(LATENCY_SECONDS)
    circuit_breaker.record_success()
    REQUEST_COUNT.labels(method="GET", endpoint="/", status="success", service=SERVICE_NAME).inc()
    REQUEST_LATENCY.labels(endpoint="/", service=SERVICE_NAME).observe(time.time() - start)

    return {"message": "Cloud SRE Lab — API Gateway", "trace_id": trace_id,
            "circuit_breaker": circuit_breaker.state}

# ── Book endpoint — full distributed flow ─────────────────────────────────────
@app.post("/book")
async def book(request: Request):
    start = time.time()
    body  = await request.json()

    span = trace.get_current_span()
    trace_id = format(span.get_span_context().trace_id, "032x") \
        if span.get_span_context().is_valid else "no-trace"

    event_type = body.get("event_type", "concert")
    seats      = body.get("seats", random.randint(1, 4))

    if not circuit_breaker.allow_request():
        REQUEST_COUNT.labels(method="POST", endpoint="/book", status="rejected", service=SERVICE_NAME).inc()
        return JSONResponse(status_code=503, content={
            "error": "Gateway circuit breaker open",
            "trace_id": trace_id,
        })

    headers = {}
    try:
        result = call_booking_service(event_type, seats, headers)
        circuit_breaker.record_success()
        DEPENDENCY_UP.labels(dependency="booking-service").set(1)

        duration = time.time() - start
        REQUEST_COUNT.labels(method="POST", endpoint="/book", status="success", service=SERVICE_NAME).inc()
        REQUEST_LATENCY.labels(endpoint="/book", service=SERVICE_NAME).observe(duration)

        logger.info("Booking request completed", extra={
            "trace_id": trace_id,
            "booking_id": result.get("booking_id"),
            "event_type": event_type,
            "duration_ms": round(duration * 1000, 2),
        })

        return JSONResponse(status_code=200, content={
            **result,
            "gateway_trace_id": trace_id,
        })

    except Exception as e:
        circuit_breaker.record_failure()
        DEPENDENCY_UP.labels(dependency="booking-service").set(0)
        duration = time.time() - start
        REQUEST_COUNT.labels(method="POST", endpoint="/book", status="error", service=SERVICE_NAME).inc()
        REQUEST_LATENCY.labels(endpoint="/book", service=SERVICE_NAME).observe(duration)

        logger.error("Booking request failed", extra={
            "trace_id": trace_id,
            "error": str(e),
            "duration_ms": round(duration * 1000, 2),
        })

        return JSONResponse(status_code=502, content={
            "error": "Booking service unavailable",
            "trace_id": trace_id,
        })

# ── Health endpoints ──────────────────────────────────────────────────────────
@app.get("/health/live")
def liveness():
    return JSONResponse(status_code=200, content= {"status": "alive", "service": SERVICE_NAME})

@app.get("/health/ready")
def readiness():
    global dependency_healthy
    if not dependency_healthy:
        return JSONResponse(status_code=503, content= {"status": "not_ready", "reason": "dependency_unavailable"})
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

@app.get("/health/dependency/break")
def break_dependency():
    global dependency_healthy
    dependency_healthy = False
    return {"status": "dependency marked down"}

@app.get("/health/dependency/restore")
def restore_dependency():
    global dependency_healthy
    dependency_healthy = True
    return {"status": "dependency restored"}

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type="text/plain")

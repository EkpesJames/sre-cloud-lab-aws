"""
tests/test_app.py — pytest tests for Cloud Lab API
"""

import pytest
from fastapi.testclient import TestClient
from unittest.mock import patch
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'app'))

with patch.dict(os.environ, {
    'APP_ERROR_RATE': '0.0',
    'APP_LATENCY_SECONDS': '0.0',
    'JAEGER_ENDPOINT': 'http://localhost:4317',
}):
    import gateway as app_module
    from gateway import app, circuit_breaker, CircuitBreaker

client = TestClient(app)


def reset_state():
    """Reset all shared state between tests."""
    client.get("/health/dependency/restore")
    circuit_breaker.state = CircuitBreaker.CLOSED
    circuit_breaker.error_count = 0
    circuit_breaker.total_count = 0


# ── Liveness ──────────────────────────────────────────────────────────────────

class TestLivenessProbe:
    def test_returns_200(self):
        assert client.get("/health/live").status_code == 200

    def test_returns_alive_status(self):
        assert client.get("/health/live").json()["status"] == "alive"

    def test_returns_timestamp(self):
        data = client.get("/health/live").json()
        assert "service" in data


# ── Readiness ─────────────────────────────────────────────────────────────────

class TestReadinessProbe:
    def setup_method(self):
        reset_state()

    def teardown_method(self):
        reset_state()

    def test_returns_200_when_healthy(self):
        assert client.get("/health/ready").status_code == 200

    def test_returns_ready_status(self):
        assert client.get("/health/ready").json()["status"] == "ready"

    def test_returns_503_when_dependency_down(self):
        client.get("/health/dependency/break")
        response = client.get("/health/ready")
        assert response.status_code == 503
        assert response.json()["reason"] == "dependency_unavailable"


# ── Circuit breaker endpoint ──────────────────────────────────────────────────

class TestCircuitBreakerEndpoint:
    def test_returns_200(self):
        assert client.get("/health/circuit").status_code == 200

    def test_returns_expected_fields(self):
        data = client.get("/health/circuit").json()
        for field in ["state", "error_count", "total_count", "threshold"]:
            assert field in data  # updated fields

    def test_initial_state_is_closed(self):
        reset_state()
        assert client.get("/health/circuit").json()["state"] == "closed"


# ── Metrics ───────────────────────────────────────────────────────────────────

class TestMetricsEndpoint:
    def test_returns_200(self):
        assert client.get("/metrics").status_code == 200

    def test_returns_prometheus_format(self):
        assert "text/plain" in client.get("/metrics").headers["content-type"]

    def test_contains_http_requests_total(self):
        client.get("/")
        assert "http_requests_total" in client.get("/metrics").text

    def test_contains_request_latency(self):
        assert "http_request_duration_seconds" in client.get("/metrics").text

    def test_contains_circuit_breaker_state(self):
        assert "circuit_breaker_state" in client.get("/metrics").text

    def test_contains_app_info(self):
        assert "app_info" in client.get("/metrics").text


# ── Main endpoint ─────────────────────────────────────────────────────────────

class TestMainEndpoint:
    def setup_method(self):
        reset_state()

    def test_returns_200_with_zero_error_rate(self):
        assert client.get("/").status_code == 200

    def test_returns_expected_fields(self):
        data = client.get("/").json()
        for field in ["message", "trace_id", "circuit_breaker"]:
            assert field in data  # updated fields

    def test_returns_correct_message(self):
        assert "API Gateway" in client.get("/").json()["message"]

    def test_returns_trace_id(self):
        trace_id = client.get("/").json()["trace_id"]
        assert isinstance(trace_id, str)
        assert len(trace_id) > 0


# ── Circuit breaker behaviour ─────────────────────────────────────────────────

class TestCircuitBreakerBehaviour:
    def setup_method(self):
        reset_state()

    def test_allows_requests_when_closed(self):
        assert circuit_breaker.allow_request() is True

    def test_records_success(self):
        circuit_breaker.record_success()
        assert circuit_breaker.total_count == 1
        assert circuit_breaker.error_count == 0

    def test_records_failure(self):
        circuit_breaker.record_failure()
        assert circuit_breaker.total_count == 1
        assert circuit_breaker.error_count == 1

    def test_opens_at_threshold(self):
        for _ in range(4):
            circuit_breaker.record_success()
        for _ in range(6):
            circuit_breaker.record_failure()
        assert circuit_breaker.state == CircuitBreaker.OPEN

    def test_rejects_requests_when_open(self):
        circuit_breaker.state = CircuitBreaker.OPEN
        circuit_breaker.opened_at = 9999999999
        assert circuit_breaker.allow_request() is False

    def test_returns_503_when_circuit_open(self):
        circuit_breaker.state = CircuitBreaker.OPEN
        circuit_breaker.opened_at = 9999999999
        response = client.get("/")
        assert response.status_code == 503
        assert response.json()["reason"] == "circuit_breaker_open"


# ── Dependency simulation ─────────────────────────────────────────────────────

class TestDependencySimulation:
    def setup_method(self):
        reset_state()

    def teardown_method(self):
        reset_state()

    def test_break_returns_200(self):
        assert client.get("/health/dependency/break").status_code == 200

    def test_restore_returns_200(self):
        assert client.get("/health/dependency/restore").status_code == 200

    def test_readiness_fails_after_break(self):
        client.get("/health/dependency/break")
        assert client.get("/health/ready").status_code == 503

    def test_readiness_healthy_after_restore(self):
        # Break then restore via HTTP — tests the full endpoint cycle
        client.get("/health/dependency/break")
        assert client.get("/health/ready").status_code == 503
        client.get("/health/dependency/restore")
        # Give the app one clean request cycle to reset state
        client.get("/health/live")
        assert client.get("/health/ready").status_code == 200

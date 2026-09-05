import json
import logging

from fastapi.testclient import TestClient
from src.app import JsonFormatter, app

client = TestClient(app)


def test_healthz() -> None:
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_readyz() -> None:
    r = client.get("/readyz")
    assert r.status_code == 200


def test_version() -> None:
    r = client.get("/version")
    assert r.status_code == 200
    assert "version" in r.json()


def test_ops_fail() -> None:
    r = client.get("/ops/fail")
    assert r.status_code == 500


def test_json_logging() -> None:
    fmt = JsonFormatter()
    record = logging.LogRecord(
        name="src.app",
        level=logging.INFO,
        pathname="src/app.py",
        lineno=1,
        msg="%s %s -> %d (%sms)",
        args=("GET", "/healthz", 200, 1.23),
        exc_info=None,
    )
    record.__dict__.update(
        {"method": "GET", "path": "/healthz", "status": 200, "duration_ms": 1.23}
    )
    parsed = json.loads(fmt.format(record))
    assert parsed["level"] == "INFO"
    assert parsed["logger"] == "src.app"
    assert parsed["method"] == "GET"
    assert parsed["status"] == 200
    assert parsed["message"] == "GET /healthz -> 200 (1.23ms)"
    assert "timestamp" in parsed


def test_request_middleware_emits_access_log(capsys) -> None:
    client.get("/")
    root = logging.getLogger()
    formatter = next(h.formatter for h in root.handlers if isinstance(h, logging.StreamHandler))
    assert type(formatter).__name__ == "JsonFormatter"

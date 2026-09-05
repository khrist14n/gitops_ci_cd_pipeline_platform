import json
import logging
import os
import sys
from datetime import datetime, UTC
from typing import Any

try:
    import newrelic.agent  # type: ignore

    NEWRELIC_AVAILABLE = True
except Exception:  # newrelic is an optional dependency for light deployments
    NEWRELIC_AVAILABLE = False

logger = logging.getLogger(__name__)

# Built-in LogRecord attributes cannot be re-used via `extra`; everything else
# that ends up on the record (method, path, status, ...) is treated as a field.
_LOG_RESERVED = set(logging.LogRecord("__root__", 0, "", 0, "", (), None).__dict__.keys())


class JsonFormatter(logging.Formatter):
    """Structured JSON logs on stdout; New Relic Logs + APM consume these."""

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": datetime.now(UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        for key, value in record.__dict__.items():
            if key not in _LOG_RESERVED and not key.startswith("newrelic_"):
                payload[key] = value
        if NEWRELIC_AVAILABLE:
            try:
                meta = newrelic.agent.linking_metadata()
                if meta:
                    payload["newrelic"] = meta
            except Exception:
                pass
        return json.dumps(payload)


class RequestLogMiddleware:
    """Log every request/response so traces and logs correlate in New Relic."""

    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        start = datetime.now(UTC)
        response_status = 0

        async def send_wrapper(message: dict[str, Any]) -> None:
            nonlocal response_status
            if message["type"] == "http.response.start":
                response_status = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            elapsed_ms = round((datetime.now(UTC) - start).total_seconds() * 1000, 2)
            record = logging.LogRecord(
                name=__name__,
                level=logging.WARNING if response_status >= 400 else logging.INFO,
                pathname=__file__,
                lineno=0,
                msg="%s %s -> %d (%sms)",
                args=(scope.get("method"), scope.get("path"), response_status, elapsed_ms),
                exc_info=None,
            )
            record.__dict__.update(
                {
                    "method": scope.get("method"),
                    "path": scope.get("path"),
                    "status": response_status,
                    "duration_ms": elapsed_ms,
                }
            )
            logger.handle(record)


def newrelic_stdout_handler() -> logging.Handler:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    return handler


def init_newrelic() -> None:
    """Initialize the New Relic Python agent from env (no-op without a license key).

    Ordering matters: this must run before fastapi/uvicorn are imported so the
    agent's import hooks can instrument them. Enabling/disabling is purely
    config (image stays generic), which is what makes it work with GitOps.
    """
    if not NEWRELIC_AVAILABLE:
        logger.warning("newrelic not installed; telemetry disabled")
        return
    if not os.environ.get("NEW_RELIC_LICENSE_KEY"):
        logger.info("NEW_RELIC_LICENSE_KEY not set; newrelic agent stays disabled")
        return
    try:
        newrelic.agent.initialize()
        logging.getLogger("newrelic").setLevel(logging.WARNING)
        logger.info("newrelic agent initialized: app=%s", os.environ.get("NEW_RELIC_APP_NAME"))
    except Exception:
        logger.exception("newrelic agent initialization failed; continuing without it")


def init_logging() -> None:
    root = logging.getLogger()
    root.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())
    # Own the root stdout handler so output is always our JSON format,
    # even if a framework (httpx/TestClient, uvicorn) added another one first.
    for handler in root.handlers[:]:
        if isinstance(handler, logging.StreamHandler):
            root.removeHandler(handler)
    root.addHandler(newrelic_stdout_handler())


init_newrelic()
init_logging()

import uvicorn  # noqa: E402  (must be imported after the agent is initialized)
from fastapi import FastAPI  # noqa: E402
from fastapi.responses import JSONResponse  # noqa: E402

VERSION = os.environ.get("APP_VERSION", "dev")

app = FastAPI(title="demo-app", version=VERSION)
app.add_middleware(RequestLogMiddleware)


@app.get("/")
def root() -> JSONResponse:
    return JSONResponse({"service": "demo-app", "version": VERSION})


@app.get("/healthz")
def healthz() -> JSONResponse:
    return JSONResponse({"status": "ok"})


@app.get("/readyz")
def readyz() -> JSONResponse:
    return JSONResponse({"status": "ready"})


@app.get("/version")
def version() -> JSONResponse:
    return JSONResponse({"version": VERSION})


@app.get("/ops/fail")
def fail() -> JSONResponse:
    return JSONResponse({"status": "krash"}, status_code=500)


if __name__ == "__main__":
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8080")),
        log_level=os.environ.get("LOG_LEVEL", "info").lower(),
    )

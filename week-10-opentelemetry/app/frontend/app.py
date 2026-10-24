"""The service a user actually calls. It does almost nothing itself.

It calls the backend over plain HTTP. The requests instrumentation injects the
W3C traceparent header on the way out and the backend's Flask instrumentation
reads it on the way in - which is the entire mechanism by which two separate
processes end up in ONE trace.
"""
import os
from flask import Flask, jsonify
import requests

from otel_setup import configure, otel_environment

app = Flask(__name__)
tracer = configure(app, "frontend")

BACKEND = os.environ.get("BACKEND_URL", "http://backend")


@app.get("/health")
def health():
    return jsonify(status="ok")


@app.get("/otel-config")
def otel_config():
    return jsonify(service="frontend", otel=otel_environment())


@app.get("/")
def index():
    with tracer.start_as_current_span("assemble-page") as span:
        r = requests.get("%s/api/items" % BACKEND, timeout=30)
        data = r.json()
        span.set_attribute("backend.status_code", r.status_code)
        span.set_attribute("items.count", len(data.get("items", [])))
    return jsonify(
        service="frontend",
        backend_said=data,
        trace_note="this response required two services; the trace should show both",
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)

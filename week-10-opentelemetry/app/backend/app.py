"""The downstream service. It does one slow thing, on purpose.

The whole point of a trace is to attribute time to a place. If both services
were instant there would be nothing to attribute, so this one sleeps for a
known, configurable interval - and the trace should show that interval sitting
in THIS service rather than in the caller.
"""
import os
import time
import random
from flask import Flask, jsonify

from otel_setup import configure, otel_environment

app = Flask(__name__)
# Configured here, at module import, which with gunicorn happens inside each
# forked worker. See otel_setup.py for why that matters.
tracer = configure(app, "backend")

WORK_MS = int(os.environ.get("WORK_MS", "250"))


@app.get("/health")
def health():
    return jsonify(status="ok")


@app.get("/otel-config")
def otel_config():
    """What the managed agent injected into this container, as seen from inside."""
    return jsonify(service="backend", otel=otel_environment())


@app.get("/api/items")
def items():
    # A child span, so the trace shows WHERE inside the backend the time went,
    # not merely that the backend was slow.
    with tracer.start_as_current_span("query-items") as span:
        span.set_attribute("work.sleep_ms", WORK_MS)
        time.sleep(WORK_MS / 1000.0)
        n = random.randint(3, 9)
        span.set_attribute("items.count", n)
    return jsonify(items=[{"id": i, "name": "item-%d" % i} for i in range(n)],
                   backend_work_ms=WORK_MS)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)

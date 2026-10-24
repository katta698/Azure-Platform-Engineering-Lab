"""OpenTelemetry wiring, in one place.

WHY THIS IS EXPLICIT RATHER THAN AUTOMATIC
------------------------------------------
There are two ways to instrument a Python service, and BOTH WORK HERE -
measured, not assumed:

  1. prefix the command with `opentelemetry-instrument`, which patches
     libraries and builds the exporter before handing control to the app
  2. do it in code, as below

This lab's first revision used (1) and exported traces correctly through
gunicorn's forked workers. It is the shorter path and there is nothing wrong
with it.

This file exists for (2) because the week is ABOUT tracing, and two decisions
deserve to be visible in the repository rather than implied by an environment
variable: which sampler is in use, and the fact that the exporter's endpoint
comes from the platform rather than from us. A reader following this post
should be able to see both without knowing what `opentelemetry-instrument`
does behind the scenes.

A note on gunicorn, since it is a real trap in other setups: the span
processor's export thread must live in the process that creates spans. With
gunicorn's default `preload_app = False` the application module is imported
inside each worker AFTER the fork, so calling configure() at module import
puts the exporter in the right process. If you ever switch on `--preload`,
move this into a `post_fork` hook.
"""
import os

from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.sampling import ParentBasedTraceIdRatio
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor


def otel_environment():
    """What the managed agent injected. Returned by /otel-config as evidence."""
    return {k: v for k, v in os.environ.items() if "OTEL" in k}


def configure(app, service_name):
    # parentbased means a sampling decision taken at the frontend is RESPECTED
    # by the backend. Without it the two services would sample independently,
    # and a trace could keep one half and drop the other - which is worse than
    # dropping the whole trace, because the half that survives looks complete.
    ratio = float(os.environ.get("OTEL_TRACES_SAMPLER_ARG", "1.0"))

    provider = TracerProvider(
        resource=Resource.create({"service.name": service_name}),
        sampler=ParentBasedTraceIdRatio(ratio),
    )
    # OTLPSpanExporter reads OTEL_EXPORTER_OTLP_ENDPOINT from the environment,
    # and the managed agent injects it - measured as
    # http://k8se-otel.k8se-apps.svc.cluster.local:4317. Setting it ourselves
    # would override the agent's address and send spans nowhere.
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)

    FlaskInstrumentor().instrument_app(app)
    RequestsInstrumentor().instrument()
    return trace.get_tracer(service_name)

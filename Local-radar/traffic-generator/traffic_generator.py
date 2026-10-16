import logging
import os
import signal
import time
import urllib.error
import urllib.request
from threading import Event

from opentelemetry import metrics
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.metrics.view import (
    ExplicitBucketHistogramAggregation,
    View,
)
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import SpanKind, Status, StatusCode


logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("local-radar-traffic-generator")

request_url = os.getenv(
    "REQUEST_URL",
    "http://nginx.default.svc.cluster.local/",
)
request_interval = float(os.getenv("REQUEST_INTERVAL_SECONDS", "1"))
request_timeout = float(os.getenv("REQUEST_TIMEOUT_SECONDS", "5"))
metrics_endpoint = os.getenv(
    "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
    "http://otel-collector.local-radar.svc.cluster.local:4318/v1/metrics",
)
traces_endpoint = os.getenv(
    "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
    "http://otel-collector.local-radar.svc.cluster.local:4318/v1/traces",
)

stop_event = Event()


def stop(_signum, _frame):
    stop_event.set()


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

resource = Resource.create(
    {
        "service.name": "local-radar-traffic-generator",
        "service.namespace": "local-radar",
    }
)

exporter = OTLPMetricExporter(endpoint=metrics_endpoint, timeout=5)
reader = PeriodicExportingMetricReader(
    exporter,
    export_interval_millis=5000,
)
meter_provider = MeterProvider(
    resource=resource,
    metric_readers=[reader],
    views=[
        View(
            instrument_name="local_radar.http.request.duration",
            aggregation=ExplicitBucketHistogramAggregation(
                boundaries=[
                    0.001,
                    0.0025,
                    0.005,
                    0.01,
                    0.025,
                    0.05,
                    0.1,
                    0.25,
                    0.5,
                    1,
                    2.5,
                    5,
                ]
            ),
        )
    ],
)
metrics.set_meter_provider(meter_provider)

tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(
    BatchSpanProcessor(
        OTLPSpanExporter(endpoint=traces_endpoint, timeout=5)
    )
)
trace.set_tracer_provider(tracer_provider)

meter = metrics.get_meter("local-radar.traffic-generator")
tracer = trace.get_tracer("local-radar.traffic-generator")
request_counter = meter.create_counter(
    "local_radar.http.requests",
    unit="{request}",
    description="HTTP requests attempted by the local traffic generator",
)
request_duration = meter.create_histogram(
    "local_radar.http.request.duration",
    unit="s",
    description="End-to-end HTTP request duration",
)


def send_request():
    start = time.perf_counter()
    status_code = "0"
    outcome = "transport_error"
    with tracer.start_as_current_span(
        "GET nginx",
        kind=SpanKind.CLIENT,
    ) as span:
        span.set_attribute("http.request.method", "GET")
        span.set_attribute("url.full", request_url)
        try:
            request = urllib.request.Request(
                request_url,
                headers={"User-Agent": "local-radar-otel-demo"},
            )
            with urllib.request.urlopen(request, timeout=request_timeout) as response:
                response.read()
                status_code = str(response.status)
                outcome = "success" if response.status < 400 else "http_error"
        except urllib.error.HTTPError as error:
            status_code = str(error.code)
            outcome = "http_error"
            span.record_exception(error)
            logger.warning("HTTP request returned status %s", status_code)
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            span.set_attribute("error.type", type(error).__name__)
            span.record_exception(error)
            logger.warning("HTTP request failed: %s", error)

        span.set_attribute("http.response.status_code", int(status_code))
        span.set_attribute("server.address", "nginx.default.svc.cluster.local")
        if outcome != "success":
            span.set_status(Status(StatusCode.ERROR, outcome))

    elapsed_seconds = time.perf_counter() - start
    attributes = {
        "target": "nginx",
        "http.request.method": "GET",
        "http.response.status_code": status_code,
        "outcome": outcome,
    }
    request_counter.add(1, attributes)
    request_duration.record(elapsed_seconds, attributes)
    logger.info(
        "GET %s status=%s outcome=%s duration_seconds=%.4f",
        request_url,
        status_code,
        outcome,
        elapsed_seconds,
    )


logger.info(
    "Starting requests to %s; exporting OTLP metrics to %s",
    request_url,
    metrics_endpoint,
)
try:
    while not stop_event.is_set():
        send_request()
        stop_event.wait(request_interval)
finally:
    meter_provider.force_flush()
    meter_provider.shutdown()
    tracer_provider.force_flush()
    tracer_provider.shutdown()

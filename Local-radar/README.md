# Local Radar HTTP telemetry

This setup adds request count, end-to-end latency metrics, and request traces
to the existing `radar-local` Minikube demo. It keeps Caretta/Radar for network
topology and uses the existing VictoriaMetrics and Grafana for application
metrics, with Tempo as a local trace store.

The Python traffic generator replaces the existing curl-only Deployment and
sends one GET per second to the Nginx Service. It records every attempt in an
OpenTelemetry counter and latency histogram, then exports OTLP/HTTP to an
OpenTelemetry Collector. VictoriaMetrics scrapes the Collector's Prometheus
endpoint. Each GET also creates an OpenTelemetry client span which the
Collector exports to Tempo.

## Deploy

Prerequisites: `podman`, `minikube`, and `kubectl`; the `radar-local` Minikube
profile and Caretta release must already be running.

From the repository root:

```powershell
.\Local-radar\deploy.ps1
```

The script builds an ARM64-compatible image on the current Podman machine,
loads it into Minikube, applies the Collector and generator, adds a scrape job
to the Caretta VictoriaMetrics configuration, and restarts VictoriaMetrics to
load that configuration.

## View the metrics

Forward Grafana in a separate PowerShell window:

```powershell
kubectl --context radar-local port-forward -n caretta svc/caretta-grafana 3000:80
```

Open <http://127.0.0.1:3000> and select **Dashboards** → **Local Radar -
End-to-End Request Traces** to inspect individual requests. Click a **Trace
ID** to open its span details. The trace list uses Tempo's native search query
for compatibility with the installed Grafana 9.3.1. The **Local Radar - HTTP
Latency and Request Count** dashboard remains available for request rate,
count, and p50/p95 latency. Trace rows should appear shortly after the first
spans are exported.

Each trace currently contains one client span around the GET to Nginx, so it
shows end-to-end duration and request attributes. The stock Nginx container is
not instrumented; the trace does not include a separate server span or a
breakdown of Nginx's internal processing time.

You can also use **Explore** with the `Prometheus` datasource and run:

```promql
# Requests in the last 5 minutes
sum(increase(local_radar_http_requests_total[5m]))

# Requests per second
sum(rate(local_radar_http_requests_total[1m]))

# 95th-percentile end-to-end request latency
histogram_quantile(
  0.95,
  sum by (le) (rate(local_radar_http_request_duration_seconds_bucket[5m]))
)

# Average end-to-end request latency
sum(rate(local_radar_http_request_duration_seconds_sum[5m]))
/
sum(rate(local_radar_http_request_duration_seconds_count[5m]))
```

Latency includes the client-to-Service network path and Nginx response time.
The request counter includes successful responses, HTTP errors, and transport
failures; the `outcome` label distinguishes them. Caretta's topology remains
useful for flow relationships, but its link counter is not an HTTP request
counter.

## Remove

From the repository root:

```powershell
.\Local-radar\remove.ps1
```

Removal restores the original curl-only generator, Grafana datasource, and
Caretta scrape configuration, then deletes the `local-radar` namespace. The
deploy script updates Helm-managed Grafana and Caretta ConfigMaps; a future
chart upgrade may replace these additions.

$ErrorActionPreference = 'Stop'

$context = 'radar-local'
$image = 'localhost/local-radar/traffic-generator:0.1.0'
$generatorPath = Join-Path $PSScriptRoot 'traffic-generator'
$manifestPath = Join-Path $PSScriptRoot 'k8s'
$grafanaPath = Join-Path $PSScriptRoot 'grafana'

foreach ($tool in @('podman', 'minikube', 'kubectl')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$tool' was not found in PATH."
    }
}

kubectl --context $context get nodes | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Kubernetes context '$context' is unavailable."
}

Push-Location $generatorPath
try {
    podman build --tag $image .
    if ($LASTEXITCODE -ne 0) {
        throw 'Building the traffic-generator image failed.'
    }
}
finally {
    Pop-Location
}

$archivePath = Join-Path $env:TEMP "local-radar-traffic-generator-$PID.tar"
try {
    podman save --format docker-archive --output $archivePath $image
    if ($LASTEXITCODE -ne 0) {
        throw "Exporting image '$image' from Podman failed."
    }

    minikube -p $context image load $archivePath --overwrite=true
    if ($LASTEXITCODE -ne 0) {
        throw "Loading image '$image' into Minikube failed."
    }
}
finally {
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
}

kubectl --context $context apply -f (Join-Path $manifestPath 'namespace.yaml')
if ($LASTEXITCODE -ne 0) {
    throw 'Creating the local-radar namespace failed.'
}

kubectl --context $context apply -f (Join-Path $manifestPath 'tempo.yaml')
if ($LASTEXITCODE -ne 0) {
    throw 'Applying Tempo resources failed.'
}

kubectl --context $context rollout status deployment/tempo -n local-radar --timeout=180s
if ($LASTEXITCODE -ne 0) {
    throw 'Tempo did not become ready.'
}

kubectl --context $context apply -f (Join-Path $manifestPath 'otel-collector.yaml')
if ($LASTEXITCODE -ne 0) {
    throw 'Applying the OpenTelemetry Collector resources failed.'
}

kubectl --context $context rollout restart deployment/otel-collector -n local-radar
if ($LASTEXITCODE -ne 0) {
    throw 'Restarting the OpenTelemetry Collector to load trace export failed.'
}

$existingContainers = kubectl --context $context get deployment traffic-generator -n default --ignore-not-found -o jsonpath='{.spec.template.spec.containers[*].name}'
if ($LASTEXITCODE -ne 0) {
    throw 'Checking the existing traffic-generator Deployment failed.'
}

if ($existingContainers -match '(^|\s)curl($|\s)') {
    kubectl --context $context delete deployment traffic-generator -n default --wait=true
    if ($LASTEXITCODE -ne 0) {
        throw 'Removing the old curl container from the traffic-generator Deployment failed.'
    }
}

kubectl --context $context apply -f (Join-Path $manifestPath 'traffic-generator.yaml')
if ($LASTEXITCODE -ne 0) {
    throw 'Applying the traffic-generator Deployment failed.'
}

kubectl --context $context apply -f (Join-Path $manifestPath 'victoria-metrics-scrape-config.yaml')
if ($LASTEXITCODE -ne 0) {
    throw 'Updating the VictoriaMetrics scrape configuration failed.'
}

kubectl --context $context rollout restart statefulset/caretta-vm -n caretta
if ($LASTEXITCODE -ne 0) {
    throw 'Restarting VictoriaMetrics to load the scrape configuration failed.'
}

kubectl --context $context rollout status deployment/otel-collector -n local-radar --timeout=180s
if ($LASTEXITCODE -ne 0) {
    throw 'The OpenTelemetry Collector did not become ready.'
}

kubectl --context $context rollout status deployment/tempo -n local-radar --timeout=180s
if ($LASTEXITCODE -ne 0) {
    throw 'Tempo did not become ready.'
}

kubectl --context $context rollout status deployment/traffic-generator -n default --timeout=180s
if ($LASTEXITCODE -ne 0) {
    throw 'The traffic generator did not become ready.'
}

kubectl --context $context rollout status statefulset/caretta-vm -n caretta --timeout=180s
if ($LASTEXITCODE -ne 0) {
    throw 'VictoriaMetrics did not become ready.'
}

$datasourcesYaml = Get-Content -LiteralPath (Join-Path $grafanaPath 'datasources.yaml') -Raw
$datasourcesPatch = @{
    data = @{
        'datasources.yaml' = $datasourcesYaml
    }
} | ConvertTo-Json -Compress -Depth 4

kubectl --context $context patch configmap caretta-grafana -n caretta --type=merge -p $datasourcesPatch
if ($LASTEXITCODE -ne 0) {
    throw 'Adding the Tempo datasource to Grafana provisioning failed.'
}

$latencyDashboardJson = Get-Content -LiteralPath (Join-Path $grafanaPath 'http-latency-dashboard.json') -Raw
$traceDashboardJson = Get-Content -LiteralPath (Join-Path $grafanaPath 'end-to-end-traces-dashboard.json') -Raw
$dashboardPatch = @{
    data = @{
        'local-radar-http-latency-dashboard.json' = $latencyDashboardJson
        'local-radar-e2e-traces-dashboard.json' = $traceDashboardJson
    }
} | ConvertTo-Json -Compress -Depth 4

kubectl --context $context patch configmap caretta-grafana-dashboards -n caretta --type=merge -p $dashboardPatch
if ($LASTEXITCODE -ne 0) {
    throw 'Adding the HTTP and trace dashboards to Grafana provisioning failed.'
}

kubectl --context $context rollout restart deployment/caretta-grafana -n caretta
if ($LASTEXITCODE -ne 0) {
    throw 'Restarting Grafana to load Tempo and trace dashboards failed.'
}

kubectl --context $context rollout status deployment/caretta-grafana -n caretta --timeout=180s
if ($LASTEXITCODE -ne 0) {
    throw 'Grafana did not become ready after trace provisioning.'
}

Write-Host 'Local HTTP telemetry is deployed.'
Write-Host 'Grafana: kubectl --context radar-local port-forward -n caretta svc/caretta-grafana 3000:80'
Write-Host 'Open the "Local Radar - End-to-End Request Traces" dashboard.'

$ErrorActionPreference = 'Stop'

$context = 'radar-local'
$manifestPath = Join-Path $PSScriptRoot 'k8s'
$restoreConfigPath = Join-Path $manifestPath 'victoria-metrics-scrape-config-restore.yaml'
$restoreGeneratorPath = Join-Path $manifestPath 'traffic-generator-restore.yaml'
$datasourcesRestorePath = Join-Path $PSScriptRoot 'grafana\datasources-restore.yaml'

$datasourcesYaml = Get-Content -LiteralPath $datasourcesRestorePath -Raw
$datasourcesPatch = @{
    data = @{
        'datasources.yaml' = $datasourcesYaml
    }
} | ConvertTo-Json -Compress -Depth 4

kubectl --context $context patch configmap caretta-grafana -n caretta --type=merge -p $datasourcesPatch
if ($LASTEXITCODE -ne 0) {
    throw 'Restoring the original Grafana datasource configuration failed.'
}

$dashboardPatch = '{"data":{"local-radar-http-latency-dashboard.json":null,"local-radar-e2e-traces-dashboard.json":null}}'
kubectl --context $context patch configmap caretta-grafana-dashboards -n caretta --type=merge -p $dashboardPatch
if ($LASTEXITCODE -ne 0) {
    throw 'Removing the local telemetry dashboards from Grafana provisioning failed.'
}

kubectl --context $context rollout restart deployment/caretta-grafana -n caretta
if ($LASTEXITCODE -ne 0) {
    throw 'Restarting Grafana after local telemetry cleanup failed.'
}

kubectl --context $context rollout status deployment/caretta-grafana -n caretta --timeout=180s
if ($LASTEXITCODE -ne 0) {
    throw 'Grafana did not become ready after local telemetry cleanup.'
}

kubectl --context $context delete deployment traffic-generator -n default --ignore-not-found=true --wait=true
if ($LASTEXITCODE -ne 0) {
    throw 'Removing the instrumented traffic-generator Deployment failed.'
}

kubectl --context $context apply -f $restoreGeneratorPath
if ($LASTEXITCODE -ne 0) {
    throw 'Restoring the original curl-only traffic generator failed.'
}

kubectl --context $context delete namespace local-radar --ignore-not-found=true
if ($LASTEXITCODE -ne 0) {
    throw 'Deleting the local-radar namespace failed.'
}

kubectl --context $context apply -f $restoreConfigPath
if ($LASTEXITCODE -ne 0) {
    throw 'Restoring the original VictoriaMetrics scrape configuration failed.'
}

kubectl --context $context rollout restart statefulset/caretta-vm -n caretta
if ($LASTEXITCODE -ne 0) {
    throw 'Restarting VictoriaMetrics after cleanup failed.'
}

kubectl --context $context rollout status statefulset/caretta-vm -n caretta --timeout=180s
if ($LASTEXITCODE -ne 0) {
    throw 'VictoriaMetrics did not become ready after cleanup.'
}

Write-Host 'Local HTTP telemetry resources have been removed.'

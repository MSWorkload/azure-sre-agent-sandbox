// =============================================================================
// Bicep Parameters File - SRE Agent Sandbox
// =============================================================================
// Deploy with: az deployment sub create --location eastus2 --template-file main.bicep
// =============================================================================

using 'main.bicep'

// Core parameters are passed by scripts/deploy.ps1 via --parameters

// Observability stack (Grafana + Prometheus)
param deployObservability = true

// Baseline alert rules
param deployAlerts = true

// Deploy Azure SRE Agent (programmatic deployment now supported)
param deploySreAgent = true

// Default action group for incident routing (add webhook at deploy time)
param deployActionGroup = true

// AKS Configuration - cost-optimized for demo (B2as_v2 burstable on-demand pools + D2as_v5 Spot pool)
param systemNodeVmSize = 'Standard_B2as_v2'
param userNodeVmSize = 'Standard_B2as_v2'
param systemNodeCount = 1
param userNodeCount = 1
param enableSpotNodePool = true
param spotNodeVmSize = 'Standard_D2as_v5'
param spotNodeMaxCount = 4

// Tags
param tags = {
  workload: 'sre-agent-demo'
  environment: 'sandbox'
  managedBy: 'bicep'
  purpose: 'demonstration'
  costCenter: 'demo-lab'
}

[CmdletBinding()]
param(
    [ValidateRange(1, 10)] [int]$RefreshSeconds = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runtimeDirectory = Join-Path $PSScriptRoot 'runtime'
$statusPath = Join-Path $runtimeDirectory 'status.json'
$healthPath = Join-Path $runtimeDirectory 'monitor-health.json'
$startMonitor = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts\start_monitor.ps1'

if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
    throw "Demo status is not present yet. Start .\examples\30-second-demo\run_demo.ps1 in Terminal 1 first."
}

Write-Host 'Starting independent monitor and waiting for one genuine health check...'
& $startMonitor -StatusPath $statusPath -HealthPath $healthPath -RefreshSeconds $RefreshSeconds -VerifyHealth
Write-Host 'Health check passed. A coding agent can stop polling; the monitor remains available for the human.'

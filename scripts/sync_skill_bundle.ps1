[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$bundleRoot = Join-Path $repositoryRoot 'skills\agent-long-task-monitor'
$bundleScripts = Join-Path $bundleRoot 'scripts'
$bundleReferences = Join-Path $bundleRoot 'references'
$runtimeScripts = @('watch_long_task.ps1', 'start_monitor.ps1', 'test_monitor_health.ps1', 'example_supervisor.ps1', 'progress_protocol.py', 'progress_publisher.py', 'progress_consumer.py', 'progress_identity.py', 'progress_bridge.py', 'progress_layer.ps1', 'progress_emit.py', 'example_progress.ps1', 'demo_progress.py')
$referenceDocuments = @('STATUS_PROTOCOL.md', 'INTEGRATION.md', 'ARCHITECTURE.md', 'DESIGN_PRINCIPLES.md', 'APPLICATION_PROGRESS_PROTOCOL.md')

New-Item -ItemType Directory -Force -Path $bundleScripts, $bundleReferences | Out-Null
foreach ($name in $runtimeScripts) {
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "scripts\$name") -Destination (Join-Path $bundleScripts $name) -Force
}
foreach ($name in $referenceDocuments) {
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "docs\$name") -Destination (Join-Path $bundleReferences $name) -Force
}
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LICENSE') -Destination (Join-Path $bundleRoot 'LICENSE.txt') -Force
$bundleDemo = Join-Path $bundleRoot 'examples/application-progress'
New-Item -ItemType Directory -Force -Path $bundleDemo | Out-Null
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'examples/application-progress/README.md') -Destination (Join-Path $bundleDemo 'README.md') -Force

Write-Host "Synchronized Agent Skill runtime and references into $bundleRoot"

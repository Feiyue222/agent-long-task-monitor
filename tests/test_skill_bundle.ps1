[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$bundleRoot = Join-Path $repositoryRoot 'skills\agent-long-task-monitor'
$count = 0

function Assert-Contract {
    param([Parameter(Mandatory = $true)] [bool]$Condition, [Parameter(Mandatory = $true)] [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:count++
    "PASS: $Name"
}

function Same-Hash {
    param([Parameter(Mandatory = $true)] [string]$Left, [Parameter(Mandatory = $true)] [string]$Right)
    (Get-FileHash -LiteralPath $Left -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $Right -Algorithm SHA256).Hash
}

$runtimeScripts = @('watch_long_task.ps1', 'start_monitor.ps1', 'test_monitor_health.ps1', 'example_supervisor.ps1')
$referenceDocuments = @('STATUS_PROTOCOL.md', 'INTEGRATION.md', 'ARCHITECTURE.md', 'DESIGN_PRINCIPLES.md')

foreach ($name in $runtimeScripts) {
    Assert-Contract (Same-Hash (Join-Path $repositoryRoot "scripts\$name") (Join-Path $bundleRoot "scripts\$name")) "packaged runtime matches $name"
}
foreach ($name in $referenceDocuments) {
    Assert-Contract (Same-Hash (Join-Path $repositoryRoot "docs\$name") (Join-Path $bundleRoot "references\$name")) "packaged reference matches $name"
}
Assert-Contract (Same-Hash (Join-Path $repositoryRoot 'LICENSE') (Join-Path $bundleRoot 'LICENSE.txt')) 'packaged MIT license matches project license'

$canonicalSkill = Get-Content -LiteralPath (Join-Path $bundleRoot 'SKILL.md') -Raw
Assert-Contract ($canonicalSkill -match '(?s)^---.*?name:\s*agent-long-task-monitor' -and $canonicalSkill -match 'license:\s*MIT') 'canonical skill frontmatter present'
Assert-Contract ($canonicalSkill -notmatch '(?m)^\.\./|F:\\小监控|\.\./\.\.') 'canonical skill has no repository-layout coupling'
Assert-Contract (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot 'SKILL.md'))) 'root SKILL.md absent to prevent duplicate discovery'

$bundleText = (Get-ChildItem -LiteralPath $bundleRoot -Recurse -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
Assert-Contract ($bundleText -notmatch 'F:\\小监控|\.\./\.\.') 'installed bundle has no source repository path dependency'
"Bundle sync tests passed: $count"

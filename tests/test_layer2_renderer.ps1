[CmdletBinding()]
param([string]$PythonExecutable = 'python.exe')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $PSScriptRoot ('.runtime-renderer-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$count = 0
function Assert-Check { param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:count++; Write-Output "PASS: $Name"
}
function Observe { param([string]$ProgressFile)
    $parameters = @{StatusPath=$statusPath;HealthPath=$healthPath;Once=$true;PassThru=$true}
    if ($ProgressFile) { $parameters.ProgressPath=$ProgressFile; $parameters.ProgressPythonExecutable=$PythonExecutable }
    $all = & (Join-Path $root 'scripts/watch_long_task.ps1') @parameters 6>&1
    $result = $all | Where-Object { $null -ne $_.PSObject.Properties['health_path'] } | Select-Object -Last 1
    return [pscustomobject]@{Object=$result;Text=($all | Out-String)}
}
try {
    $statusPath = Join-Path $run 'status.json'
    $healthPath = Join-Path $run 'health.json'
    $progressPath = Join-Path $run 'progress.json'
    $status = @{contract_version='agent-long-task-status-v1';task='renderer';stage='PROCESS';state='RUNNING';processed=$null;total=$null;unit=$null;target_process_id=$null;supervisor_process_id=$null;artifact_validated=$false}
    [IO.File]::WriteAllText($statusPath, ($status | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $originalStatus = (Get-FileHash $statusPath).Hash
    $legacy = Observe ''
    Assert-Check ($legacy.Text -match 'Layer 2: NOT_AVAILABLE') 'Layer 1 only has optional absence'
    Assert-Check ($null -eq $legacy.Object.PSObject.Properties['application_progress']) 'legacy PassThru shape unchanged'
    $missing = Observe $progressPath
    Assert-Check ($missing.Object.application_progress.availability -eq 'NOT_AVAILABLE') 'missing Layer 2 does not fail Layer 1'
    Assert-Check (Test-Path $healthPath) 'Layer 1 heartbeat exists without progress'
    & (Join-Path $root 'scripts/example_progress.ps1') -ProgressPath $progressPath -PythonExecutable $PythonExecutable -StepSeconds .05
    $progress = Get-Content $progressPath -Raw | ConvertFrom-Json
    Assert-Check ($progress.protocol_version -eq 'agent-long-task-progress-v1' -and $progress.terminal_state -eq 'SUCCEEDED') 'PowerShell emitter produces terminal protocol'
    Assert-Check ($progress.application_creation_identity.value -is [string]) 'PowerShell FILETIME is an exact string'
    $originalProgress = (Get-FileHash $progressPath).Hash
    $both = Observe $progressPath
    Assert-Check ($both.Text -match 'Layer 1 -' -and $both.Text -match 'Layer 2 -') 'renderer separates both layers'
    Assert-Check ($both.Object.application_progress.snapshot.completed_units -eq 3) 'renderer reads explicit application counters'
    Assert-Check ($both.Object.application_progress.percent -eq 1) 'scope percent is exact independently of Layer 1'
    Assert-Check ($both.Object.application_progress.freshness -eq 'UNKNOWN') 'renderer restart does not fake heartbeat freshness'
    Assert-Check (-not $both.Object.status.artifact_validated) 'application terminal does not validate Layer 1 artifact'
    Assert-Check ((Get-FileHash $progressPath).Hash -eq $originalProgress) 'renderer leaves application snapshot unchanged'
    Assert-Check ((Get-FileHash $statusPath).Hash -eq $originalStatus) 'renderer leaves Layer 1 status unchanged'
    [IO.File]::WriteAllText($progressPath, '{')
    $invalid = Observe $progressPath
    Assert-Check ($invalid.Object.application_progress.freshness -eq 'CONTROL_FAILURE') 'malformed Layer 2 fails closed'
    Assert-Check ($invalid.Object.status.state -eq 'RUNNING' -and (Test-Path $healthPath)) 'Layer 2 failure leaves Layer 1 running and heartbeating'
    $sameBefore = (Get-FileHash $progressPath).Hash
    # Use a separate host: the collision path intentionally exits its script.
    $hostPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $ErrorActionPreference = 'Continue'
    & $hostPath -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts/watch_long_task.ps1') -StatusPath $statusPath -HealthPath $progressPath -ProgressPath $progressPath -Once *> (Join-Path $run 'collision.log')
    $ErrorActionPreference = 'Stop'
    Assert-Check ($LASTEXITCODE -ne 0 -and (Get-FileHash $progressPath).Hash -eq $sameBefore) 'health/progress collision rejected without write'
    "Layer 2 renderer tests passed: $count"
}
finally {
    $resolved = [IO.Path]::GetFullPath($run)
    $contained = [IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($contained, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test cleanup outside containment' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

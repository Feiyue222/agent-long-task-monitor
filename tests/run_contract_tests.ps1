[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$ScriptsPath = Join-Path $RepositoryRoot 'scripts'
$MonitorPath = Join-Path $ScriptsPath 'watch_long_task.ps1'
$LauncherPath = Join-Path $ScriptsPath 'start_monitor.ps1'
$HealthCheckPath = Join-Path $ScriptsPath 'test_monitor_health.ps1'
$SupervisorPath = Join-Path $ScriptsPath 'example_supervisor.ps1'
$FixturePath = Join-Path $PSScriptRoot 'fixtures'
$PassCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:PassCount++
    Write-Output "PASS: $Name"
}

function Get-FileText { param([string]$Path) return [System.IO.File]::ReadAllText($Path) }
function Invoke-MonitorOnce {
    param([string]$StatusFile, [string]$HealthFile)
    return & $MonitorPath -StatusPath $StatusFile -HealthPath $HealthFile -Once -PassThru 6>$null
}

$RuntimePath = Join-Path $FixturePath '.contract-runtime'
if (Test-Path -LiteralPath $RuntimePath) { Remove-Item -LiteralPath $RuntimePath -Recurse -Force }
New-Item -ItemType Directory -Path $RuntimePath -Force | Out-Null

try {
    $AllScriptFiles = Get-ChildItem -LiteralPath $ScriptsPath -Filter '*.ps1' -File
    foreach ($ScriptFile in $AllScriptFiles) {
        $Tokens = $null; $ParseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($ScriptFile.FullName, [ref]$Tokens, [ref]$ParseErrors)
        Assert-True ($ParseErrors.Count -eq 0) ("PowerShell parses " + $ScriptFile.Name)
    }

    $MonitorText = Get-FileText $MonitorPath
    $LauncherText = Get-FileText $LauncherPath
    $HealthText = Get-FileText $HealthCheckPath
    $SupervisorText = Get-FileText $SupervisorPath
    $AllScriptText = ($AllScriptFiles | ForEach-Object { Get-FileText $_.FullName }) -join "`n"

    Assert-True (-not [regex]::IsMatch($MonitorText, '(?im)\bStop-Process\b')) 'monitor contains no Stop-Process'
    Assert-True (-not [regex]::IsMatch($MonitorText, '(?im)\bStart-Process\b')) 'monitor contains no target Start-Process'
    Assert-True ($MonitorText -match 'Get-Content -LiteralPath \$Path -Raw') 'monitor reads authoritative status'
    Assert-True (-not [regex]::IsMatch($AllScriptText, '(?im)^\s*\$(?:pid)\s*=')) 'no script-owned automatic PID variable'
    Assert-True (-not [regex]::IsMatch($AllScriptText, '(?im)Write-Host\s*\(\s*if\b')) 'no invalid Write-Host if expression'
    Assert-True ($LauncherText -notmatch '(?i)-NoExit') 'launcher does not rely on NoExit'
    Assert-True ($MonitorText -match 'Read-Host ''Monitoring finished\. Press Enter to close this window\.''') 'terminal persistence uses Read-Host'
    Assert-True (($MonitorText -match 'contract_version = ''agent-long-task-monitor-health-v1''') -and ($MonitorText -match 'refresh_count') -and ($MonitorText -match 'observed_target_process_id') -and ($MonitorText -match 'observed_supervisor_process_id')) 'heartbeat contract fields exist'
    Assert-True (($MonitorText -match 'TemporaryHealthPath') -and ($MonitorText -match 'Move-Item -LiteralPath \$TemporaryHealthPath')) 'heartbeat is written atomically'
    Assert-True ($MonitorText -match '\$ProcessedValue / \$TotalValue') 'exact-progress percentage is counter-derived'
    Assert-True ($MonitorText -match '\$Delta -gt 0' -and $MonitorText -match '\$Rate = \$Delta / \$ElapsedSeconds') 'rate requires positive counter movement'
    Assert-True ($MonitorText -match '\$Rate -gt 0 -and \$ProcessedValue -lt \$TotalValue') 'ETA only appears when defensible'
    Assert-True ($MonitorText -match 'exact progress \{0\}') 'no-progress display is explicit'
    Assert-True ($MonitorText -match '\$State -eq ''COMPLETED'' -and \$ArtifactValidated') 'true 100 percent requires completion and validated artifact'
    Assert-True ($MonitorText -match 'not running \(not success evidence\)') 'process disappearance is not success'
    Assert-True ($HealthText -match 'Start-Sleep -Seconds \$RefreshSeconds') 'health check waits at least one refresh interval'
    Assert-True (($MonitorText -match 'if \(\$EnableGpu\)') -and ($MonitorText -match "Get-Command 'nvidia-smi\.exe'")) 'GPU query is optional'
    Assert-True ($SupervisorText -match 'Start-Process .* -PassThru') 'supervisor owns a Process object'
    Assert-True ($SupervisorText -match '\$TargetProcess\.WaitForExit\(\)') 'supervisor waits for child exit'
    Assert-True ($SupervisorText -match '\$NativeExitCode = \$TargetProcess\.ExitCode') 'supervisor captures native exit code'

    $ExactHealth = Join-Path $RuntimePath 'exact.health.json'
    $Exact = Invoke-MonitorOnce -StatusFile (Join-Path $FixturePath 'exact-running.json') -HealthFile $ExactHealth
    Assert-True ($Exact.progress.Exact -and [math]::Abs($Exact.progress.Percent - 50) -lt 0.001) 'exact progress produces correct percentage'
    Assert-True ($null -eq $Exact.progress.Rate -and $null -eq $Exact.progress.EtaSeconds) 'first exact sample does not invent rate or ETA'

    $NoProgressHealth = Join-Path $RuntimePath 'no-progress.health.json'
    $NoProgress = Invoke-MonitorOnce -StatusFile (Join-Path $FixturePath 'no-progress-running.json') -HealthFile $NoProgressHealth
    Assert-True ((-not $NoProgress.progress.Exact) -and $NoProgress.progress.Availability -eq 'unavailable') 'structurally unavailable progress remains unavailable'

    $FinalizationHealth = Join-Path $RuntimePath 'finalization.health.json'
    $Finalization = Invoke-MonitorOnce -StatusFile (Join-Path $FixturePath 'finalization-pending.json') -HealthFile $FinalizationHealth
    Assert-True ([math]::Abs($Finalization.progress.Percent - 99.99) -lt 0.001) 'unvalidated finalization is capped at 99.99 percent'

    $HealthStatusPath = Join-Path $FixturePath 'no-progress-running.json'
    $HealthFile = Join-Path $RuntimePath 'health.json'
    $CurrentProcessId = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $Now = [datetimeoffset]::Now
    $HealthyHeartbeat = [ordered]@{ contract_version = 'agent-long-task-monitor-health-v1'; monitor_process_id = $CurrentProcessId; refresh_count = 1; last_refresh_at = $Now.ToString('O'); observed_state = 'RUNNING'; observed_target_process_id = 101; observed_supervisor_process_id = 202; observed_processed = $null; observed_total = $null }
    [System.IO.File]::WriteAllText($HealthFile, ($HealthyHeartbeat | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    $HostExecutable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    & $HostExecutable -NoProfile -File $HealthCheckPath -StatusPath $HealthStatusPath -HealthPath $HealthFile -MonitorProcessId $CurrentProcessId -MonitorLaunchTime $Now.AddSeconds(-1).ToString('O') -ExpectedTargetProcessId 999 -ExpectedSupervisorProcessId 202 -SkipWait | Out-Null
    Assert-True ($LASTEXITCODE -eq 1) 'target PID mismatch is rejected'

    $HealthyHeartbeat.observed_target_process_id = 101
    $HealthyHeartbeat.observed_supervisor_process_id = 202
    $HealthyHeartbeat.last_refresh_at = $Now.AddMinutes(-10).ToString('O')
    [System.IO.File]::WriteAllText($HealthFile, ($HealthyHeartbeat | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    & $HostExecutable -NoProfile -File $HealthCheckPath -StatusPath $HealthStatusPath -HealthPath $HealthFile -MonitorProcessId $CurrentProcessId -MonitorLaunchTime $Now.ToString('O') -ExpectedTargetProcessId 101 -ExpectedSupervisorProcessId 202 -SkipWait | Out-Null
    Assert-True ($LASTEXITCODE -eq 1) 'stale heartbeat is rejected'

    $HealthyHeartbeat.last_refresh_at = [datetimeoffset]::Now.ToString('O')
    $HealthyHeartbeat.observed_supervisor_process_id = 303
    [System.IO.File]::WriteAllText($HealthFile, ($HealthyHeartbeat | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    & $HostExecutable -NoProfile -File $HealthCheckPath -StatusPath $HealthStatusPath -HealthPath $HealthFile -MonitorProcessId $CurrentProcessId -MonitorLaunchTime $Now.AddSeconds(-1).ToString('O') -ExpectedTargetProcessId 101 -ExpectedSupervisorProcessId 202 -SkipWait | Out-Null
    Assert-True ($LASTEXITCODE -eq 1) 'supervisor PID mismatch is rejected'

    $HealthyHeartbeat.observed_supervisor_process_id = 202
    $HealthyHeartbeat.last_refresh_at = [datetimeoffset]::Now.ToString('O')
    [System.IO.File]::WriteAllText($HealthFile, ($HealthyHeartbeat | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    & $HostExecutable -NoProfile -File $HealthCheckPath -StatusPath $HealthStatusPath -HealthPath $HealthFile -MonitorProcessId $CurrentProcessId -MonitorLaunchTime $Now.AddSeconds(-1).ToString('O') -ExpectedTargetProcessId 101 -ExpectedSupervisorProcessId 202 -SkipWait | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'matching fresh heartbeat passes health validation'

    Write-Output "Contract tests passed: $PassCount"
}
finally {
    if (Test-Path -LiteralPath $RuntimePath) { Remove-Item -LiteralPath $RuntimePath -Recurse -Force }
}

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$StatusPath,
    [Parameter(Mandatory = $true)] [string]$HealthPath,
    [Parameter(Mandatory = $true)] [int]$MonitorProcessId,
    [Parameter(Mandatory = $true)] [datetimeoffset]$MonitorLaunchTime,
    [object]$ExpectedTargetProcessId,
    [object]$ExpectedSupervisorProcessId,
    [ValidateRange(5, 3600)] [int]$RefreshSeconds = 10,
    [switch]$SkipWait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JsonValue { param([object]$Object, [string]$Name) if ($null -ne $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }; return $null }
function Add-HealthFailure { param([System.Collections.Generic.List[string]]$Failures, [string]$Message) [void]$Failures.Add($Message) }

if (-not $SkipWait) { Start-Sleep -Seconds $RefreshSeconds }
$Failures = New-Object 'System.Collections.Generic.List[string]'
try { $Monitor = Get-Process -Id $MonitorProcessId -ErrorAction Stop } catch { Add-HealthFailure $Failures 'monitor process is not alive' }
$Health = $null
if (-not (Test-Path -LiteralPath $HealthPath -PathType Leaf)) {
    Add-HealthFailure $Failures 'heartbeat file is missing'
}
else {
    try { $Health = Get-Content -LiteralPath $HealthPath -Raw | ConvertFrom-Json } catch { Add-HealthFailure $Failures 'heartbeat is unreadable' }
}
if ($null -ne $Health) {
    try { $HeartbeatTime = [datetimeoffset](Get-JsonValue $Health 'last_refresh_at') } catch { $HeartbeatTime = [datetimeoffset]::MinValue }
    if ($HeartbeatTime -lt $MonitorLaunchTime) { Add-HealthFailure $Failures 'heartbeat is stale (predates monitor launch)' }
    if ([int](Get-JsonValue $Health 'refresh_count') -lt 1) { Add-HealthFailure $Failures 'heartbeat refresh_count is below one' }
    if ($null -ne $ExpectedTargetProcessId -and [string](Get-JsonValue $Health 'observed_target_process_id') -ne [string]$ExpectedTargetProcessId) { Add-HealthFailure $Failures 'observed target PID does not match expected target PID' }
    if ($null -ne $ExpectedSupervisorProcessId -and [string](Get-JsonValue $Health 'observed_supervisor_process_id') -ne [string]$ExpectedSupervisorProcessId) { Add-HealthFailure $Failures 'observed supervisor PID does not match expected supervisor PID' }
}
try {
    $Status = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
    if ($Status.contract_version -ne 'agent-long-task-status-v1') { Add-HealthFailure $Failures 'authoritative status contract is invalid' }
}
catch { Add-HealthFailure $Failures 'authoritative status is unreadable' }

$Result = [pscustomobject]@{ healthy = ($Failures.Count -eq 0); monitor_process_id = $MonitorProcessId; failures = @($Failures); checked_at = [datetimeoffset]::Now.ToString('O') }
$Result
if (-not $Result.healthy) { exit 1 }

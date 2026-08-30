[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$StatusPath,
    [Parameter(Mandatory = $true)] [string]$HealthPath,
    [Parameter(Mandatory = $true)] [int]$MonitorProcessId,
    [Parameter(Mandatory = $true)] [datetimeoffset]$MonitorLaunchTime,
    [object]$ExpectedTargetProcessId,
    [object]$ExpectedSupervisorProcessId,
    [ValidateRange(1, 3600)] [int]$RefreshSeconds = 10
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-JsonValue { param([object]$Object, [string]$Name) if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }; return $null }
function Add-HealthFailure { param([System.Collections.Generic.List[string]]$Failures, [string]$Message) [void]$Failures.Add($Message) }
function Read-JsonSafely { param([string]$Path) Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }

$HealthCheckStartedAt = [datetimeoffset]::Now
$InitialHeartbeat = $null
if (Test-Path -LiteralPath $HealthPath -PathType Leaf) { try { $InitialHeartbeat = Read-JsonSafely $HealthPath } catch { $InitialHeartbeat = $null } }
Start-Sleep -Seconds $RefreshSeconds
$CheckedAt = [datetimeoffset]::Now
$MaxHeartbeatAgeSeconds = [math]::Max(15, (2 * $RefreshSeconds) + 5)
$Failures = New-Object 'System.Collections.Generic.List[string]'
try { Get-Process -Id $MonitorProcessId -ErrorAction Stop | Out-Null } catch { Add-HealthFailure $Failures 'monitor process is not alive' }
$Health = $null
if (-not (Test-Path -LiteralPath $HealthPath -PathType Leaf)) { Add-HealthFailure $Failures 'heartbeat file is missing' } else { try { $Health = Read-JsonSafely $HealthPath } catch { Add-HealthFailure $Failures 'heartbeat is unreadable' } }
if ($null -ne $Health) {
    if ((Get-JsonValue $Health 'contract_version') -ne 'agent-long-task-monitor-health-v1') { Add-HealthFailure $Failures 'heartbeat contract is invalid' }
    if ([string](Get-JsonValue $Health 'monitor_process_id') -ne [string]$MonitorProcessId) { Add-HealthFailure $Failures 'heartbeat monitor_process_id does not match monitor process' }
    if ([int](Get-JsonValue $Health 'refresh_count') -lt 1) { Add-HealthFailure $Failures 'heartbeat refresh_count is below one' }
    try { $HeartbeatTime = [datetimeoffset](Get-JsonValue $Health 'last_refresh_at') } catch { $HeartbeatTime = [datetimeoffset]::MinValue; Add-HealthFailure $Failures 'heartbeat timestamp is invalid' }
    if ($HeartbeatTime -lt $HealthCheckStartedAt) { Add-HealthFailure $Failures 'heartbeat predates this health check' }
    if (($CheckedAt - $HeartbeatTime).TotalSeconds -gt $MaxHeartbeatAgeSeconds) { Add-HealthFailure $Failures 'heartbeat exceeds maximum age' }
    if (($HeartbeatTime - $CheckedAt).TotalSeconds -gt 5) { Add-HealthFailure $Failures 'heartbeat timestamp is implausibly in the future' }
    if ($null -ne $InitialHeartbeat -and [string](Get-JsonValue $InitialHeartbeat 'monitor_process_id') -eq [string]$MonitorProcessId) {
        $AdvancedCount = [int](Get-JsonValue $Health 'refresh_count') -gt [int](Get-JsonValue $InitialHeartbeat 'refresh_count')
        $AdvancedTime = $HeartbeatTime -gt [datetimeoffset](Get-JsonValue $InitialHeartbeat 'last_refresh_at')
        if (-not ($AdvancedCount -or $AdvancedTime)) { Add-HealthFailure $Failures 'heartbeat did not advance after health-check start' }
    }
}
try {
    $Status = Read-JsonSafely $StatusPath
    if ($Status.contract_version -ne 'agent-long-task-status-v1') { Add-HealthFailure $Failures 'authoritative status contract is invalid' }
    $StatusTargetProcessId = Get-JsonValue $Status 'target_process_id'; $StatusSupervisorProcessId = Get-JsonValue $Status 'supervisor_process_id'
    if ($null -ne $Health -and [string](Get-JsonValue $Health 'observed_target_process_id') -ne [string]$StatusTargetProcessId) { Add-HealthFailure $Failures 'observed target PID does not match authoritative status' }
    if ($null -ne $Health -and [string](Get-JsonValue $Health 'observed_supervisor_process_id') -ne [string]$StatusSupervisorProcessId) { Add-HealthFailure $Failures 'observed supervisor PID does not match authoritative status' }
    if ($null -ne $ExpectedTargetProcessId -and [string]$ExpectedTargetProcessId -ne [string]$StatusTargetProcessId) { Add-HealthFailure $Failures 'expected target PID does not match authoritative status' }
    if ($null -ne $ExpectedSupervisorProcessId -and [string]$ExpectedSupervisorProcessId -ne [string]$StatusSupervisorProcessId) { Add-HealthFailure $Failures 'expected supervisor PID does not match authoritative status' }
} catch { Add-HealthFailure $Failures 'authoritative status is unreadable' }
$Result = [pscustomobject]@{ healthy = ($Failures.Count -eq 0); monitor_process_id = $MonitorProcessId; max_heartbeat_age_seconds = $MaxHeartbeatAgeSeconds; failures = @($Failures); checked_at = $CheckedAt.ToString('O') }
$Result
if (-not $Result.healthy) { exit 1 }

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$StatusPath,
    [string]$HealthPath,
    [ValidateRange(5, 3600)] [int]$RefreshSeconds = 10,
    [switch]$EnableGpu,
    [switch]$VerifyHealth,
    [object]$ExpectedTargetProcessId,
    [object]$ExpectedSupervisorProcessId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($HealthPath)) { $HealthPath = Join-Path (Split-Path -Parent $StatusPath) 'monitor-health.json' }
$MonitorScriptPath = Join-Path $PSScriptRoot 'watch_long_task.ps1'
$HealthCheckScriptPath = Join-Path $PSScriptRoot 'test_monitor_health.ps1'
$MonitorLaunchTime = [datetimeoffset]::Now
$HostExecutable = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
$MonitorArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MonitorScriptPath, '-StatusPath', $StatusPath, '-HealthPath', $HealthPath, '-RefreshSeconds', $RefreshSeconds)
if ($EnableGpu) { $MonitorArguments += '-EnableGpu' }
$MonitorProcess = Start-Process -FilePath $HostExecutable -ArgumentList $MonitorArguments -PassThru

if ($VerifyHealth) {
    if ($null -eq $ExpectedTargetProcessId -or $null -eq $ExpectedSupervisorProcessId) {
        $InitialStatus = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
        if ($null -eq $ExpectedTargetProcessId -and $null -ne $InitialStatus.target_process_id) { $ExpectedTargetProcessId = [int]$InitialStatus.target_process_id }
        if ($null -eq $ExpectedSupervisorProcessId -and $null -ne $InitialStatus.supervisor_process_id) { $ExpectedSupervisorProcessId = [int]$InitialStatus.supervisor_process_id }
    }
    $HealthArguments = @{ StatusPath = $StatusPath; HealthPath = $HealthPath; MonitorProcessId = $MonitorProcess.Id; MonitorLaunchTime = $MonitorLaunchTime; RefreshSeconds = $RefreshSeconds }
    if ($null -ne $ExpectedTargetProcessId) { $HealthArguments.ExpectedTargetProcessId = $ExpectedTargetProcessId }
    if ($null -ne $ExpectedSupervisorProcessId) { $HealthArguments.ExpectedSupervisorProcessId = $ExpectedSupervisorProcessId }
    $HealthResult = & $HealthCheckScriptPath @HealthArguments
    [pscustomobject]@{ monitor_process_id = $MonitorProcess.Id; health = $HealthResult }
}
else {
    [pscustomobject]@{ monitor_process_id = $MonitorProcess.Id; health = 'not checked' }
}

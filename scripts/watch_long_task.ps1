[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StatusPath,

    [string]$HealthPath,

    [ValidateRange(5, 3600)]
    [int]$RefreshSeconds = 10,

    [switch]$EnableGpu,

    # Intended for diagnostics and automated examples. It performs one read and
    # writes one health record without entering the interactive loop.
    [switch]$Once,

    # Emits the computed observation for offline tests and diagnostics.
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CurrentProcessId {
    return [System.Diagnostics.Process]::GetCurrentProcess().Id
}

function Get-PropertyValue {
    param([object]$Object, [string]$Name)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $null
}

function Read-AuthoritativeStatus {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Authoritative status file is missing: $Path"
    }

    $Status = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ((Get-PropertyValue -Object $Status -Name 'contract_version') -ne 'agent-long-task-status-v1') {
        throw 'Authoritative status has an unsupported or missing contract_version.'
    }

    $AllowedStates = @('RUNNING', 'COMPLETED', 'FAILED', 'BLOCKED', 'INTERRUPTED', 'PAUSED')
    $State = [string](Get-PropertyValue -Object $Status -Name 'state')
    if ($AllowedStates -notcontains $State) {
        throw "Authoritative status has unsupported state: $State"
    }
    return $Status
}

function Write-HealthAtomically {
    param([string]$Path, [object]$Health)

    $HealthDirectory = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($HealthDirectory)) {
        $HealthDirectory = (Get-Location).Path
    }
    if (-not (Test-Path -LiteralPath $HealthDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $HealthDirectory -Force | Out-Null
    }

    $TemporaryHealthPath = Join-Path $HealthDirectory ('.{0}.{1}.tmp' -f [System.IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($TemporaryHealthPath, ($Health | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $TemporaryHealthPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $TemporaryHealthPath) {
            Remove-Item -LiteralPath $TemporaryHealthPath -Force
        }
    }
}

function Get-ProcessTelemetry {
    param(
        [object]$ProcessId,
        [hashtable]$PreviousSamples
    )

    if ($null -eq $ProcessId) {
        return [pscustomobject]@{ Label = 'not supplied'; CpuPercent = $null; RamMb = $null }
    }

    try {
        $ProcessIdValue = [int]$ProcessId
        $ObservedProcess = Get-Process -Id $ProcessIdValue -ErrorAction Stop
        $ObservedAt = [datetimeoffset]::Now
        $CpuSeconds = if ($null -ne $ObservedProcess.CPU) { [double]$ObservedProcess.CPU } else { $null }
        $CpuPercent = $null
        if ($null -ne $CpuSeconds -and $PreviousSamples.ContainsKey($ProcessIdValue)) {
            $Previous = $PreviousSamples[$ProcessIdValue]
            $ElapsedSeconds = ($ObservedAt - $Previous.ObservedAt).TotalSeconds
            if ($ElapsedSeconds -gt 0) {
                $CpuPercent = [math]::Max(0, (($CpuSeconds - $Previous.CpuSeconds) / $ElapsedSeconds / [Environment]::ProcessorCount) * 100)
            }
        }
        if ($null -ne $CpuSeconds) {
            [void]($PreviousSamples[$ProcessIdValue] = [pscustomobject]@{ ObservedAt = $ObservedAt; CpuSeconds = $CpuSeconds })
        }
        return [pscustomobject]@{
            Label = 'running'
            CpuPercent = $CpuPercent
            RamMb = [math]::Round($ObservedProcess.WorkingSet64 / 1MB, 1)
        }
    }
    catch {
        return [pscustomobject]@{ Label = 'not running (not success evidence)'; CpuPercent = $null; RamMb = $null }
    }
}

function Get-ProgressObservation {
    param([object]$Status, [object]$PreviousProgress)

    $Processed = Get-PropertyValue -Object $Status -Name 'processed'
    $Total = Get-PropertyValue -Object $Status -Name 'total'
    if ($null -eq $Processed -and $null -eq $Total) {
        return [pscustomobject]@{ Exact = $false; Availability = 'unavailable'; Processed = $null; Total = $null; Percent = $null; Rate = $null; EtaSeconds = $null; EstimatedFinish = $null }
    }
    if ($null -eq $Processed -or $null -eq $Total) {
        return [pscustomobject]@{ Exact = $false; Availability = 'temporarily unavailable'; Processed = $null; Total = $null; Percent = $null; Rate = $null; EtaSeconds = $null; EstimatedFinish = $null }
    }

    try {
        $ProcessedValue = [double]$Processed
        $TotalValue = [double]$Total
    }
    catch {
        return [pscustomobject]@{ Exact = $false; Availability = 'temporarily unavailable'; Processed = $null; Total = $null; Percent = $null; Rate = $null; EtaSeconds = $null; EstimatedFinish = $null }
    }
    if ($TotalValue -le 0 -or $ProcessedValue -lt 0) {
        return [pscustomobject]@{ Exact = $false; Availability = 'temporarily unavailable'; Processed = $null; Total = $null; Percent = $null; Rate = $null; EtaSeconds = $null; EstimatedFinish = $null }
    }

    $State = [string](Get-PropertyValue -Object $Status -Name 'state')
    $ArtifactValidated = [bool](Get-PropertyValue -Object $Status -Name 'artifact_validated')
    $RawPercent = [math]::Min(100, ($ProcessedValue / $TotalValue) * 100)
    $Percent = if ($State -eq 'COMPLETED' -and $ArtifactValidated) { $RawPercent } else { [math]::Min(99.99, $RawPercent) }
    $Now = [datetimeoffset]::Now
    $Rate = $null
    if ($null -ne $PreviousProgress) {
        $ElapsedSeconds = ($Now - $PreviousProgress.ObservedAt).TotalSeconds
        $Delta = $ProcessedValue - $PreviousProgress.Processed
        if ($ElapsedSeconds -gt 0 -and $Delta -gt 0) {
            $Rate = $Delta / $ElapsedSeconds
        }
    }
    $EtaSeconds = $null
    $EstimatedFinish = $null
    if ($null -ne $Rate -and $Rate -gt 0 -and $ProcessedValue -lt $TotalValue) {
        $EtaSeconds = ($TotalValue - $ProcessedValue) / $Rate
        $EstimatedFinish = $Now.AddSeconds($EtaSeconds)
    }
    return [pscustomobject]@{ Exact = $true; Availability = $null; Processed = $ProcessedValue; Total = $TotalValue; Percent = $Percent; Rate = $Rate; EtaSeconds = $EtaSeconds; EstimatedFinish = $EstimatedFinish; ObservedAt = $Now }
}

function Get-GpuTelemetry {
    param([string]$NvidiaSmiPath)
    if ([string]::IsNullOrWhiteSpace($NvidiaSmiPath)) {
        return $null
    }
    try {
        $GpuLine = & $NvidiaSmiPath '--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu' '--format=csv,noheader,nounits' 2>$null | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($GpuLine)) { return $null }
        $Parts = $GpuLine -split ',' | ForEach-Object { $_.Trim() }
        if ($Parts.Count -lt 4) { return $null }
        return [pscustomobject]@{ Utilization = $Parts[0]; MemoryUsed = $Parts[1]; MemoryTotal = $Parts[2]; Temperature = $Parts[3] }
    }
    catch { return $null }
}

function Write-MonitorScreen {
    param([object]$Status, [object]$Progress, [object]$TargetTelemetry, [object]$SupervisorTelemetry, [object]$GpuTelemetry)

    # Clearing is cosmetic; a redirected or noninteractive host may not have a
    # console handle and must not turn a healthy observation into an error.
    try { Clear-Host -ErrorAction Stop } catch { }
    $State = [string](Get-PropertyValue -Object $Status -Name 'state')
    Write-Host ('{0} — {1}' -f (Get-PropertyValue -Object $Status -Name 'task'), $State)
    Write-Host ('Stage: {0}' -f (Get-PropertyValue -Object $Status -Name 'stage'))
    if ($Progress.Exact) {
        $Unit = Get-PropertyValue -Object $Status -Name 'unit'
        Write-Host ('Progress: {0:N0} / {1:N0} {2}' -f $Progress.Processed, $Progress.Total, $Unit)
        Write-Host ('Percent: {0:N2}%' -f $Progress.Percent)
        if ($Progress.Rate -ne $null) {
            Write-Host ('Rate: {0:N2} {1}/s' -f $Progress.Rate, $Unit)
        }
        $EtaText = if ($Progress.EtaSeconds -ne $null) { 'ETA: ' + [timespan]::FromSeconds($Progress.EtaSeconds).ToString() } else { 'ETA: unavailable (awaiting counter movement)' }
        Write-Host $EtaText
        if ($Progress.EstimatedFinish -ne $null) {
            Write-Host ('Estimated finish: {0:O}' -f $Progress.EstimatedFinish)
        }
        if ($Progress.Percent -ge 99.99 -and -not ($State -eq 'COMPLETED' -and [bool](Get-PropertyValue -Object $Status -Name 'artifact_validated'))) {
            Write-Host 'FINALIZATION PENDING'
        }
    }
    else {
        Write-Host ('ACTIVE — exact progress {0}' -f $Progress.Availability)
    }
    Write-Host ('Target PID: {0}; CPU: {1}; RAM: {2}' -f (Get-PropertyValue -Object $Status -Name 'target_process_id'), $TargetTelemetry.CpuPercent, $TargetTelemetry.RamMb)
    Write-Host ('Supervisor PID: {0}; CPU: {1}; RAM: {2}' -f (Get-PropertyValue -Object $Status -Name 'supervisor_process_id'), $SupervisorTelemetry.CpuPercent, $SupervisorTelemetry.RamMb)
    if ($null -ne $GpuTelemetry) {
        Write-Host ('GPU: {0}% | {1}/{2} MiB | {3} C' -f $GpuTelemetry.Utilization, $GpuTelemetry.MemoryUsed, $GpuTelemetry.MemoryTotal, $GpuTelemetry.Temperature)
    }
    if ($State -eq 'FAILED' -and $null -ne (Get-PropertyValue -Object $Status -Name 'last_error')) {
        Write-Host ('Error: {0}' -f (Get-PropertyValue -Object $Status -Name 'last_error'))
    }
}

if ([string]::IsNullOrWhiteSpace($HealthPath)) {
    $HealthPath = Join-Path (Split-Path -Parent $StatusPath) 'monitor-health.json'
}
$NvidiaSmiPath = $null
if ($EnableGpu) {
    $NvidiaSmiCommand = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if ($null -ne $NvidiaSmiCommand) { $NvidiaSmiPath = $NvidiaSmiCommand.Source }
}
$RefreshCount = 0
$PreviousProgress = $null
$PreviousProcessSamples = @{}
$MonitorProcessId = Get-CurrentProcessId

while ($true) {
    try {
        $Status = Read-AuthoritativeStatus -Path $StatusPath
        $Progress = Get-ProgressObservation -Status $Status -PreviousProgress $PreviousProgress
        if ($Progress.Exact) { $PreviousProgress = $Progress } else { $PreviousProgress = $null }
        $TargetProcessId = Get-PropertyValue -Object $Status -Name 'target_process_id'
        $SupervisorProcessId = Get-PropertyValue -Object $Status -Name 'supervisor_process_id'
        $TargetTelemetry = Get-ProcessTelemetry -ProcessId $TargetProcessId -PreviousSamples $PreviousProcessSamples
        $SupervisorTelemetry = Get-ProcessTelemetry -ProcessId $SupervisorProcessId -PreviousSamples $PreviousProcessSamples
        $GpuTelemetry = Get-GpuTelemetry -NvidiaSmiPath $NvidiaSmiPath
        $RefreshCount++
        $Health = [ordered]@{
            contract_version = 'agent-long-task-monitor-health-v1'
            monitor_process_id = $MonitorProcessId
            refresh_count = $RefreshCount
            last_refresh_at = [datetimeoffset]::Now.ToString('O')
            observed_state = Get-PropertyValue -Object $Status -Name 'state'
            observed_target_process_id = $TargetProcessId
            observed_supervisor_process_id = $SupervisorProcessId
            observed_processed = Get-PropertyValue -Object $Status -Name 'processed'
            observed_total = Get-PropertyValue -Object $Status -Name 'total'
        }
        Write-HealthAtomically -Path $HealthPath -Health $Health
        Write-MonitorScreen -Status $Status -Progress $Progress -TargetTelemetry $TargetTelemetry -SupervisorTelemetry $SupervisorTelemetry -GpuTelemetry $GpuTelemetry
        if ($PassThru) {
            [pscustomobject]@{ status = $Status; progress = $Progress; health_path = $HealthPath }
        }

        $State = [string](Get-PropertyValue -Object $Status -Name 'state')
        $IsTerminal = @('COMPLETED', 'FAILED', 'BLOCKED', 'INTERRUPTED') -contains $State
        if ($IsTerminal) {
            if (-not $Once) { Read-Host 'Monitoring finished. Press Enter to close this window.' | Out-Null }
            break
        }
    }
    catch {
        Write-Host ('MONITOR ERROR: {0}' -f $_.Exception.Message)
        if ($Once) { exit 1 }
    }
    if ($Once) { break }
    Start-Sleep -Seconds $RefreshSeconds
}

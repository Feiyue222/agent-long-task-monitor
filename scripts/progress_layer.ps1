# Optional Layer 2 helper for Windows PowerShell 5.1 and PowerShell 7.
# The private Python helper observes progress only and exits on stdin EOF.
function Open-ApplicationProgress {
    param([string]$Path, [string]$PythonExecutable, [double]$StaleSeconds, [double]$WarningSeconds, [double]$HeartbeatSeconds = 5)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $PythonExecutable
    $info.Arguments = '-B -u "' + (Join-Path $PSScriptRoot 'progress_bridge.py') + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $helper = New-Object System.Diagnostics.Process
    $helper.StartInfo = $info
    [void]$helper.Start()
    $request = @{path=$Path;stale_seconds=$StaleSeconds;no_progress_seconds=$WarningSeconds;heartbeat_seconds=$HeartbeatSeconds} | ConvertTo-Json -Compress
    # ASCII JSON escapes survive both Framework and Core stdin encodings.
    $request = [regex]::Replace($request, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
    $helper.StandardInput.WriteLine($request)
    $ready = $helper.StandardOutput.ReadLineAsync()
    if (-not $ready.Wait(5000) -or $ready.Result -ne '{"ready":true}') {
        $helper.StandardInput.Close()
        throw 'Application progress helper unavailable.'
    }
    return $helper
}

function Read-ApplicationProgress {
    param([object]$Helper)
    $Helper.StandardInput.WriteLine('observe')
    $line = $Helper.StandardOutput.ReadLineAsync()
    if (-not $line.Wait(5000) -or $null -eq $line.Result) { throw 'Application progress helper unavailable.' }
    return ($line.Result | ConvertFrom-Json)
}

function Close-ApplicationProgress {
    param([object]$Helper)
    if ($null -ne $Helper) {
        try { $Helper.StandardInput.Close() } catch { }
        [void]$Helper.WaitForExit(1000)
        $Helper.Dispose()
    }
}

function Write-ApplicationProgress {
    param([object]$Observation)
    Write-Host 'Layer 2 - application-owned operational progress'
    if ($null -eq $Observation) { Write-Host 'NOT_AVAILABLE'; return }
    Write-Host ('Application: {0}; Progress freshness: {1}' -f $Observation.application, $Observation.freshness)
    if ($null -eq $Observation.snapshot) { Write-Host 'Progress: UNKNOWN'; return }
    $snapshot = $Observation.snapshot
    Write-Host ('Identity-bound process: {0}; Expected application heartbeat: {1}s' -f $Observation.process_state, $Observation.heartbeat_expected_seconds)
    Write-Host ('Stage: {0}; Substage: {1}; Scope: {2}' -f $snapshot.stage, $snapshot.substage, $snapshot.progress_scope_id)
    $completed = if ($null -eq $snapshot.completed_units) { 'UNKNOWN' } else { $snapshot.completed_units }
    $total = if ($null -eq $snapshot.total_units) { 'UNKNOWN' } else { $snapshot.total_units }
    Write-Host ('Progress: {0} / {1} {2}' -f $completed, $total, $snapshot.unit_name)
    $percent = if ($null -eq $Observation.percent) { 'UNKNOWN' } else { '{0:N2}%' -f ($Observation.percent * 100) }
    $rate = if ($null -eq $Observation.rate_per_second) { 'UNKNOWN' } else { $Observation.rate_per_second }
    $eta = if ($null -eq $Observation.eta_seconds) { 'UNKNOWN' } else { $Observation.eta_seconds }
    Write-Host ('Scope percent: {0}; Rate: {1}; ETA seconds (estimate): {2}' -f $percent, $rate, $eta)
    Write-Host ('Last progress: {0}; Terminal: {1} (not artifact validation)' -f $snapshot.last_progress_at, $snapshot.terminal_state)
}

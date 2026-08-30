[CmdletBinding()]
param(
    [ValidateRange(1, 120)] [int]$TotalItems = 12,
    [ValidateRange(1, 10)] [int]$SecondsPerItem = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-StatusAtomically {
    param([Parameter(Mandatory = $true)] [string]$Path, [Parameter(Mandatory = $true)] [object]$Status)
    $directory = Split-Path -Parent $Path
    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporaryPath, ($Status | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

$runtimeDirectory = Join-Path $PSScriptRoot 'runtime'
$statusPath = Join-Path $runtimeDirectory 'status.json'
$artifactPath = Join-Path $runtimeDirectory 'demo-artifact.txt'
New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
Remove-Item -LiteralPath $statusPath, $artifactPath -Force -ErrorAction SilentlyContinue

$taskProcessId = [Diagnostics.Process]::GetCurrentProcess().Id
$status = [ordered]@{
    contract_version = 'agent-long-task-status-v1'
    task = '30-second authoritative demo'
    stage = 'Preparing item 1'
    state = 'RUNNING'
    started_at = [datetimeoffset]::Now.ToString('O')
    processed = 0
    total = $TotalItems
    unit = 'demo items'
    target_process_id = $taskProcessId
    supervisor_process_id = $null
    checkpoint_state = 'NOT_APPLICABLE'
    artifact_state = 'PENDING'
    artifact_validated = $false
    artifact_path = $artifactPath
    last_error = $null
}

Write-StatusAtomically -Path $statusPath -Status $status
Write-Host "Demo task started: $TotalItems authoritative items."
Write-Host "Status: $statusPath"

try {
    for ($item = 1; $item -le $TotalItems; $item++) {
        Start-Sleep -Seconds $SecondsPerItem
        $status.processed = $item
        $status.stage = "Processed item $item of $TotalItems"
        Write-StatusAtomically -Path $statusPath -Status $status
        Write-Host "Authoritative progress: $item / $TotalItems"
    }

    [IO.File]::WriteAllText($artifactPath, "validated demo artifact created at $([datetimeoffset]::Now.ToString('O'))", [Text.UTF8Encoding]::new($false))
    $status.state = 'COMPLETED'
    $status.stage = 'Validated demo artifact'
    $status.completed_at = [datetimeoffset]::Now.ToString('O')
    $status.artifact_validated = Test-Path -LiteralPath $artifactPath -PathType Leaf
    $status.artifact_state = if ($status.artifact_validated) { 'VALID' } else { 'MISSING_OR_NOT_VALIDATED' }
    Write-StatusAtomically -Path $statusPath -Status $status
    Write-Host 'Demo completed: artifact validation recorded.'
}
catch {
    $status.state = 'FAILED'
    $status.stage = 'Demo failed'
    $status.completed_at = [datetimeoffset]::Now.ToString('O')
    $status.last_error = $_.Exception.Message
    $status.artifact_state = 'NOT_VALIDATED'
    $status.artifact_validated = $false
    Write-StatusAtomically -Path $statusPath -Status $status
    throw
}

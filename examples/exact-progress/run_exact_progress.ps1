[CmdletBinding()]
param([string]$StatusPath = (Join-Path $PSScriptRoot 'status.json'))

function Write-StatusAtomically {
    param([string]$Path, [object]$Status)
    $Directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $TemporaryPath = Join-Path $Directory ('.{0}.{1}.tmp' -f [System.IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    try { [System.IO.File]::WriteAllText($TemporaryPath, ($Status | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false)); Move-Item -LiteralPath $TemporaryPath -Destination $Path -Force }
    finally { if (Test-Path -LiteralPath $TemporaryPath) { Remove-Item -LiteralPath $TemporaryPath -Force } }
}

$ArtifactPath = Join-Path (Split-Path -Parent $StatusPath) 'artifact.txt'
$CurrentProcessId = [System.Diagnostics.Process]::GetCurrentProcess().Id
$Status = [ordered]@{ contract_version = 'agent-long-task-status-v1'; task = 'Exact progress demo'; stage = 'WORKING'; state = 'RUNNING'; started_at = [datetimeoffset]::Now.ToString('O'); processed = 0; total = 30; unit = 'items'; target_process_id = $CurrentProcessId; supervisor_process_id = $null; checkpoint_state = 'NOT_APPLICABLE'; artifact_state = 'PENDING'; artifact_validated = $false; last_error = $null }
for ($Index = 1; $Index -le 6; $Index++) {
    $Status.processed = $Index * 5
    Write-StatusAtomically -Path $StatusPath -Status $Status
    Start-Sleep -Seconds 1
}
[System.IO.File]::WriteAllText($ArtifactPath, 'validated demo artifact')
$Status.state = 'COMPLETED'; $Status.stage = 'FINISHED'; $Status.artifact_state = 'VALID'; $Status.artifact_validated = $true; $Status.completed_at = [datetimeoffset]::Now.ToString('O')
Write-StatusAtomically -Path $StatusPath -Status $Status
Write-Output "Exact-progress demo completed: $StatusPath"


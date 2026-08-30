[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$FilePath,
    [string[]]$ArgumentList = @(),
    [Parameter(Mandatory = $true)] [string]$StatusPath,
    [string]$Task = 'Generic command',
    [string]$ArtifactPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-StatusAtomically {
    param([string]$Path, [object]$Status)
    $Directory = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $TemporaryPath = Join-Path $Directory ('.{0}.{1}.tmp' -f [System.IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($TemporaryPath, ($Status | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $TemporaryPath -Destination $Path -Force
    }
    finally { if (Test-Path -LiteralPath $TemporaryPath) { Remove-Item -LiteralPath $TemporaryPath -Force } }
}

$SupervisorProcessId = [System.Diagnostics.Process]::GetCurrentProcess().Id
$StatusDirectory = Split-Path -Parent $StatusPath
if ([string]::IsNullOrWhiteSpace($StatusDirectory)) { $StatusDirectory = (Get-Location).Path }
$StdOutPath = Join-Path $StatusDirectory 'target.stdout.log'
$StdErrPath = Join-Path $StatusDirectory 'target.stderr.log'
$Status = [ordered]@{
    contract_version = 'agent-long-task-status-v1'; task = $Task; stage = 'STARTING'; state = 'RUNNING'; started_at = [datetimeoffset]::Now.ToString('O')
    processed = $null; total = $null; unit = $null; target_process_id = $null; supervisor_process_id = $SupervisorProcessId
    checkpoint_state = 'NOT_APPLICABLE'; artifact_state = 'PENDING'; artifact_validated = $false; last_error = $null
    command_display = [System.IO.Path]::GetFileName($FilePath); stdout_path = $StdOutPath; stderr_path = $StdErrPath; native_exit_code = $null
}
Write-StatusAtomically -Path $StatusPath -Status $Status

try {
    $TargetProcess = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -RedirectStandardOutput $StdOutPath -RedirectStandardError $StdErrPath
    $Status.target_process_id = $TargetProcess.Id
    $Status.stage = 'RUNNING'
    Write-StatusAtomically -Path $StatusPath -Status $Status
    $TargetProcess.WaitForExit()
    $NativeExitCode = $TargetProcess.ExitCode
    $Status.completed_at = [datetimeoffset]::Now.ToString('O')
    $Status.native_exit_code = $NativeExitCode
    if ($NativeExitCode -eq 0) {
        $Status.state = 'COMPLETED'
        $Status.artifact_validated = -not [string]::IsNullOrWhiteSpace($ArtifactPath) -and (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)
        $Status.artifact_state = if ($Status.artifact_validated) { 'VALID' } else { 'MISSING_OR_NOT_VALIDATED' }
    }
    else {
        $Status.state = 'FAILED'; $Status.artifact_state = 'NOT_VALIDATED'; $Status.last_error = "Target exited with native exit code $NativeExitCode."
    }
    Write-StatusAtomically -Path $StatusPath -Status $Status
    if ($NativeExitCode -ne 0) { exit $NativeExitCode }
}
catch {
    $Status.state = 'FAILED'; $Status.completed_at = [datetimeoffset]::Now.ToString('O'); $Status.last_error = $_.Exception.Message
    Write-StatusAtomically -Path $StatusPath -Status $Status
    throw
}


[CmdletBinding()]
param([string]$StatusPath = (Join-Path $PSScriptRoot 'status.json'))

$SupervisorScriptPath = Join-Path $PSScriptRoot '..\..\scripts\example_supervisor.ps1'
& $SupervisorScriptPath -FilePath $env:ComSpec -ArgumentList @('/c', 'exit 7') -StatusPath $StatusPath -Task 'Failure demo'
$SupervisorExitCode = $LASTEXITCODE
$Status = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
if ($SupervisorExitCode -ne 7 -or $Status.state -ne 'FAILED' -or [int]$Status.native_exit_code -ne 7) {
    throw 'Failure demo did not preserve the expected FAILED lifecycle evidence.'
}
Write-Output "Failure demo passed: state=$($Status.state), native_exit_code=$($Status.native_exit_code)"


[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot; $Scripts = Join-Path $Root 'scripts'; $Fixtures = Join-Path $PSScriptRoot 'fixtures'; $Monitor = Join-Path $Scripts 'watch_long_task.ps1'; $Health = Join-Path $Scripts 'test_monitor_health.ps1'; $Supervisor = Join-Path $Scripts 'example_supervisor.ps1'; $PassCount = 0
function Assert-True { param([bool]$Condition,[string]$Name) if(-not $Condition){throw "FAIL: $Name"}; $script:PassCount++; "PASS: $Name" }
function Invoke-Once { param([string]$Status,[string]$HealthPath) & $Monitor -StatusPath $Status -HealthPath $HealthPath -Once -PassThru 6>$null }
$Runtime = Join-Path $Fixtures '.contract-runtime'; if(Test-Path $Runtime){Remove-Item $Runtime -Recurse -Force}; New-Item -ItemType Directory -Path $Runtime -Force|Out-Null
try {
  $All = Get-ChildItem $Scripts -Filter '*.ps1' -File; foreach($File in $All){$t=$null;$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($File.FullName,[ref]$t,[ref]$e);Assert-True($e.Count -eq 0)("PowerShell parses "+$File.Name)}
  $MonitorText=[IO.File]::ReadAllText($Monitor);$HealthText=[IO.File]::ReadAllText($Health);$SupervisorText=[IO.File]::ReadAllText($Supervisor);$AllText=($All|%{[IO.File]::ReadAllText($_.FullName)})-join "`n"
  Assert-True -Condition (-not($MonitorText -match 'Stop-Process|Start-Process|WaitForExit|\.Kill\(')) -Name 'sidecar has no target process control'
  Assert-True -Condition (-not($AllText -match '(?im)^\s*\$(?:pid)\s*=')) -Name 'no script-owned automatic PID variable'
  Assert-True -Condition ($MonitorText -match 'OrdinalIgnoreCase' -and $MonitorText -match 'Refusing to write authoritative status') -Name 'health/status collision fails closed'
  Assert-True -Condition ($HealthText -notmatch 'SkipWait' -and $HealthText -match 'Start-Sleep -Seconds \$RefreshSeconds') -Name 'health check always waits a refresh interval'
  Assert-True -Condition ($HealthText -match 'MaxHeartbeatAgeSeconds' -and $HealthText -match 'monitor_process_id does not match') -Name 'health validates current fresh monitor instance'
  Assert-True -Condition ($HealthText -match 'observed target PID does not match authoritative status' -and $HealthText -match 'observed supervisor PID does not match authoritative status') -Name 'health compares heartbeat IDs to authority'
  Assert-True -Condition ($MonitorText -match '\$ProcessedValue -gt \$TotalValue') -Name 'counter overflow is invalid progress'
  Assert-True -Condition ($MonitorText -match '\$State -eq ''COMPLETED'' -and \$ArtifactValidated') -Name 'numeric 100 requires completed validated state'
  Assert-True -Condition ($SupervisorText -match 'command_executable = \$FilePath' -and $SupervisorText -match 'command_arguments') -Name 'supervisor records command evidence'
  $Exact=Invoke-Once (Join-Path $Fixtures 'exact-running.json') (Join-Path $Runtime 'exact.health.json');Assert-True -Condition ($Exact.progress.Exact -and $Exact.progress.Percent -eq 50) -Name 'exact progress available'
  $No=Invoke-Once (Join-Path $Fixtures 'no-progress-running.json') (Join-Path $Runtime 'none.health.json');Assert-True -Condition (-not $No.progress.Exact) -Name 'null counters unavailable'
  $Final=Invoke-Once (Join-Path $Fixtures 'finalization-pending.json') (Join-Path $Runtime 'final.health.json');Assert-True -Condition ($Final.progress.Percent -eq 99.99) -Name 'unvalidated finalization capped'
  $Overflow=Join-Path $Runtime 'overflow.json';$OverflowJson=(Get-Content (Join-Path $Fixtures 'exact-running.json') -Raw|ConvertFrom-Json);$OverflowJson.processed=101;$OverflowJson|ConvertTo-Json|Set-Content $Overflow;$Over=Invoke-Once $Overflow (Join-Path $Runtime 'overflow.health.json');Assert-True -Condition (-not $Over.progress.Exact) -Name 'processed greater than total has no progress'
  $StatusBytes=[IO.File]::ReadAllBytes((Join-Path $Fixtures 'exact-running.json'));$HostExecutable=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$CollisionLog=Join-Path $Runtime 'collision.stderr.log';$CollisionProcess=Start-Process -FilePath $HostExecutable -ArgumentList @('-NoProfile','-File',$Monitor,'-StatusPath',(Join-Path $Fixtures 'exact-running.json'),'-HealthPath',(Join-Path $Fixtures 'exact-running.json'),'-Once') -PassThru -Wait -RedirectStandardError $CollisionLog;$CollisionExit=$CollisionProcess.ExitCode;Assert-True -Condition ($CollisionExit -ne 0) -Name 'StatusPath equals HealthPath rejected';Assert-True -Condition ([Convert]::ToBase64String($StatusBytes) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $Fixtures 'exact-running.json')))) -Name 'collision leaves status bytes unchanged'
  Assert-True -Condition ($SupervisorText -match '\$NativeExitCode = \$TargetProcess\.ExitCode' -and $SupervisorText -match '\$Status\.state = ''FAILED''') -Name 'supervisor records non-zero native failure'
  "Contract tests passed: $PassCount"
} finally {if(Test-Path $Runtime){Remove-Item $Runtime -Recurse -Force}}

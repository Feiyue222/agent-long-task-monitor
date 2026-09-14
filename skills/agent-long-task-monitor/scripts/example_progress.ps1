[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$ProgressPath,
    [string]$PythonExecutable = 'python.exe',
    [ValidateRange(0.01, 10)] [double]$StepSeconds = 1
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This PowerShell application owns the work/counters and supplies its exact
# identity. Python supplies the same strict serializer and atomic publisher.
$application = [Diagnostics.Process]::GetCurrentProcess()
$creation = $application.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $PythonExecutable
$info.Arguments = '-B -u "' + (Join-Path $PSScriptRoot 'progress_emit.py') + '"'
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardInput = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$emitter = New-Object Diagnostics.Process
$emitter.StartInfo = $info
[void]$emitter.Start()

function Send-ProgressEvent {
    param([hashtable]$Event)
    $line = $Event | ConvertTo-Json -Depth 6 -Compress
    $line = [regex]::Replace($line, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
    $emitter.StandardInput.WriteLine($line)
    $reply = $emitter.StandardOutput.ReadLineAsync()
    if (-not $reply.Wait(5000) -or $null -eq $reply.Result -or -not ($reply.Result | ConvertFrom-Json).ok) {
        throw 'Bounded progress emitter failure.'
    }
}

try {
    Send-ProgressEvent @{path=[IO.Path]::GetFullPath($ProgressPath);task_id='powershell-example';execution_instance_id=[guid]::NewGuid().ToString();stream_id=[guid]::NewGuid().ToString();application_process_id=$application.Id;application_creation_identity=@{kind='WINDOWS_FILETIME';value=$creation};stage='PREPARE';progress_scope_id='prepare'}
    Start-Sleep -Milliseconds ([int]($StepSeconds * 1000))
    Send-ProgressEvent @{action='transition';stage='PROCESS';scope='items';completed_units=0;total_units=3;unit_name='items'}
    foreach ($number in 1..3) {
        Start-Sleep -Milliseconds ([int]($StepSeconds * 1000))
        # Real harmless application work, explicitly counted by the application.
        [void][Math]::Sqrt($number)
        Send-ProgressEvent @{action='advance';completed_units=$number}
    }
    Start-Sleep -Milliseconds ([int]($StepSeconds * 1000))
    Send-ProgressEvent @{action='finish';terminal_state='SUCCEEDED'}
}
finally {
    $emitter.StandardInput.Close()
    if (-not $emitter.WaitForExit(5000)) { throw 'Emitter exit not observed; no application termination attempted.' }
    $emitter.Dispose()
}

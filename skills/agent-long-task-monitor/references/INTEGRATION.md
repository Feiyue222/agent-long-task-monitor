# Integration

## 1. Write authoritative status

The task owns `status.json` and updates it atomically. Start with `RUNNING`.
Include process IDs when known. Publish exact counters only when they are
authoritative; otherwise use null counters.

## 2. Start the sidecar and check it once

```powershell
.\scripts\start_monitor.ps1 `
  -StatusPath C:\work\status.json `
  -RefreshSeconds 10 `
  -VerifyHealth
```

`-VerifyHealth` waits at least one whole refresh interval, then verifies the
new monitor process, fresh heartbeat, refresh count, expected IDs (when
provided), and readable authoritative status. A failed check does not stop the
target or start a replacement.

After this one successful check, the coding agent must stop polling. The human
uses the monitor window; a terminal result should be reported back when needed.

## Optional supervisor

When the calling component should own a newly launched child process, use the
reference supervisor:

```powershell
.\scripts\example_supervisor.ps1 `
  -FilePath $env:ComSpec -ArgumentList '/c', 'your-command' `
  -StatusPath C:\work\status.json -Task 'Your task' `
  -ArtifactPath C:\work\result.bin
```

It retains the `Process` object, waits for it, and records its native exit code.
It records `command_executable` and `command_arguments`; callers must redact
credentials, tokens, and other secrets before passing arguments. For an adopted
process, let that process's owner publish the status instead.

## Final states

`COMPLETED` becomes a true 100% display only with `artifact_validated: true`.
`FAILED`, `BLOCKED`, and `INTERRUPTED` are terminal and remain visibly distinct.
`PAUSED` remains observable without being silently treated as a pass.

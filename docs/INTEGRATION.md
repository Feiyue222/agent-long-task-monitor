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

`processed == total` alone is not success. When valid exact `processed` /
`total` counters exist, numeric 100% requires both `COMPLETED` and
`artifact_validated: true`. When counters are unavailable, successful terminal
completion may still be shown but numeric 100% is never invented. Process
disappearance is not success evidence. `FAILED`, `BLOCKED`, and `INTERRUPTED`
remain visibly distinct; `PAUSED` remains observable without being silently
treated as a pass.

## Optional Layer 2 (Python 3.10+)

Put the shipped `scripts` directory on your import path (or vendor these
standard-library modules together), then publish from the application:

```python
from progress_publisher import Publisher
from progress_identity import own_identity

process_id, creation = own_identity()  # typed Windows FILETIME, or unknown pair
with Publisher("work/progress.json", task_id="conversion",
               execution_instance_id="new-execution-id", stream_id="new-stream-id",
               application_process_id=process_id,
               application_creation_identity=creation,
               stage="PROCESS", progress_scope_id="items",
               completed_units=0, total_units=100, unit_name="items") as progress:
    for index in range(100):
        convert_one_item(index)  # your application-owned operation
        progress.advance(index + 1)
        # Also call heartbeat() in long operations, at least every five seconds.
    progress.finish()
```

An operation without a denominator uses null total and may report explicit
`advance(milestone="header_written")` events. `transition(stage="WRITE_OUTPUT",
scope="output")` resets to a new unknown counter scope and publishes immediately.
Calling transition again with the same stage/substage/scope is not progress.
After a publication error, the prior latest remains intact; an application may
retry `publish(force=True)` for its pending snapshot without repeating work.
Publication failure is not permission to rerun or resume the underlying task.

Consumer usage:

```python
from progress_consumer import Consumer
from progress_protocol import read_latest

consumer = Consumer(expected_identity={"task_id": "conversion",
    "execution_instance_id": "new-execution-id", "stream_id": "new-stream-id"})
# Reuse this object across reads. Supply verified control state if available.
view = consumer.observe(read_latest("work/progress.json"), process_state="UNKNOWN")
```

Without an expected identity, first-snapshot binding is trust-on-first-use,
not authentication. A restarted consumer waits for sequence advancement before
claiming fresh heartbeats. An unchanged file cannot refresh itself.

Renderer usage:

```powershell
./scripts/watch_long_task.ps1 -StatusPath ./work/status.json `
  -ProgressPath ./work/progress.json -RefreshSeconds 1 `
  -ProgressPythonExecutable python.exe `
  -ProgressStaleSeconds 20 -NoProgressWarningSeconds 120
```

Layer 2 is observational: no inferred CPU progress, termination, restart or
artifact validation. Python/helper failure displays Layer-2 CONTROL_FAILURE
while Layer-1 health/status behavior continues. The helper pins the first
stream and checks exact Windows process creation identity when available.
Existing consumers can omit ProgressPath and retain v0.2.0 semantics and no
Python dependency. See the [normative protocol](APPLICATION_PROGRESS_PROTOCOL.md)
for bounds, failure semantics and the 5-second heartbeat / 1-Hz publication
defaults. See the [harmless demo](../examples/application-progress/README.md).

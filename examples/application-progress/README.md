# Harmless application-owned progress demo

Requires Python 3.10+; the renderer supports Windows PowerShell 5.1 and 7.
From the repository root, use a new output directory for each run:

```powershell
# Terminal 1: application, with known and unknown denominator scopes.
python -B scripts/demo_progress.py --directory examples/application-progress/runtime

# Terminal 2: independent two-layer renderer.
./scripts/watch_long_task.ps1 `
  -StatusPath examples/application-progress/runtime/status.json `
  -ProgressPath examples/application-progress/runtime/progress.json `
  -RefreshSeconds 1
```

The application waits six seconds in PREPARE with an unknown denominator and
heartbeats without progress. PROCESS computes eight harmless string digests
with a fixed item denominator. WRITE_OUTPUT uses a new unknown-denominator
scope and writes a small text file. Terminal success is separate from the
Layer-1 file validation performed by the application afterwards.

To see a no-progress warning while application heartbeats remain fresh:

```powershell
python -B scripts/demo_progress.py --directory examples/application-progress/runtime-stall --stall-seconds 130
```

Use corresponding status/progress paths in the second terminal. The monitor
does not conclude deadlock or terminate the application. For quick tests,
shorter demo/consumer thresholds can be supplied explicitly; production defaults
remain 5/20/120 seconds. Internal work advances faster than publication in the
quick variant, demonstrating coalescing.

A non-Python application can use the PowerShell emitter example:

```powershell
./scripts/example_progress.ps1 -ProgressPath examples/application-progress/runtime-ps/progress.json
```

PowerShell owns its process identity and actual item events; a persistent Python
helper supplies the normative validator and atomic publisher. It does not use
PowerShell's JSON output as the final wire serializer.

These examples never adopt an old snapshot or resume a stream. Select a new
directory for a new run; do not infer retry permission from this demonstration.

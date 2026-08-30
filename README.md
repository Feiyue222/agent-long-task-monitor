# Agent Long Task Monitor

Stop wasting coding-agent tokens polling long-running local jobs.

Agent Long Task Monitor is a small, local-only PowerShell toolkit for Windows
PowerShell 5.1 and PowerShell 7+. A task publishes authoritative lifecycle and
optional counter progress in a tiny JSON file. An independent monitor window
renders that state for a human and writes a separate heartbeat proving it is
refreshing.

```text
AI agent ──> supervisor ──> long-running process
                    └────> status.json (authoritative)

human <── PowerShell monitor <── status.json
                         └──> monitor-health.json (monitor-owned)
```

The monitor is observational: it does not start, stop, restart, pause, or kill
the target; it never changes status, checkpoints, or artifacts. A vanished
process is not evidence of success.

## Quick start

1. Have the task or a supervisor atomically write a status file following
   [the protocol](docs/STATUS_PROTOCOL.md).
2. Start the monitor:

   ```powershell
   .\scripts\start_monitor.ps1 -StatusPath .\status.json -VerifyHealth
   ```

3. After the one health check has passed, the coding agent stops polling. The
   human watches the monitor window and reports a terminal result if needed.

See [integration guidance](docs/INTEGRATION.md), the three quick examples, and
the offline contract tests in `tests`.

## Progress and completion

When the writer provides valid `processed` and `total` counters, the monitor
calculates percentage, rate, ETA, and estimated finish from counter movement.
When it does not, the monitor says `ACTIVE — exact progress unavailable`; it
does not invent a percentage or ETA. A visible 100% requires both `COMPLETED`
and `artifact_validated: true`.

## GPU telemetry

NVIDIA telemetry is optional (`-EnableGpu`). It is queried only when
`nvidia-smi` is present. CPU-only jobs need no NVIDIA software.

## Status

Version **0.1.0** — experimental but usable. MIT licensed. No remote service,
telemetry, or Python dependency is required.


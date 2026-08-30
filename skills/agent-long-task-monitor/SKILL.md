---
name: agent-long-task-monitor
description: Monitor long-running local builds, tests, benchmarks, data-processing, model, and batch jobs in Windows PowerShell without repeated coding-agent polling. Use when a local task will run about 30+ minutes or has become long-running; verify one read-only monitor, then stop polling to preserve tokens, quota, and context.
license: MIT
compatibility: Windows PowerShell 5.1 or PowerShell 7+ on Windows with local filesystem access; no network, server, database, or cloud telemetry is required.
---

# Agent Long Task Monitor

Use this skill for a long-running local task. The monitor is an independent,
read-only sidecar: it does not start, stop, restart, pause, or kill the target,
and it never changes task-owned status, checkpoints, or artifacts.

The workflow goal is simple: long tasks consume compute, not coding-agent
context. After one genuine health check succeeds, stop polling and let the
human watch the monitor.

## When to use it

Use this skill when a local build, test suite, benchmark, data-processing,
model, conversion, or batch job is expected to exceed about 30 minutes, or has
already become long-running.

## Workflow

1. Establish task-owned, authoritative lifecycle evidence in an
   `agent-long-task-status-v1` JSON document. Read
   [the status protocol](references/STATUS_PROTOCOL.md) before defining the
   writer.
2. Publish exact `processed` and `total` counters only when they are
   authoritative. Otherwise set both to `null`; never derive percentage, rate,
   or ETA from elapsed time or logs.
3. Use `scripts/example_supervisor.ps1` only when it is appropriate for the
   supervisor to own a newly launched child process. For an adopted process,
   its existing owner publishes status.
4. Start the independent monitor with `scripts/start_monitor.ps1`, normally
   using `-VerifyHealth`.
5. Wait at least one full configured refresh interval and perform exactly one
   bounded, real health check with `scripts/test_monitor_health.ps1` (the
   startup helper does this when `-VerifyHealth` is used).
6. Require a fresh heartbeat from the current monitor process and require its
   observed target and supervisor PIDs to match authoritative status.
7. If the check succeeds, stop coding-agent polling. The human watches the
   separate monitor window.
8. Treat terminal success as lifecycle evidence plus artifact validation. A
   vanished process is never success evidence. With valid exact counters,
   numeric 100% additionally requires `COMPLETED` and
   `artifact_validated: true`.

## Commands

From the installed skill root, launch and verify the monitor:

```powershell
.\scripts\start_monitor.ps1 -StatusPath C:\work\status.json -VerifyHealth
```

Run a monitor directly when needed:

```powershell
.\scripts\watch_long_task.ps1 -StatusPath C:\work\status.json
```

See [integration guidance](references/INTEGRATION.md) for supervisor ownership
and [architecture](references/ARCHITECTURE.md) for the separation of task,
monitor, agent, and human roles.

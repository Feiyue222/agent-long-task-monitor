# Agent Long Task Monitor

Stop wasting coding-agent tokens polling long-running local jobs.

Long tasks should consume compute, not coding-agent context. A coding agent may
start a build, benchmark, data conversion, model job, test suite, or other
local command that runs for 30 minutes or several hours. It does not need to
spend that entire time repeatedly asking whether the process is still alive.

Agent Long Task Monitor moves continuous observation into a tiny, independent
local sidecar. The agent verifies the monitor once, then stops polling.

## The problem

```text
WITHOUT

Coding agent starts a 2-hour local job
        |
        v
"Still running?"
        |
        v
"Still running?"
        |
        v
"Still running?"
        |
        v
tokens / quota / context keep being spent
```

## With agent-long-task-monitor

```text
Coding agent
    |
    v
Supervisor owns long-running process
    |
    +--> authoritative status.json
    |
    |
Coding agent starts independent monitor
    |
    +--> human watches progress
    |
    +--> monitor-health.json
    |
Coding agent performs one genuine health check
    |
    v
AGENT STOPS POLLING

Independent monitor continues for the human.
```

## This is not just a progress bar

The PowerShell monitor is only the visible sidecar. The real architecture
separates process ownership, authoritative task lifecycle, human observation,
and coding-agent health verification. The supervisor (when used) owns a target
process; the monitor never does.

After one valid health check, the coding agent stops polling.

The monitor is the implementation. Stopping agent polling is the product.

## Why this exists

This is a workflow problem for long local builds, benchmark suites, data
processing, dataset conversion, model training or inference jobs, batch work,
and integration tests. A two-hour job should not require a two-hour AI
conversation whose main activity is checking whether a process is still alive.

## 30-second demo

The [30-second demo](examples/30-second-demo/README.md) is a recording-friendly
local walkthrough. It publishes real `processed` / `total` counters, starts a
real independent monitor, verifies its health, and finishes with validated
completion evidence.

```powershell
# Terminal 1: run the authoritative demo task (about 24 seconds)
.\examples\30-second-demo\run_demo.ps1

# Terminal 2: start, verify, and then leave the monitor running
.\examples\30-second-demo\start_verified_monitor.ps1
```

When the health check passes, the coding agent stops polling; the monitor keeps
running independently for the human.

## Install as an Agent Skill

The standards-compliant, self-contained bundle lives at
[`skills/agent-long-task-monitor/`](skills/agent-long-task-monitor/).

Install the latest tagged release:

```powershell
# Codex
gh skill install Feiyue222/agent-long-task-monitor agent-long-task-monitor --agent codex --scope user

# Claude Code
gh skill install Feiyue222/agent-long-task-monitor agent-long-task-monitor --agent claude-code --scope user
```

Versionless installation resolves the latest tagged release. For a reproducible
v0.2.0 install, pin the version explicitly:

```powershell
# Codex
gh skill install Feiyue222/agent-long-task-monitor agent-long-task-monitor@v0.2.0 --agent codex --scope user

# Claude Code
gh skill install Feiyue222/agent-long-task-monitor agent-long-task-monitor@v0.2.0 --agent claude-code --scope user
```

`@main` is for development/main testing, not the stable install path.

## Quick start

1. Have the task or a supervisor atomically write a status file following
   [the protocol](docs/STATUS_PROTOCOL.md).
2. Start and verify the independent monitor:

   ```powershell
   .\scripts\start_monitor.ps1 -StatusPath .\status.json -VerifyHealth
   ```

3. After the one health check has passed with a fresh heartbeat from the
   current monitor instance, the coding agent stops polling. The human watches
   the monitor window and reports a terminal result if needed.

See [integration guidance](docs/INTEGRATION.md), [architecture](docs/ARCHITECTURE.md),
the quick examples, and the offline contract tests in `tests`.

## No fake progress

Only authoritative `processed` / `total` counters may produce a percentage,
rate, or ETA. Without them, the monitor says `ACTIVE — exact progress
unavailable`. It never infers completion percentage from elapsed time.

### Strict completion

`processed == total` is not enough. When valid authoritative `processed` /
`total` counters exist, a true numeric 100% requires both `state == COMPLETED`
and `artifact_validated == true`. If exact counters are unavailable, successful
terminal completion may still be shown, but the monitor never invents numeric
100%. Process disappearance is never success evidence.

## Local and read-only

Local-first by design: no server, database, cloud telemetry, or SaaS
requirement. The monitor cannot kill, restart, or pause the target, and it does
not modify status, checkpoints, or artifacts. It reads authoritative task
evidence and writes only its separate monitor heartbeat.

## How it works

```text
AI coding agent --> supervisor (when appropriate) --> target task
                         |
                         +--> authoritative status.json

independent monitor --> reads authoritative status --> monitor-health.json

agent --> one bounded real health check --> stops polling

human --> watches the independent monitor
```

The target does the work. A supervisor is optional and owns a new child only
when it is appropriate to do so. For adopted processes, their existing owner
publishes status. The monitor is intentionally read-only with respect to all
task-owned files.

## Quick examples

```powershell
# Exact counters: percentage, rate, and ETA become available after movement.
.\examples\exact-progress\run_exact_progress.ps1

# Lifecycle only: the monitor explicitly reports unavailable exact progress.
.\examples\no-exact-progress\run_no_exact_progress.ps1

# Failing target: preserves FAILED and native exit code 7.
.\examples\failure\run_failure.ps1
```

For the first two demos, start `watch_long_task.ps1` while the demo is still
running, for example:

```powershell
.\scripts\watch_long_task.ps1 -StatusPath .\examples\exact-progress\status.json
```

## GPU telemetry

NVIDIA telemetry is optional (`-EnableGpu`). It is queried only when
`nvidia-smi` is present. CPU-only jobs need no NVIDIA software.

## Status

Version **0.2.0** — experimental but usable. This release adds the
standards-compliant, self-contained Agent Skill distribution. MIT licensed. No
remote service, telemetry, or Python dependency is required.

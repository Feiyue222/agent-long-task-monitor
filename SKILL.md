---
name: agent-long-task-monitor
description: Monitor long-running local commands without repeatedly polling them from an AI coding conversation.
---

# Agent Long Task Monitor

Use this skill when a local command is expected to run longer than about 30
minutes, or once it crosses that threshold.

1. Determine whether the task can publish authoritative counters. If not, use
   `processed: null` and `total: null`; never infer progress from time or logs.
2. Establish durable task-owned lifecycle evidence in an
   `agent-long-task-status-v1` JSON document. Use the supplied supervisor when
   it is appropriate for the supervisor to own a new child process.
3. Launch the independent monitor with `scripts/start_monitor.ps1`.
4. Wait at least one full monitor refresh interval and run exactly one genuine
   health check. It must verify the monitor is alive, its heartbeat is fresh,
   expected process IDs match, and the authoritative status remains readable.
5. If healthy, stop polling. The human watches the separate monitor window.
6. Evaluate terminal success only from terminal lifecycle plus validated
   artifact evidence. A process disappearance never makes a task pass.

Do not spend conversation quota repeatedly checking a healthy long-running
local process. Ask the human to report the terminal result when interaction is
needed.


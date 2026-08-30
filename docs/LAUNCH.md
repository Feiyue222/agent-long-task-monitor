# One-line description

Stop wasting coding-agent tokens polling long-running local jobs.

# Core idea

Long tasks should consume compute, not coding-agent context.

# Short pitch

agent-long-task-monitor is a small, local PowerShell sidecar for long-running
local work. It lets an agent verify a real monitor once, stop polling, and
leave a human-readable monitor running independently.

# Medium pitch

When an agent starts a long local build, conversion, benchmark, or test suite,
the task should publish authoritative lifecycle evidence instead of inviting a
conversation to keep checking whether a process is alive. This project separates
process ownership, task status, human observation, and monitor health. The
agent performs one bounded health check; after that, the monitor continues for
the human while the agent stops polling.

# Before / after

```text
Before: an agent starts a long job and repeatedly asks whether it is still
running, spending conversation context on observation.

After: the task owns authoritative status; an independent, read-only monitor
refreshes it; the agent verifies the monitor once and stops polling.
```

# Example scenario

A coding agent starts a multi-hour local dataset conversion or benchmark. The
task publishes exact processed and total counts only when it truly has them.
The monitor displays those counters for a human and emits a separate heartbeat.
Once that heartbeat passes a real health check, the agent no longer checks the
job in a loop.

# Key differentiators

- One health check, then stop polling.
- Authoritative progress only; no elapsed-time percentage guesswork.
- Strict completion semantics: counters alone are not success.
- Read-only monitor sidecar for task-owned state.
- Local-first: no server, database, telemetry, or SaaS requirement.

# Not just a progress bar

The visible PowerShell monitor is a sidecar, not the product boundary. It is
paired with authoritative lifecycle evidence and a genuine health check so the
coding agent can stop spending context on observation.

The monitor is the implementation. Stopping agent polling is the product.

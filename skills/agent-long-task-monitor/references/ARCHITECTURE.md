# Architecture

```text
AI agent ──> supervisor ──> target process
                   └──────> authoritative status.json

human <── independent PowerShell monitor <── status.json
                                  └────────> monitor-health.json
```

The target does work. The supervisor may own a child process and records exit
evidence. The monitor is a sidecar: it never starts, stops, or mutates the
target, status, checkpoints, or artifacts. An AI agent launches the monitor,
does one health check after a full refresh interval, requiring a fresh
heartbeat from that monitor instance, then stops polling. The
human keeps the monitor window visible.

## Optional application progress layer

```text
application work events -> strict publisher -> progress.json (Layer 2)
                                             |
human <- PowerShell renderer <- persistent read-only progress consumer
                  |
                  +-> unchanged Layer-1 status/health view
```

Layer 1 remains responsible for process/control state, monitor heartbeat,
artifact validation and exit. Layer 2 carries application-owned operational
progress under [agent-long-task-progress-v1](APPLICATION_PROGRESS_PROTOCOL.md).
The private Python helper retains sequence/scope history and monotonic freshness
state; it is an observer, not a task owner. It exits when the renderer closes
stdin. No helper is needed by existing Layer-1-only users.

Monitor heartbeat != application progress. Application progress != durable
scientific checkpoint. Terminal state != artifact validation. PID alive !=
application making progress. Disagreement between layers remains visible.

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

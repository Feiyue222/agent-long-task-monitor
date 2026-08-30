# 30-second demo

A local, recording-friendly demonstration of the actual contracts: authoritative
counter progress, a read-only monitor heartbeat, one health check, and strict
validated completion. It needs only Windows PowerShell or PowerShell 7+.

Open two terminals in the repository root.

Terminal 1 starts the task (12 real items, two seconds each by default):

```powershell
.\examples\30-second-demo\run_demo.ps1
```

Terminal 2 starts the real monitor and performs its one bounded health check:

```powershell
.\examples\30-second-demo\start_verified_monitor.ps1
```

Important moment:

```text
Health check passes
        -> coding agent stops polling
        -> monitor keeps running for the human
```

The task completes in about 24 seconds. It writes `COMPLETED` only after it
creates and validates its local demo artifact, with `processed == total`.
The terminal monitor then shows its normal close prompt; press Enter when done.

Runtime files are written under `examples/30-second-demo/runtime/` and are not
part of the repository. The demo uses no network, GPU, admin privileges,
Python, external service, or elapsed-time-derived percentage.

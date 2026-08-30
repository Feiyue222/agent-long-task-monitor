# Design principles

- Local only: no network calls, analytics, telemetry, or cloud service.
- Fail closed: a missing process is not a completed task; unreadable status is
  reported rather than guessed.
- Truthful progress: counters are authoritative; time and logs are not.
- Minimal cost: refreshes read one small JSON document and query only supplied
  process IDs. NVIDIA telemetry is opt-in.
- Separation: the monitor writes only its own heartbeat. The optional
  supervisor is the component that may own a target child process.
- Privacy: command arguments are not displayed by default; do not put secrets
  in a status file.


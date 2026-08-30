# Status protocol

`agent-long-task-status-v1` is the authoritative, task-owned JSON document.
The monitor only reads it. Writers should replace it atomically: write a
temporary file in the same directory, then rename it into place.

## Required fields

| Field | Meaning |
| --- | --- |
| `contract_version` | Exactly `agent-long-task-status-v1`. |
| `task`, `stage` | Human-readable task and current stage. |
| `state` | `RUNNING`, `COMPLETED`, `FAILED`, `BLOCKED`, `INTERRUPTED`, or `PAUSED`. |
| `started_at` | ISO 8601 timestamp with offset. |
| `checkpoint_state` | Task-owned checkpoint evidence, if applicable. |
| `artifact_state` | `PENDING`, `VALID`, `MISSING`, or another task-defined result state. |
| `artifact_validated` | Boolean result-artifact validation evidence. |
| `last_error` | Null or a safe human-readable error. |

`processed`, `total`, `unit`, `target_process_id`, and
`supervisor_process_id` are optional. Set both counters to `null` when exact
progress is not structurally available. Do not substitute elapsed time, log
size, or an expected duration.

## Completion rule

`processed == total` is not success. The only condition eligible for a true
100% display is `state == "COMPLETED"` **and**
`artifact_validated == true`. Otherwise the monitor caps the visible value at
99.99% and marks finalization pending.

## Monitor health protocol

The monitor independently writes `agent-long-task-monitor-health-v1` with:

- `monitor_process_id`
- `refresh_count`
- `last_refresh_at`
- `observed_state`
- `observed_target_process_id`
- `observed_supervisor_process_id`
- `observed_processed`
- `observed_total`

This is evidence that the monitor refreshed; it is never task progress or
success evidence.


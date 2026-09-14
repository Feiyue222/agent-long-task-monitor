# agent-long-task-progress-v1

This document is normative. MUST, MUST NOT and SHOULD describe the v1 contract.
The application owns operational work events and publishes them explicitly.
The monitor observes; it MUST NOT infer application progress from process names,
CPU/GPU load, descendants, process liveness or its own heartbeat.

## Two independent layers

Layer 1 retains `agent-long-task-status-v1` and
`agent-long-task-monitor-health-v1`: lifecycle/control evidence, process exit,
monitor heartbeat and artifact validation. Layer 2 is opt-in and additive.
Missing Layer 2 is `NOT_AVAILABLE`, never failure of a Layer-1 task.

- monitor heartbeat != application progress
- application progress != durable scientific checkpoint
- terminal_state != artifact validation
- PID alive != application making progress

`ATOMIC_LATEST_SNAPSHOT` means only an atomically published latest operational
snapshot. It does not assert a scientific checkpoint, resume point, recoverable
state, transaction commit, artifact validation or power-loss durability.
No alert or terminal field authorizes termination, retry, restart or resume.

## Closed snapshot schema

UTF-8 JSON object, at most **16,384 bytes**, including a trailing newline if
present. All fields below are required. Extra fields, duplicate keys, malformed
or partial JSON, BOM, NaN and Infinity MUST be rejected. Object key order is
irrelevant. Integers MUST be JSON integers, never booleans, floats or numeric
strings, except the explicitly typed creation identity value.

| Field | Type and meaning |
| --- | --- |
| `protocol_version` | Exact string `agent-long-task-progress-v1`. |
| `task_id` | Nonempty identifier string. |
| `execution_instance_id` | Nonempty identifier for the authorized application instance. |
| `stream_id` | Nonempty identifier for this single-writer stream. |
| `application_process_id` | Positive integer <= 2^32-1, or null. |
| `application_creation_identity` | Typed object described below, or null paired with null PID. |
| `publication_sequence` | Integer 0..2^63-1; starts at 0 in the reference publisher. |
| `progress_sequence` | Integer 0..2^63-1; starts at 0 before progress. |
| `progress_scope_id` | Nonempty identifier for the counter/denominator scope. |
| `stage` | Application-defined string, or null when unknown. |
| `substage` | Application-defined string, or null when unknown. |
| `state` | `RUNNING`, `PAUSED`, `UNKNOWN` or `TERMINAL`. |
| `completed_units` | Integer 0..2^53-1, or null when unknown. |
| `total_units` | Integer 1..2^53-1, or null when unknown. |
| `unit_name` | String; required when either counter is known, otherwise string or null. |
| `heartbeat_at` | UTC wall-clock timestamp of this publication. |
| `last_progress_at` | UTC timestamp of the last work event, or null before known progress. |
| `started_at` | UTC timestamp fixed for this execution stream. |
| `updated_at` | Same UTC timestamp as `heartbeat_at` for this publication. |
| `monotonic_elapsed_ns` | Integer 0..2^63-1; elapsed application monotonic nanoseconds since stream start. |
| `durability_kind` | Exact string `ATOMIC_LATEST_SNAPSHOT`. |
| `terminal_state` | null, `SUCCEEDED`, `FAILED` or `CANCELLED`. |
| `safe_details` | Bounded closed JSON map described below; empty map is valid. |

Identifiers, stage/substage and units are 1..128 Unicode characters, excluding
C0 controls and DEL. UTC timestamps use
`YYYY-MM-DDTHH:MM:SS[.fraction]Z` or `+00:00`, with 1..7 optional fractional
digits and a valid calendar date/time. Other offsets and naive times are
invalid. With `progress_sequence > 0`, `last_progress_at` MUST be non-null.
Unknown numeric values MUST be null, never a fabricated zero. Actual zero
completed work is valid. Known total requires known completed units.

`application_creation_identity` has exactly `kind` and `value`:

- `{"kind":"WINDOWS_FILETIME","value":"134337832703165233"}` preserves
  raw creation FILETIME exactly. Value MUST be a canonical positive decimal
  string <= 2^64-1, without leading zeros. Never convert it through float.
- `{"kind":"OPAQUE_STRING","value":"platform-bound-token"}` is available
  to consumers with an explicit platform-specific verification policy. It is
  not verified by the built-in Windows query.

PID and creation identity MUST either both be null or both be supplied. A PID
alone never establishes identity. Task, execution, stream, application identity
and `started_at` MUST remain fixed. A replacement application requires a new
execution instance and/or stream and an explicitly reset consumer binding under
the caller's policy. This protocol supplies no authorization for replacement.

## Sequence, scope and terminal invariants

`publication_sequence` increments by one for every successful publication,
including heartbeat-only writes. A consumer may miss intermediate publications
and therefore MUST accept forward jumps. Failed publication does not consume a
publication number. Repeated reads of identical content are duplicates, not new
heartbeats. Same publication number with different content is invalid.

`progress_sequence` increments only for actual work advancement or a defined
forward operational milestone. Coalescing may cause observed jumps. A repeated
stage/substage observation or heartbeat MUST NOT advance it. Publishers MUST
declare the actual event explicitly; a validator cannot establish the physical
truth of a dishonest application's claimed work.

When progress sequence is unchanged, all fields except publication sequence,
heartbeat/updated timestamps and monotonic elapsed MUST remain identical. Those
four fields are the only permitted heartbeat-only differences. Thus conflicting
content at the same progress sequence is rejected while legitimate heartbeat
publication remains valid. Progress and publication sequences MUST NOT regress.

Within a scope, completed units MUST NOT decrease; a known total MUST remain
fixed; a known unit name MUST remain fixed. Known values MUST NOT become null
in that same scope. Unknown total may become known on an explicit operational
event. Completed units MUST remain between zero and known total. A stage change
or local reset that would violate these rules requires a new scope ID. Reusing
a prior scope does not erase its history. The reference validator bounds scope
history at 1,024 IDs per stream and fails closed on exhaustion.

`state == TERMINAL` if and only if `terminal_state` is non-null. Terminal
transition is an immediate final operational milestone. `SUCCEEDED` with a
known denominator requires completed == total for that scope. Unknown final
denominator is permitted. After a terminal snapshot, only identical rereads
are valid; no further publication or restart belongs to that stream. Terminal
success does not validate any artifact or imply a whole-project percentage.

## Atomic single-writer publication

The standard-library reference is `scripts/progress_publisher.py` (Python 3.10+).
Required flow: exclusive same-directory temp -> UTF-8 JSON -> flush -> fsync
where supported -> close -> atomic replacement of latest. Never truncate latest
in place. A pre-replace failure retains the previous valid latest and raises a
bounded error containing no payload. Windows transient replacement failures may
retry the same closed temp at most five attempts, separated by 10 ms; exhaustion
raises an error. No work event is repeated by these publication attempts.

An exclusive `.writer.lock` claims one destination. Calls to one Publisher
object MUST be serial, from its application owner. An existing snapshot or lock
is not silently adopted. A killed writer can leave a lock and temp; these are
not snapshots or resume authority. Recovery/lock removal needs explicit external
ownership policy. The library never kills another writer or automatically resumes.

If the writer is interrupted before replacement, readers see the old complete
snapshot; after replacement, the new complete snapshot. This is not a claim
about sudden power loss or arbitrary network filesystem behavior. Use a local
filesystem supporting atomic same-directory replace. Noncooperating Windows
readers may still cause a bounded sharing error. `read_latest` uses Windows
read/write/delete sharing and bounded reads to cooperate with replacement.

Default heartbeat interval is **5 s**. Default non-transition progress
publication maximum rate is **1 Hz**. Internal work counters may advance faster
and coalesce. Stage/scope transitions and terminal transitions publish
immediately, exempt from this rate cap. The application must call `heartbeat()`
regularly; the publisher does not invent a background application work loop.
After a failed publication, pending work remains available for publication;
retrying `publish(force=True)` retries the snapshot, not the work event.

## Safe details

Only exact built-in JSON types are accepted: null, bool, finite bounded numbers,
short strings, lists and dictionaries. Limits:

- Map at the root; maximum depth 4, maximum 64 total value/container nodes.
- At most 16 entries/elements per map/list.
- Keys match `[A-Za-z][A-Za-z0-9_]{0,47}`.
- Strings at most 256 characters, excluding C0 controls and DEL.
- Numbers have absolute value <= 2^53-1; floats must be finite.
- Recursive containers, bytes, custom objects and subclasses are rejected.

No repr, automatic object conversion or arbitrary serializer fallback is used.
The closed serializer limits accidental bulk payload disclosure; it does not
classify the meaning of allowed short strings. Applications must intentionally
select safe operational details, never secrets or payload contents.

## Consumer time and state

`scripts/progress_consumer.py` accepts optional caller-supplied expected identity
fields. Without them, the first valid snapshot pins a stream (trust-on-first-use).
`BOUND_STREAM` means stable protocol binding, not proof of producer authenticity
or a platform process query. The renderer additionally queries Windows PID plus
exact creation FILETIME using query/synchronization rights. It never enumerates
descendants or substitutes PID-only telemetry for application progress.

Wall-clock times are for audit/display and may move backwards. They MUST NOT be
the sole basis of freshness, elapsed time or rate. Application monotonic elapsed
MUST NOT regress. Equal ticks are permitted for immediate transitions on coarse
clocks; their zero interval cannot produce a rate. Consumers use their own
monotonic clock for time since genuinely new publication/work sequences.

A new consumer treats the first snapshot as a baseline with UNKNOWN freshness.
It requires a higher publication sequence before claiming a new heartbeat and
a higher progress sequence before claiming observed progress. Repeated reads
after a monitor restart never make an old snapshot fresh. The consumer's
no-progress duration is observation-local; it does not invent how long a task
had already been idle before attachment.

Defaults are configurable: expected application heartbeat **5 s**, stale
publication threshold **20 s**, no-progress warning threshold **120 s**.
Thresholds measure operational alerts, not scientific retry or termination
permission. State precedence:

| State | Meaning |
| --- | --- |
| `CONTROL_FAILURE` | Invalid/conflicting input, explicit control failure, or local monotonic regression. Last valid binding is retained; numeric display is suppressed. |
| `PROCESS_EXITED` | Caller/identity-bound control proves original process exited; old progress cannot override it. |
| `UNKNOWN` | No valid snapshot, or startup baseline not yet followed by a new publication. |
| `PROGRESS_STALE` | No higher publication sequence for >= stale threshold, even if Layer 1 says alive. |
| `ALIVE_NO_APPLICATION_PROGRESS` | New application heartbeats were observed and remain fresh, but progress sequence has not advanced for >= warning threshold. Not a deadlock conclusion. |
| `ACTIVE_PROGRESS` | New work sequence has been observed, publication remains fresh and no-progress warning has not elapsed. |

The stale check precedes startup UNKNOWN once the baseline ages out. During the
initial fresh-heartbeat interval before any observed work, state stays UNKNOWN
until either actual progress or the no-progress warning threshold. Terminal
state remains a separate displayed fact, even when process exit/staleness wins.
No state causes automatic termination. Layer-1 and Layer-2 disagreement is
displayed without rewriting either layer.

## Percentage, rate and ETA

For valid known completed/total in one scope, `percent = completed / total`
(fraction 0..1; renderer multiplies by 100). Unknown denominator means null /
UNKNOWN percent. Scope percentages MUST NOT be combined into an overall metric.
Layer-2 scope 100% does not alter Layer-1 artifact validation or completion gates.

Rate requires two accepted observations with actual progress/counter advancement,
same scope, same known fixed denominator, compatible unchanged units and a
strictly positive application monotonic interval. Rate is counter delta divided
by elapsed seconds; ETA is remaining units divided by rate. Otherwise both are
null / UNKNOWN. A new heartbeat-only observation clears the rate/ETA sample.
Stale, unknown, exited or failed control suppresses current rate/ETA. An ETA is
an operational estimate, never a completion guarantee.

## Interfaces and compatibility

`validate` checks one object; `decode` also checks bounded strict JSON;
`Validator.accept` enforces stream history without advancing on rejection.
`Consumer.observe` combines validated snapshots with explicit control state.
Use `read_latest` for bounded concurrent reads. The private renderer bridge
keeps one Consumer alive; monitor restart creates a new conservative baseline.

`watch_long_task.ps1 -ProgressPath <latest.json>` enables the separate view.
`-ProgressPythonExecutable`, `-ProgressStaleSeconds` and
`-NoProgressWarningSeconds` configure its helper. `-ApplicationHeartbeatSeconds`
configures the displayed expected heartbeat interval (default 5); Consumer
exposes the same `heartbeat_seconds` setting. Without ProgressPath, no Python
helper is launched, Layer-1 PassThru/health/status semantics remain unchanged,
and Layer 2 displays NOT_AVAILABLE. Helper failure affects Layer 2 only. Health
output MUST NOT alias either task-owned input. The monitor never writes a
progress file. Supported renderer/emitter hosts: Windows PowerShell 5.1 and
PowerShell 7; private stdio framing handles Framework's BOM without relaxing
the normative snapshot decoder.

See [integration](INTEGRATION.md) for APIs and
[the demo](../examples/application-progress/README.md) for harmless usage.

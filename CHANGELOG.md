# Changelog

## 0.3.0

- Added the opt-in `agent-long-task-progress-v1` Layer 2 for
  application-owned operational work events, stages, authoritative counters,
  application heartbeat, freshness, and no-progress distinction.
- Added an atomic Python 3.10+ publisher and strict consumer validation with
  process identity binding; percentages, rates, and ETAs derive only from
  authoritative application counters.
- Integrated Layer-2 rendering while preserving Layer-1 lifecycle, monitor
  health, artifact validation, and read-only sidecar semantics.
- Synchronized the self-contained Agent Skill bundle with Layer 2 and added
  renderer, protocol, and release validation coverage for Windows PowerShell
  5.1 and PowerShell 7+ where supported.
- Field-tested in a real long-running local workflow in addition to the
  automated contract suite. Layer-1 behavior remains backward-compatible with
  v0.2.0.

## 0.2.0

- Added a standards-compliant, self-contained Agent Skill bundle with runtime
  scripts, reference documents, and the MIT license.
- Added GitHub CLI installation guidance for Codex and Claude Code, bundle
  synchronization/drift protection, and `agent-skills` discovery preparation.
- Added the 30-second demo and clarified the project's long-task observation
  workflow and strict completion messaging.

## 0.1.0 - 2026-08-31

- Initial experimental release of the local PowerShell monitor, status protocol,
  supervisor example, health check, examples, and offline contract tests.
- Hardened release-candidate contracts: independent health paths, current and
  fresh monitor heartbeats, validated counters, and explicit command evidence.

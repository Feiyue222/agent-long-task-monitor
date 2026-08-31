# Agent Skill distribution

The v0.2.0 canonical installable skill is
[`skills/agent-long-task-monitor/`](../skills/agent-long-task-monitor/).

There is intentionally no repository-root `SKILL.md`. GitHub CLI discovery
also treats a root `SKILL.md` as an installable skill; during validation it
reported `invalid skill name "小监控"`. Keeping a root compatibility pointer
would therefore create an unintended duplicate and prevent `gh skill publish
--dry-run` from validating the canonical bundle.

Use the canonical bundle for installation and maintenance. Its runtime scripts,
reference documents, and MIT license are self-contained and synchronized by
`scripts/sync_skill_bundle.ps1`.

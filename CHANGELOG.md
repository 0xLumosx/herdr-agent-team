# Changelog

All notable changes to this project are documented here.

## Unreleased

### Added

- Prefixed Herdr team names for multiple concurrent three-agent teams.
- Runtime Planner identity derivation and same-team dynamic routing.
- Team-aware startup, diagnostics, communication tests, and collision checks.
- Multi-team routing and isolation test coverage.
- Multi-team documentation and examples.
- Git worktree guidance for concurrent tasks in one repository.
- Simplified Chinese README and documentation.

### Changed

- Planner no longer assumes that downstream agents use the generic live names
  `coder` and `reviewer`.
- The Coder template now recommends `gpt-5.6-luna` with `high` reasoning while
  keeping model selection user-configurable and workflow-independent.

### Backward compatibility

- Exact legacy live names `planner`, `coder`, and `reviewer` remain supported.
- Installation still manages only the three reusable Codex profiles.

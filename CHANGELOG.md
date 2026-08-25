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
- Fail-closed shared-worktree startup preflight for other live Herdr role agents.
- Strict string-type validation for live role identity and cwd evidence, so
  malformed numeric or boolean agent kinds cannot bypass that preflight.
- Installed prompt and normalized profile-policy SHA-256 integrity checks in
  install, doctor, and startup, while leaving model selection configurable.
- Correlated normal handoffs with stable task, round, and per-handoff IDs.
- Adversarial live `policy` mode for bounded role-boundary evidence.
- Multi-round `full` evidence contracts that validate consecutive correlated
  `CHANGES_REQUIRED` rounds followed by one final `PASS` through round 4.
- Repeatable `--add-dir` startup and doctor support for one Team working across
  multiple disjoint project roots, including explicit degraded-evidence support
  for non-Git directories.
- Complete managed-root-set collision checks across primary and additional
  Git-backed or non-Git scopes.

### Changed

- Prefixed workspace labels now use `codex-team:<team>` without repeating the
  project directory; legacy labels remain `codex-team:<project>`.
- Planner no longer assumes that downstream agents use the generic live names
  `coder` and `reviewer`.
- The Coder template now recommends `gpt-5.6-luna` with `high` reasoning while
  keeping model selection user-configurable and workflow-independent.
- Normal Coder and Reviewer responses now echo `TASK_ID`, `ROUND`, and
  `HANDOFF_ID`; Planner fails closed before interpreting a mismatched response.
- Managed role launches clear inherited
  `sandbox_workspace_write.writable_roots` and apply the role's explicit
  sandbox. Planner/Coder receive only the requested additional writable roots;
  read-only Reviewer receives no `--add-dir`. Doctor verifies this role-specific
  policy from foreground process arguments.
- Git worktrees are no longer a startup prerequisite. Existing non-Git
  directories work in both single-root and multi-root mode with explicit
  degraded-evidence warnings.
- Non-Git roots now use best-effort touched-path evidence with explicit
  `Git evidence: NOT AVAILABLE` limits. Git-hosted `full` and `policy` remain
  `NOT RUN` when the primary cwd is non-Git; routing-only modes do not claim
  filesystem or Git isolation.

### Backward compatibility

- Exact legacy live names `planner`, `coder`, and `reviewer` remain supported.
- Installation still manages only the three reusable Codex profiles.

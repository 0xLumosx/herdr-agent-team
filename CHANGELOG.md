# Changelog

All notable changes to this project are documented here.

## Unreleased

### Added

- Select Codex, Claude Code, or Antigravity independently for each role. Role handoffs preserve task text and leave plugin handling to the native CLI.
- Managed launches link the three native conversations. Resuming a registered Planner chat switches its Coder and Reviewer and verifies both before handoff. The team's SSH host and directory follow the selected conversation.

- Prefixed Herdr team names for multiple concurrent three-agent teams.
- Runtime Planner identity derivation and same-team dynamic routing.
- A required Planner-only stdio MCP bridge with bounded `inspect_team` and
  role-only `prompt_agent` tools, avoiding Linux Codex shell-sandbox AF_UNIX
  failures without granting arbitrary Herdr or filesystem operations.
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
- A versioned, user-local latest-launch record for each Team, written with
  atomic same-directory replacement and including per-invocation correlation,
  root scope, Herdr workspace/pane IDs, role names, and expected sandboxes
  without storing task, transcript, source, or conversation content.
- Record-backed short-form Doctor diagnostics that fail closed on unsafe state;
  explicit `--cwd` continues to bypass recorded workspace/pane binding for a
  direct live-scope check.
- An owner-checked, short-lived same-`CODEX_HOME` managed-start lock with
  conservative same-host stale-owner recovery, closing concurrent
  current-helper check/create races without claiming a filesystem lease or
  Herdr-wide lock.
- Pinned-source OMX architecture comparison and launch-state documentation in
  English and Simplified Chinese.
- A create-or-reuse `open.sh` entry and an SSH `remote.sh` launcher that keeps
  the Herdr UI local while running the fixed three-agent workflow and project
  file access in one version-checked remote named session. The launcher streams
  the current policy bundle instead of requiring a second checkout, verifies
  the detached server identity before Team operations, and binds recorded
  workspace/pane expectations when verifying a current live Team. An explicit
  `--repair-profiles` path backs up and refreshes drifted remote profiles only
  while the selected named session has no live Agent. Remote setup requests
  Herdr live handoff, and Codex integration hook/config installation now
  requires explicit approval before mutation.

### Changed

- The English and Chinese quick starts are shorter and now separate local,
  multi-root, remote, manual-attach, detach, workspace-close, and named-session
  stop/delete flows. Detach guidance now uses the correct lowercase `q` key.
- All three managed roles now enable command networking through role-specific
  Codex permission profiles so ordinary SSH can open outbound TCP connections.
  Planner and Reviewer extend `:read-only`; Coder extends `:workspace` and
  remains the only role that can write additional roots. Planner and Coder
  receive `--add-dir` so both project roots are visible to orchestration and
  implementation; Reviewer stays on the primary root. Startup and Doctor inspect
  the effective model-visible filesystem/network policy and reject legacy
  `--sandbox` argv or incompatible permission resolution.
- All three managed Codex role profiles now set `agents.enabled = false`, and
  startup repeats that setting as an exact CLI override. This removes Codex's
  native collaboration tools so `/root/*` workers cannot substitute for the
  visible same-team Herdr Agents. Static tests inspect rendered prompt input,
  while startup and Doctor reject live role processes missing the override.
- The read-only Reviewer profile now makes ordinary Python test runs avoid
  pytest's file-backed default capture, cache writes, and Python bytecode
  writes. Tests or plugins that inherently require writable temporary storage
  remain an explicit validation limitation instead of weakening the sandbox.
- Prefixed workspace labels now use `codex-team:<team>` without repeating the
  project directory; legacy labels remain `codex-team:<project>`.
- Planner no longer assumes that downstream agents use the generic live names
  `coder` and `reviewer`.
- The Coder template now recommends `gpt-6.2-sol` with `xhigh` reasoning while
  keeping model selection user-configurable and workflow-independent.
- Normal Coder and Reviewer responses now echo `TASK_ID`, `ROUND`, and
  `HANDOFF_ID`; Planner fails closed before interpreting a mismatched response.
- Planner now runs under a hard `read-only` filesystem permission profile and
  communicates through the managed bridge. Planner and Coder receive requested
  `--add-dir` roots as read-only and writable context respectively; Reviewer
  remains on the primary root. Doctor verifies profile, bridge, effective
  permission state, and foreground argv integrity.
- Git worktrees are no longer a startup prerequisite. Existing non-Git
  directories work in both single-root and multi-root mode with explicit
  degraded-evidence warnings.
- Non-Git roots now use best-effort touched-path evidence with explicit
  `Git evidence: NOT AVAILABLE` limits. Git-hosted `full` and `policy` remain
  `NOT RUN` when the primary cwd is non-Git; routing-only modes do not claim
  filesystem or Git isolation.
- Managed recovery now distinguishes saved launch expectations from live
  authority: Herdr remains the sole owner of live identity and prompt
  transport, while the local record never becomes task/workflow state or
  restores a conversation. The fixed Planner/Coder/Reviewer architecture does
  not add an OMX-style scheduler, mailbox, or automatic per-role worktrees.
- Herdr 0.8.2 Agent payloads that omit the settled-only `launch_pending` field
  no longer produce a false `START_PARTIAL`. An absent field is treated as not
  pending; a present non-boolean value and an explicit `true` still fail closed.

### Backward compatibility

- Exact legacy live names `planner`, `coder`, and `reviewer` remain supported.
- Installation still manages only the three reusable Codex profiles, plus one
  shared Planner bridge independent of Team prefix.

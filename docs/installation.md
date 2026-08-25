# Installation

[简体中文](zh-CN/installation.md)

## Before you install

Use a normal user account. Do not run the scripts with `sudo`. The installer writes role profiles under the current user's Codex home and should not need system-wide access.

The compatibility contract is the required CLI surface. The development host was inspected with:

```text
herdr 0.8.2
codex-cli 0.147.0
```

These versions are a known inspection baseline as of 2026-08-24, not exact pins. `doctor.sh` and `start.sh` also verify the commands they rely on so an incompatible newer binary fails early.

## 1. Verify the base tools

```bash
codex --version
codex --help
herdr --version
herdr --help
```

Codex must support `--profile` files at `$CODEX_HOME/<name>.config.toml`. Herdr must expose its `status`, `workspace`, `pane`, and `agent` command groups. Authenticate Codex using its normal supported login flow before starting the team. `doctor.sh` and `start.sh` perform the detailed command-surface checks; `install.sh` first confirms that both binaries exist and reports their versions.

Startup, diagnostics, and live tests also require a real JSON parser. Install
`jq`, or keep Python 3 available as the standard-library fallback. The full
workflow demo always requires Python 3 because it runs independent assertions.

Herdr's official setup guidance is at <https://herdr.dev/agent-guide.md>. Codex's official profile-file behavior is documented in the [configuration reference](https://developers.openai.com/codex/config-reference/).

## 2. Inspect the repository

```bash
cd /path/to/herdr-codex-team
git status --short
```

Read the profile templates and role prompts before installing them, especially:

```text
profiles/planner.config.toml
profiles/coder.config.toml
profiles/reviewer.config.toml
prompts/planner.md
prompts/coder.md
prompts/reviewer.md
```

Do not copy private settings, API keys, provider endpoints, or machine paths into the repository templates.

## 3. Install the profiles

```bash
./scripts/install.sh
```

Optionally choose role models at installation time without editing repository templates:

```bash
PLANNER_MODEL="<available-model>" \
CODER_MODEL="<available-model>" \
REVIEWER_MODEL="<available-model>" \
./scripts/install.sh
```

Each variable is independent; leave one unset to keep that template's model setting.

Unless `CODEX_HOME` is already set, the destination is `~/.codex`. The installed files are:

```text
~/.codex/planner.config.toml
~/.codex/coder.config.toml
~/.codex/reviewer.config.toml
```

If any destination exists, the installer first copies it to a timestamped backup directory such as:

```text
~/.codex/herdr-codex-team-backup-20260824-153000/
```

The base `~/.codex/config.toml` remains in place. It continues to supply account, provider, and other user-level settings; a role profile is layered on top when selected.

These are the only three profiles installed even when you run many teams.
`github-coder` and `auth-coder`, for example, both select the generic `coder`
profile. Team identity belongs to the Herdr live name, not a copied profile.

Re-running the installer is safe with respect to pre-existing profiles because
each conflict is backed up first. It is not a merge operation. Review the
printed backup, but restore only a top-level `model = ...` assignment directly
to an installed role file. Reasoning, sandbox, approval, and role instructions
are managed fields: apply an intentional change to the repository template,
run the static checks, and reinstall. Keep credentials, provider endpoints, and
private machine paths in user-local configuration rather than repository
templates.

## 4. Review Herdr integration and hooks

Check the integration state:

```bash
herdr integration status
```

If the scripts report that the Codex integration is missing, review Herdr's current help and official instructions before running the command they recommend. On the inspected Herdr 0.8.2 command surface, the relevant integration command group is:

```bash
herdr integration install codex
```

An integration may add or change Codex hooks. Codex can then show a warning such as `1 hook is new or changed`. Do not bypass that warning blindly. Review the hook file, confirm that it came from the Herdr installation you intended, understand what it executes, and trust it only after that review. The installer intentionally does not force hook trust.

## 5. Run diagnostics before startup

```bash
./scripts/doctor.sh
```

Before a team exists, binary and profile checks should pass while live-agent
checks may correctly report that the requested names are absent. Use
`doctor.sh` for legacy names or `doctor.sh --team <prefix>` for a prefixed team.
It exits nonzero in that pre-start state; use its messages to distinguish an
expected missing team from a binary, profile, or integration problem.

## Start the team

### 1. Enter the target repository through Herdr

```bash
cd /absolute/path/to/your-project
herdr
```

Herdr injects `HERDR_ENV=1` and pane/workspace identifiers into managed panes. From a shell pane, you can verify:

```bash
test "${HERDR_ENV:-}" = 1 && echo "inside Herdr"
```

The startup script creates a new workspace with explicit returned identifiers and does not depend on the UI-focused pane. If you invoke it from an ordinary external shell, first confirm that `herdr status server` reaches the intended local Herdr server.

### 2. Run the startup helper

For a prefixed team:

```bash
/absolute/path/to/herdr-codex-team/scripts/start.sh \
  --team github \
  --cwd "$PWD"
```

The interface is:

```text
start.sh [--no-focus] [--team PREFIX] [--cwd PROJECT_DIR] [PROJECT_DIR]
```

`PROJECT_DIR` defaults to the current directory and must be inside a Git
worktree. The positional form remains for backward compatibility; do not supply
it together with `--cwd`. `--no-focus` asks startup to preserve the current
focus. `--team github` produces `github-planner`, `github-coder`, and
`github-reviewer`. Omitting it preserves legacy `planner`, `coder`, and
`reviewer` names.

`TEAM_PREFIX=github` is an environment alternative. If the environment and
`--team` both specify a value, they must agree. Startup validates the three
generated names and checks all of them for collisions before creating a
workspace. On a collision such as `agent_name_taken`, it stops without
renaming, deleting, or replacing the existing team.

Run another unique prefix to create a concurrent team:

```bash
/absolute/path/to/herdr-codex-team/scripts/start.sh \
  --team auth \
  --cwd /absolute/path/to/another-project
```

Different repositories can safely use different `--cwd` paths. Two tasks in
one repository should use separate branches and Git worktrees before startup;
the helper does not create, merge, or remove them. See
[Multi-team isolation](multi-team.md).

For one run, model environment variables add a Codex `--model` override for the corresponding role without rewriting installed files:

```bash
PLANNER_MODEL="<available-model>" \
CODER_MODEL="<available-model>" \
REVIEWER_MODEL="<available-model>" \
/absolute/path/to/herdr-codex-team/scripts/start.sh \
  --no-focus --team github --cwd "$PWD"
```

Startup is successful only when:

```bash
herdr agent list
```

shows the three exact requested live names. For `--team github`, those are
`github-planner`, `github-coder`, and `github-reviewer`; in legacy mode they are
`planner`, `coder`, and `reviewer`. Three panes that merely contain a process of
kind `codex` do not satisfy the naming requirement.

This confirms process startup, not the whole security posture. Before sending
work, run the team-aware doctor to verify installed sandbox/approval settings,
profile load, integration, exact identity, readiness, lifecycle state,
workspace/pane/cwd association, and foreground `--profile <role>` arguments. A
working agent is reported as a warning; communication tests require all
relevant targets to be settled at `idle` or `done` and bound to the matching
generic role profile.

### Verified manual primitives

If automation stops, use the current binary's `--help` before applying a manual recovery. Herdr 0.8.2 exposes these primitives:

For prefixed teams, the workspace label is intentionally kept short as
`codex-team:<team>`; the live agent names and `--cwd` retain the role and project
identity. Legacy mode continues to use `codex-team:<project>`.

```bash
# Create an isolated workspace and read its root pane ID from the JSON response.
herdr workspace create --cwd "$PWD" --label "codex-team:github" \
  --env "CODEX_HOME=${CODEX_HOME:-$HOME/.codex}" --no-focus

# Split only panes returned by the preceding commands.
herdr pane split <root-pane-id> --direction right --ratio 0.5 --cwd "$PWD" \
  --env "CODEX_HOME=${CODEX_HOME:-$HOME/.codex}" --no-focus
herdr pane split <right-pane-id> --direction down --ratio 0.5 --cwd "$PWD" \
  --env "CODEX_HOME=${CODEX_HOME:-$HOME/.codex}" --no-focus

# Start a supported Codex process in an existing shell pane.
herdr agent start github-planner --kind codex --pane <planner-pane-id> -- --profile planner
herdr agent start github-coder --kind codex --pane <coder-pane-id> -- --profile coder
herdr agent start github-reviewer --kind codex --pane <reviewer-pane-id> -- --profile reviewer
```

`agent start` requires the target pane to be at an interactive shell prompt. It does not create the pane. Agent-native arguments belong after `--`.

If you are repairing an agent you own and have positively identified its pane,
Herdr 0.8.2 supports:

```bash
herdr agent rename <agent-name-or-pane-id> github-planner
```

Use the exact same-team Coder or Reviewer name for the other roles. Names must
be unique. Never rename an agent belonging to another team to resolve a
collision. Do not derive pane IDs from sidebar order; copy them from Herdr's
JSON response or `herdr pane list`.

### 3. Re-run diagnostics

The interface is:

```text
doctor.sh [--team PREFIX] [--cwd PROJECT_DIR]
```

```bash
/absolute/path/to/herdr-codex-team/scripts/doctor.sh \
  --team github \
  --cwd "$PWD"
```

Now binary, on-disk profile, foreground profile binding, runtime, name, and state checks should all have enough live data to evaluate. If the platform cannot expose foreground process arguments, diagnostics fail closed instead of treating a renamed stale session as a valid role.

### 4. Establish communication evidence

The interface is:

```text
test.sh [--team PREFIX] [--against-team PREFIX] static|ping|communication|full|policy|isolation
```

```bash
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github ping
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github communication
```

Invoke these while the shell remains in the same Git project passed to `start.sh`. Watch the live panes during the test. A Planner-generated claim that Coder responded is not enough if the Herdr Coder pane never receives input or changes lifecycle state.

For the `full` and `policy` tests, the current directory is also the default
host for their nested disposable fixtures:

```bash
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github full
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github policy
```

If the shell must be elsewhere, set `HERDR_TEST_PROJECT_DIR=/absolute/path/to/the-project-used-by-start.sh`. The script validates that the entire host Git worktree has a committed `HEAD` and is clean before it creates the nested fixture; use a disposable worktree rather than hiding or stashing changes merely to satisfy the test.

When two prefixed teams are live and settled, test cross-team isolation from
both directions:

```bash
/absolute/path/to/herdr-codex-team/scripts/test.sh \
  --team github --against-team auth isolation
/absolute/path/to/herdr-codex-team/scripts/test.sh \
  --team auth --against-team github isolation
```

`--against-team` is required only for `isolation`. If two real teams are not
available, report this check as `NOT RUN`; static name parsing is not live
routing evidence.

## Updating a profile

For a model-only change, prefer the documented `PLANNER_MODEL`, `CODER_MODEL`,
or `REVIEWER_MODEL` override. A direct installed-file edit is supported only
for the top-level `model = ...` assignment, which is excluded from the managed
policy digest.

For reasoning, sandbox, approval, or role-instruction changes, edit the
matching source under `profiles/` or `prompts/`, run `test.sh static`, then run
`install.sh`. `doctor.sh` and `start.sh` reject direct installed-file drift in
those managed fields. Exit and restart the affected Codex session after either
kind of persistent change:

```bash
codex --profile planner
```

An already-running session does not automatically reload profile changes.
Re-running `install.sh` replaces all three installed role files after backing
them up.

## Static verification and uninstall

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static
```

The static mode checks required files, shell syntax, role guardrails, install rendering and backup behavior, recoverable uninstall behavior, and whether current Codex can load every rendered profile without contacting live agents. On Codex CLI 0.147.0 the load smoke test uses `codex --profile <role> debug prompt-input`; it is a configuration-load check, not a live agent/model test or a strict guarantee that every unknown field would be rejected.

To uninstall the profiles:

```bash
./scripts/uninstall.sh
```

The uninstall scope is intentionally narrow: project-installed role profiles are moved to a fresh timestamped backup. It does not uninstall Codex or Herdr, remove credentials, delete the base Codex configuration, remove unrelated hooks, or delete backup directories.

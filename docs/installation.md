# Installation

[简体中文](zh-CN/installation.md)

## Before you install

Use a normal user account. Do not run the scripts with `sudo`. The installer writes role profiles under the current user's Codex home and should not need system-wide access.

The compatibility contract is the required CLI surface. The development host was inspected with:

```text
herdr 0.8.2
codex-cli 0.149.1
```

These versions are a known inspection baseline as of 2026-08-25, not exact pins. `doctor.sh` and `start.sh` also verify the commands they rely on so an incompatible newer binary fails early.

## 1. Verify the base tools

```bash
codex --version
codex --help
herdr --version
herdr --help
git --version
```

Codex must support `--profile` files at `$CODEX_HOME/<name>.config.toml`. Herdr must expose its `status`, `workspace`, `pane`, and `agent` command groups. Git CLI is required for conservative scope discovery even when the requested project directories are non-Git. Authenticate Codex using its normal supported login flow before starting the team. `doctor.sh` and `start.sh` perform the detailed command-surface checks; `install.sh` first confirms that Codex and Herdr exist and reports their versions.

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

### Remote mode: local UI, remote agents and files

Do not use SSHFS to make the project look local. This mode uses Herdr's SSH
thin client: only the TUI is rendered locally; the remote Herdr server owns the
panes, three Codex processes, and project files. Every `--cwd` and `--add-dir`
below is therefore an absolute path on the remote host.

Locally, install Herdr, OpenSSH, and `tar` and keep this repository checkout.
Remotely, provide Codex, Bash, Git, `tar`, `jq` or Python 3, and one of
`sha256sum`, `shasum`, or `openssl`. The remote project directory must already
exist and be accessible to the SSH user.

Complete only the remote Codex login first. Prefer device auth on a headless
SSH host:

```bash
# Remote: install and authenticate Codex. No herdr-codex-team checkout is needed.
ssh my-server
codex login status || codex login --device-auth
exit
```

Then use the same local command to create the Team or continue a still-live
conversation:

```bash
cd /path/to/local/herdr-codex-team
./scripts/remote.sh \
  --host my-server \
  --team dex \
  --cwd /home/REMOTE_USER/Dex_Teleop
```

If the remote Herdr binary needs its first install/update, or an existing named
server is incompatible with that binary, `remote.sh` first opens Herdr's
supported setup/update flow. When it is ready, press `Ctrl+B` and then `Q`; the
same script continues automatically without a second command. It then
selects the remote session named `dex`, streams the fixed current launcher
files into a private remote temporary directory, runs the `open.sh`
create-or-reuse decision, removes that directory, and launches the local thin
client. A second remote checkout is not required and cannot drift from the
local launcher. The remote Codex home is explicitly `$HOME/.codex`; when all
three managed profiles are absent, their first install happens automatically.
If the Herdr Codex integration is missing or outdated, the same command shows
the hook/config mutation boundary and waits for one explicit `y`; only then
does it install and continue. Existing or partial profile sets are never
overwritten by this convenience path.

The setup/update attach explicitly requests Herdr `--handoff` so a binary
handoff can preserve live pane processes when supported. This is not an
unconditional guarantee: if Herdr says it must stop/restart the old server and
the live conversation still matters, do not approve that stop. Exit while
leaving the current server intact, then inspect the version and handoff
failure.

Only when the launcher explicitly reports missing or drifted profiles and no
Agent is live in the named session, add one repair flag to the same command:

```bash
./scripts/remote.sh --repair-profiles \
  --host my-server \
  --team dex \
  --cwd /home/REMOTE_USER/Dex_Teleop
```

That flag runs `install.sh`, backing up existing managed profiles before
replacing them from the current launcher. It refuses to modify shared profiles
while any Agent remains live in the selected session. Normal creation and
daily continuation do not need this flag.

For daily shutdown, press `Ctrl+B` and then `Q` to detach the Herdr client; do
not stop the remote server or exit the three agents. The same `remote.sh`
invocation then prints `TEAM_REUSED` for a complete live team that passes
Doctor. When a launch record exists, Doctor also binds the original workspace
and pane IDs instead of trusting names alone. This excludes a different
pane/workspace, but the record contains no PID or conversation ID and cannot
prove prior conversation continuity by itself. It prints `TEAM_CREATED` when
all three names are absent, `TEAM_PARTIAL` for 1/3 or 2/3, and `TEAM_UNSAFE` when
all names exist but managed validation fails. The latter two states never stop,
overwrite, or fill in agents automatically. Their UI opens for inspection, but
the command ultimately exits nonzero; that is not a successful resume.

This simplification covers the common case of closing a local window and
continuing later. After a real remote-host or Herdr-server restart, Herdr 0.8.2
may attempt a native `codex resume`, but that does not replay every managed
launch argument from this project. Conversation text may return while
`doctor.sh` still correctly rejects the process. The launch record verifies
identity; it does not store or restore conversations. The launcher does not
weaken profile, sandbox, or root validation to manufacture a successful result.

### 1. Enter the primary project directory through Herdr

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
  --cwd /absolute/path/to/primary-project \
  --add-dir /absolute/path/to/second-project
```

The interface is:

```text
start.sh [--no-focus] [--team PREFIX] [--cwd PROJECT_DIR] [--add-dir DIR]... [PROJECT_DIR]
```

`PROJECT_DIR` defaults to the current directory and becomes the primary Herdr
workspace and pane cwd. The positional form remains for backward compatibility;
do not supply it together with `--cwd`. `--add-dir` is repeatable and gives
Planner and Coder the requested additional writable roots. Reviewer remains
`read-only` and is launched without `--add-dir`. Every supplied directory must
exist, resolve safely, differ from `/`, and be physically disjoint from every
other requested root. `--no-focus` asks startup to preserve the current focus.
`--team github` produces `github-planner`, `github-coder`, and
`github-reviewer`. Omitting it preserves legacy `planner`, `coder`, and
`reviewer` names.

After Herdr returns a workspace ID, startup writes one private, atomic launch
record under
`$CODEX_HOME/herdr-codex-team/state/v1/teams/{legacy|prefixed-<team-prefix>}/current.json`.
It records a per-invocation `run_id`, ordered roots, exact live names, workspace/pane
IDs, and the latest startup observation (`starting`, `partial`, or `ready`). A
`partial` record means a workspace may have been left for diagnosis; inspect it
instead of rerunning startup blindly. The record contains no task or
conversation state. See [Launch state](launch-state.md).

A Git worktree is not a startup prerequisite. Existing non-Git directories are
accepted in both single-root and multi-root mode. The Git CLI remains required
for conservative worktree-scope discovery. For each non-Git root, `git status`,
complete diffs, untracked-file enumeration, rollback, and pre-existing-change
attribution are unavailable. The agents must label that Git evidence
`NOT AVAILABLE` rather than infer it from direct file inspection.

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

Different repositories can safely use different root sets. Every primary and
additional root of concurrent teams must be disjoint after physical path and
Git-worktree resolution. Two tasks in one repository should use separate
branches and Git worktrees before startup; the helper does not create, merge,
or remove them. See [Multi-team isolation](multi-team.md).

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
work, run the team-aware Doctor. `doctor.sh --team github` loads the saved
launch expectations when available; the explicit same-`--cwd`, ordered
`--add-dir` form performs a direct scope check and bypasses recorded
workspace/pane binding. Doctor verifies installed sandbox/approval settings, profile load,
integration, exact identity, readiness, lifecycle state, workspace/pane/cwd
association, the foreground `--profile <role>` binding, the managed empty
`sandbox_workspace_write.writable_roots` override, the explicit sandbox, and
the role-specific additional-root argv. A working agent is reported as a warning;
communication tests require all relevant targets to be settled at `idle` or
`done` and bound to the matching generic role profile.

### Verified manual primitives

If automation stops, use the current binary's `--help` before applying a manual recovery. Herdr 0.8.2 exposes these primitives:

For prefixed teams, the workspace label is intentionally kept short as
`codex-team:<team>`; the live agent names and `--cwd` retain the role and project
identity. Legacy mode continues to use `codex-team:<project>`.

```bash
# Planner and Coder use this writable root; Reviewer deliberately does not.
EXTRA_ROOT=/absolute/path/to/second-project

# Create an isolated workspace and read its root pane ID from the JSON response.
herdr workspace create --cwd "$PWD" --label "codex-team:github" \
  --env "CODEX_HOME=${CODEX_HOME:-$HOME/.codex}" --no-focus

# Split only panes returned by the preceding commands.
herdr pane split <root-pane-id> --direction right --ratio 0.5 --cwd "$PWD" \
  --env "CODEX_HOME=${CODEX_HOME:-$HOME/.codex}" --no-focus
herdr pane split <right-pane-id> --direction down --ratio 0.5 --cwd "$PWD" \
  --env "CODEX_HOME=${CODEX_HOME:-$HOME/.codex}" --no-focus

# Start supported Codex processes with an exact managed root set.
herdr agent start github-planner --kind codex --pane <planner-pane-id> -- \
  --profile planner -c 'sandbox_workspace_write.writable_roots=[]' \
  --sandbox workspace-write --add-dir "$EXTRA_ROOT"
herdr agent start github-coder --kind codex --pane <coder-pane-id> -- \
  --profile coder -c 'sandbox_workspace_write.writable_roots=[]' \
  --sandbox workspace-write --add-dir "$EXTRA_ROOT"
herdr agent start github-reviewer --kind codex --pane <reviewer-pane-id> -- \
  --profile reviewer -c 'sandbox_workspace_write.writable_roots=[]' \
  --sandbox read-only
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
doctor.sh [--team PREFIX] [--cwd PROJECT_DIR] [--add-dir DIR]...
```

```bash
/absolute/path/to/herdr-codex-team/scripts/doctor.sh --team github

# Explicit scope override for stale/replaced runtime diagnosis:
/absolute/path/to/herdr-codex-team/scripts/doctor.sh \
  --team github \
  --cwd /absolute/path/to/primary-project \
  --add-dir /absolute/path/to/second-project
```

With neither root option, Doctor loads the latest safe launch record for the
requested Team and treats its roots, workspace ID, and pane IDs as expectations
to re-check against Herdr. With explicit roots, pass every additional root in
the same order used by `start.sh`; `--add-dir` requires `--cwd`. The explicit
form bypasses recorded workspace/pane binding without modifying the record.
Doctor validates role-specific argv: Planner and Coder must carry the exact
ordered list, while Reviewer must carry no `--add-dir`. Binary, on-disk profile, foreground
profile/sandbox/root binding, runtime, name, and state checks should then have
enough live data to evaluate. This proves launch argv, not successful reads,
writes, or Git history. If the platform cannot expose foreground process
arguments, diagnostics fail closed instead of treating a renamed stale session
as a valid role.

### 4. Establish communication evidence

The interface is:

```text
test.sh [--team PREFIX] [--against-team PREFIX] static|ping|communication|full|policy|isolation
```

```bash
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github ping
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github communication
```

`ping` and `communication` do not require a Git root; they provide bounded
transport evidence only. Watch the live panes during the test. A
Planner-generated claim that Coder responded is not enough if the Herdr Coder
pane never receives input or changes lifecycle state.

For the `full` and `policy` tests, the current directory is also the default
host for their nested disposable fixtures:

```bash
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github full
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github policy
```

If the shell must be elsewhere, set `HERDR_TEST_PROJECT_DIR=/absolute/path/to/the-project-used-by-start.sh`. The script validates that the entire host Git worktree has a committed `HEAD` and is clean before it creates the nested fixture; use a disposable worktree rather than hiding or stashing changes merely to satisfy the test.

When the primary `--cwd` is non-Git, it cannot be this host: report `full` and
`policy` as `NOT RUN` for that team. If a Git-backed primary is combined with a
non-Git additional root, a passing fixture under the primary does not establish
the non-Git root's baseline, complete change scope, rollback, or writer
attribution.

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
routing evidence. Isolation checks named-agent transcripts and lifecycle
sequences; it does not establish filesystem non-interference across roots.

## Updating a profile

For a model-only change, prefer the documented `PLANNER_MODEL`, `CODER_MODEL`,
or `REVIEWER_MODEL` override. A direct installed-file edit is supported only
for the top-level `model = ...` assignment, which is excluded from the managed
policy digest.

For reasoning, sandbox, approval, or role-instruction changes, edit the
matching source under `profiles/` or `prompts/`, run `test.sh static`, then run
`install.sh`. `doctor.sh` and `start.sh` reject direct installed-file drift in
those managed fields. After either kind of persistent change, preserve the
task context and project changes, close only the requested team's three old
sessions, and recreate that team with the current `start.sh` and its original
root arguments:

```bash
/path/to/herdr-codex-team/scripts/start.sh \
  --team github \
  --cwd /absolute/path/to/primary-project \
  --add-dir /absolute/path/to/second-project
/path/to/herdr-codex-team/scripts/doctor.sh \
  --team github \
  --cwd /absolute/path/to/primary-project \
  --add-dir /absolute/path/to/second-project
```

For legacy mode, omit `--team` from both commands. Plain
`codex --profile <role>` does not reproduce the managed sandbox/root argv and
will fail the managed-process checks. An already-running session does not
automatically reload profile changes. Re-running `install.sh` replaces all
three installed role files after backing them up.

## Static verification and uninstall

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static
```

The static mode checks required files, shell syntax, role guardrails, install rendering and backup behavior, recoverable uninstall behavior, and whether current Codex can load every rendered profile without contacting live agents. On Codex CLI 0.149.1 the load smoke test uses `codex --profile <role> debug prompt-input`; it is a configuration-load check, not a live agent/model test or a strict guarantee that every unknown field would be rejected.

To uninstall the profiles:

```bash
./scripts/uninstall.sh
```

The uninstall scope is intentionally narrow: project-installed role profiles are moved to a fresh timestamped backup. It does not uninstall Codex or Herdr, remove credentials, delete the base Codex configuration, remove unrelated hooks, delete backup directories, or remove user-local launch records.

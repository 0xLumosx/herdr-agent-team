# Troubleshooting

[简体中文](zh-CN/troubleshooting.md)

## Start with evidence

After a managed startup, start with the saved launch expectation:

```bash
./scripts/doctor.sh --team <prefix>
```

This short form loads the safe latest record for that Team from the same
`CODEX_HOME` and binds the check to its recorded workspace, panes, and roots.
Omit `--team` for the legacy `planner`/`coder`/`reviewer` Team.

For a deliberately replaced session, a missing or stale record, or a direct
check of an intended scope, supply the roots explicitly:

```bash
./scripts/doctor.sh --team <prefix> \
  --cwd /path/to/primary-project \
  --add-dir /path/to/second-project
```

Explicit `--cwd` bypasses recorded workspace/pane binding and verifies the
requested live scope directly. Every diagnostic `--add-dir` requires `--cwd`;
repeat the exact ordered list used by `start.sh`. This shortcut applies only to
Doctor: `start.sh` still requires the intended roots through `--cwd`, ordered
`--add-dir`, or its current-directory default.

Inside a Herdr-managed pane, also inspect:

```bash
herdr status --json
herdr agent list
```

Do not infer a healthy team from three terminal panes alone. Record which binary, profile file, live name, pane, and lifecycle state actually exist.

## `agent_name_taken`

A message such as `agent name planner is already used` or an
`agent_name_taken` error means another live agent already owns an exact name
requested by startup. Herdr live names are unique.

Do not force startup, rename the existing agent, or continue with the other two
roles. That would leave an ambiguous or partial team. Choose a unique valid team
prefix instead:

```bash
./scripts/start.sh --team github --cwd /path/to/project
```

This requests `github-planner`, `github-coder`, and `github-reviewer`. If one of
those also exists, choose another prefix or intentionally finish the existing
team before retrying. Startup must never delete, overwrite, or adopt it.

## Planner sent work to the wrong Coder

Likely causes are an old Planner prompt that still hard-codes `coder`, an
unrecognized self-name, or incorrect team-prefix derivation.

Inspect the four routing values Planner is required to establish:

```text
SELF_AGENT
TEAM_PREFIX
CODER_AGENT
REVIEWER_AGENT
```

For `SELF_AGENT=github-planner`, the only valid route is
`CODER_AGENT=github-coder` and `REVIEWER_AGENT=github-reviewer`. Use the current
Herdr inspection commands to verify the exact live names:

```bash
herdr agent list
herdr agent get github-planner
herdr agent get github-coder
herdr agent get github-reviewer
```

Do not infer team membership from pane position, tab, workspace, process kind,
or a hard-coded pane ID. If derivation or exact-target verification fails, the
correct response is `HERDR_COMMUNICATION_FAILED`, even when another team's
Coder is idle and available.

Reinstall the current role prompts, recreate only the requested team through
the current `start.sh`, then run `doctor.sh --team github --cwd <primary>
--add-dir <extra> ...` with the exact ordered startup roots before the
team-aware communication test. Do not accept or merge work produced by the
wrong team without independently inspecting and reconciling all available Git
diffs and reported non-Git touched paths.

## Two Coders changed the same working tree or root

This is a filesystem/Git workspace-scope collision, not a Herdr routing failure.
Exact-name routing and the prompt contract reduce accidental cross-team
messages; they are not an ACL. They also do not prevent `auth-coder` and
`ui-coder` from writing the same files when either team's primary or additional
root overlaps the other team's scope.

Stop issuing new work and preserve both agents' reports plus every available
Git diff and reported non-Git touched-path inventory. For different
repositories, restart the teams with disjoint complete root sets.
For concurrent tasks in one repository, prepare a separate branch and Git
worktree for each team:

```bash
cd /projects/myapp
git worktree add ../myapp-auth -b task/auth
git worktree add ../myapp-ui -b task/ui
```

Then bind each team to its own path. This project does not automatically merge,
remove, or repair worktrees. See [Multi-team isolation](multi-team.md).

## Planner says Coder is working, but the Coder pane is idle

This is the highest-priority failure because it can create false progress.

Likely cause: Planner could not use Herdr and silently created or addressed a
Codex-native/internal subagent, or it derived another team's target instead of
the expected live Herdr Coder.

Check:

```bash
herdr agent list
herdr agent get <expected-team-coder>
herdr agent read <expected-team-coder> --source recent-unwrapped --lines 120
```

Then inspect the Planner profile and confirm that it contains the mandatory
Herdr identity/routing and strict team-isolation rules and explicitly forbids
cross-team routing, native subagents, hidden workers, `/root/coder`,
`/root/reviewer`, and fallback agent systems.

Expected response to failed routing:

```text
HERDR_COMMUNICATION_FAILED
```

Do not accept a generated Coder report unless the named live pane received the prompt and the resulting repository state matches the report.

## `Operation not permitted` from Planner

Planner may be using a `read-only` sandbox that cannot access the local Herdr communication mechanism.

Check the installed file:

```text
~/.codex/planner.config.toml
```

The repository default in `profiles/planner.config.toml` is:

```toml
sandbox_mode = "workspace-write"
```

Keep the Planner developer instructions that prohibit application-source
edits. Restore or intentionally update the repository template, run
`scripts/install.sh`, restart Planner, then re-run `test.sh --team <prefix>
communication` (or the legacy unprefixed form). Directly changing this managed
field in the installed file is rejected by the profile-policy digest.

If the error persists, do not broaden to `danger-full-access`. Inspect the exact denied path, verify that the Herdr integration and hooks are current, and run `herdr agent explain <expected-team-agent>` or the diagnostics printed by the current Herdr version.

For a required second project, restart the team through `start.sh` with an
explicit `--add-dir`; do not add a private machine-wide writable root as a
workaround. Managed startup clears inherited
`sandbox_workspace_write.writable_roots`, applies the explicit role sandbox,
passes the additional writable-root list to Planner/Coder, and deliberately
omits it from read-only Reviewer.

## All agents appear as `codex`

Agent kind and live name are different. `codex` may correctly describe the executable while the required unique names are absent.

Run:

```bash
herdr agent list
```

On Herdr 0.8.2, rename an existing live target that you own and have positively
identified with:

```bash
herdr agent rename <agent-name-or-pane-id> <team-prefix>-planner
herdr agent rename <agent-name-or-pane-id> <team-prefix>-coder
herdr agent rename <agent-name-or-pane-id> <team-prefix>-reviewer
```

Use the actual target returned by Herdr, not sidebar position or a guessed ID.
Names must be unique. Never rename an existing agent from another team to
resolve a collision. Use unprefixed role names only for intentional legacy mode.

## Agent name disappears after restart

In the inspected Herdr 0.8.2 behavior, a live name follows the current pane occupant. It is cleared when the agent exits, is released, or is replaced. A Codex profile does not permanently assign the Herdr name.

After preserving context and project changes, recreate only the requested team
through the current `start.sh` with its original `--team`, `--cwd`, and ordered
`--add-dir` arguments; launch state does not supply roots to `start.sh`. Then
run short-form `doctor.sh --team <prefix>` against the new saved record before
resuming, or use explicit roots for a direct scope check. A plain profile
launch followed by `herdr agent rename` does not reproduce the managed
sandbox/root argv. This is expected runtime lifecycle, not proof that the
profile was lost. Neither the launch record nor a new process restores the old
conversation; only the still-live original pane retains it.

## Profile changes have no effect

Current Codex profile files live beside the base configuration:

```text
~/.codex/planner.config.toml
~/.codex/coder.config.toml
~/.codex/reviewer.config.toml
```

They are selected with `codex --profile <name>`. The managed files include
separate digests for the embedded role prompt and normalized profile policy.
The `model = ...` assignment is deliberately excluded so documented model
selection remains configurable; reasoning, sandbox, approval, and other
policy/template fields are managed. Edit source under `prompts/` or `profiles/`
and rerun `scripts/install.sh`; direct installed-policy edits are rejected by
`doctor.sh` and `start.sh`. An existing Codex session
does not automatically reload a freshly installed profile. Preserve context
and project changes, close only the requested team's old sessions, then
recreate that team through the current `start.sh` with its original root
arguments. Launch state is diagnostic metadata, not an input replay mechanism
for `start.sh`. Verify the replacement with short-form `doctor.sh --team
<prefix>` against its new record, or use explicit roots for a direct check; do
not use a plain profile launch plus rename as a managed restart.

Also check whether `CODEX_HOME` was set differently during installation and startup. A mismatch can make Codex read a different directory.

## `1 hook is new or changed`

A Herdr Codex integration can add or update hooks used for agent-state reporting. A changed hook is executable configuration and deserves review.

1. run `herdr integration status`;
2. locate the hook named by Codex;
3. confirm it belongs to the intended Herdr installation;
4. inspect the command, arguments, and referenced script;
5. trust it only after the source and behavior are acceptable.

Do not use a bypass flag simply to make the warning disappear. If the file changed unexpectedly, stop and compare it with the installed integration or official Herdr guidance.

## `start.sh` cannot reach the Herdr server

The startup helper needs a reachable local Herdr server. Enter the target repository and launch or attach Herdr:

```bash
cd /path/to/project
herdr
```

Run `start.sh` from a shell pane inside that session, or from an external shell after confirming `herdr status server` reaches the intended server. The script creates a new workspace and targets the IDs returned by Herdr; it does not rely on the UI-focused pane.

## Doctor rejects the saved launch record

The short Doctor form reads the Team's `current.json` below
`$CODEX_HOME/herdr-codex-team/state/v1/teams`. An oversized, malformed,
unsupported-schema, symlinked, unsafe-path, or wrong-Team record is rejected
before Doctor contacts Herdr. Preserve the file for inspection; do not edit its
workspace/pane IDs or status to manufacture a healthy result.

To inspect the intended live scope without trusting recorded workspace/pane
binding, use the explicit form:

```bash
./scripts/doctor.sh --team <prefix> \
  --cwd /path/to/primary-project \
  --add-dir /path/to/second-project
```

Explicit roots bypass the record for that Doctor invocation without modifying
it. If the file is missing, the short form can still inspect live Team
identity, but it has no saved multi-root or workspace/pane expectation; use
explicit roots for that evidence. The record is not task, handoff, transcript,
or conversation state and cannot restore a replaced Codex session. Herdr is
still authoritative for which workspace, pane, and Agent are live.

## `start.sh` reports a startup-lock owner

All current `start.sh` processes in the same `CODEX_HOME` share one short-lived
startup lock while they inspect live names/root sets and create the Herdr
workspace and Agents. A valid same-host owner with a live PID means another
managed startup is still in that critical section; let it finish, then inspect
its result before retrying. This is independent of whether the Herdr server is
running.

The next managed startup automatically recovers a well-formed same-host owner
whose PID is dead. A malformed owner or a different/unknown host fails closed
because ownership cannot be proved. Preserve and inspect unexpected lock state;
do not recursively delete the state root. The lock does not stop manual Herdr
commands, older helpers, external writers, or current helpers using a different
`CODEX_HOME`, and it does not reserve project roots after startup.

## Launch state says `partial`

`partial` means `start.sh` created a Herdr workspace but did not complete and
persist a `ready` conclusion. The live roles may still be ready; the record says
nothing about task progress or conversation state. Inspect the recorded
workspace/pane IDs together with `herdr agent list`, `herdr agent get`, and pane
output. Preserve any live processes and project changes while you identify the
failure. Do not blindly rerun startup, stop the workspace, or edit
`current.json` to `ready`; a retry can encounter the still-live names or hide
useful evidence. See [Launch state](launch-state.md).

## Agent is `blocked` or `unknown`

`blocked` means Herdr recognized an approval or question UI. `unknown` means an agent is present but Herdr cannot classify it confidently; it does not prove the work finished.

Inspect before acting:

```bash
herdr agent get <name>
herdr agent read <name> --source recent-unwrapped --lines 120
```

Do not automatically answer approvals or user questions. Bring the visible prompt to the user when it requires authority or a material choice.

## `agent start` fails

Herdr's `agent start` requires an existing pane whose foreground process is an interactive shell at its prompt. It will not split a pane or replace a running editor, server, or agent.

Check the target pane:

```bash
herdr pane process-info --pane <pane-id>
herdr pane read <pane-id> --source recent-unwrapped --lines 80
```

Create or choose a clean shell pane, then retry with the agent's native arguments after `--`:

```bash
herdr agent start <team-prefix>-coder --kind codex --pane <pane-id> -- --profile coder
```

## Ping passes but communication fails

Direct ping proves the external shell can address Coder and Reviewer. It does not prove Planner has Herdr access or follows the no-fallback policy.

Check Planner's sandbox, installed prompt, live name, and pane state. Run:

```bash
/path/to/herdr-codex-team/scripts/test.sh --team <prefix> communication
```

while watching both downstream panes. If Planner only echoes the expected sentinel itself, treat the test as failed.

## Full test cannot run

The full test needs a live three-agent Herdr team, Git, and Python 3 because it verifies a real working-tree change, executes the demo tests, and checks the review loop. Run it only after ping and communication pass:

```bash
/path/to/herdr-codex-team/scripts/test.sh --team <prefix> full
```

The script copies its bundled fixture into `.herdr-codex-test.*` under `${HERDR_TEST_PROJECT_DIR:-$PWD}`, initializes an isolated Git repository there, and removes it after success. Invoke the absolute `test.sh` path while the current directory is the same Git project used by `start.sh`, or set `HERDR_TEST_PROJECT_DIR` to that project explicitly. The script rejects a host outside a Git worktree, without a committed `HEAD`, or whose full worktree is not clean.

If the team's primary cwd is non-Git, this precondition cannot be met for that
team: record `full` as `NOT RUN`. A separate fixture does not create a baseline
or complete diff for the team's non-Git roots. If only an additional root is
non-Git, a full-test pass under the Git-backed primary still says nothing about
the additional root's complete change scope.

The host placement matters: the disposable path must remain inside the live team's workspace-write root. The script preserves the directory after failure for diagnosis; set `KEEP_TEST_WORKSPACE=1` to retain a successful run. Use a clean disposable worktree. If the harness reports a dirty host, inspect and preserve that work yourself; do not ask the test to ignore it.

A pass verifies challenge-derived Coder completion and Reviewer pass responses,
unchanged fixture history, the exact changed-file scope, unchanged host
Git-visible status/branch/`HEAD`, script-owned assertions, fixture test success,
and Planner's run-specific approval. It does not inspect ignored host files or
prove filesystem writer identity because Planner also has `workspace-write`.
Use a disposable host without sensitive ignored files. If hard attribution is
part of your acceptance criteria, the current test is insufficient.

The full test also verifies the normal handoff correlation contract in live
Coder and Reviewer transcripts. It preassigns distinct Coder/Reviewer
`HANDOFF_ID` values for rounds 1 through 4, keeps one stable `TASK_ID`, accepts
consecutive `CHANGES_REQUIRED` rounds followed by one same-round `PASS`, and
rejects reused or unused later-round response tokens. Every used correlation
value must appear both in the received prompt and in the role's exact response
echoes.

The test reads the latest 2000 unwrapped terminal rows by default. If a legitimately verbose run scrolls its final run-specific token out of that window, preserve the fixture and rerun with a larger positive `HERDR_TEST_READ_LINES`; do not treat a larger window as a substitute for watching the named panes.

If an audit session cannot safely address the intended live Herdr server—as was true while this repository was assembled—only static shell/configuration checks can be claimed. The live scripts may be invoked from an external human-operated shell when `herdr status server` resolves the intended server, but live communication remains unverified until those scripts actually run against the named agents.

Run the non-live checks from the team repository checkout with:

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static
```

## Policy test cannot run

After `ping`, `communication`, and `full`, run the adversarial role-boundary
check from the same clean disposable host worktree:

```bash
./scripts/test.sh --team <prefix> policy
```

It sequentially challenges Reviewer, Coder, and Planner, while checking a
baseline-checked nested Git fixture, unchanged peer transcripts/lifecycle sequences,
and unchanged visible Herdr agent names. A phase failure before successful
cleanup preserves the fixture. A pass is bounded behavioral evidence, not an ACL, filesystem audit, or proof
that no hidden native worker ever existed. If the intended live team cannot be
safely addressed, record this mode as `NOT RUN`.

The same Git-host requirement applies here. A team whose primary cwd is
non-Git must record `policy` as `NOT RUN`; do not extrapolate a different
Git-backed fixture's policy result to non-Git project roots.

## Isolation test cannot run

The isolation mode needs two different prefixed teams that are both live,
settled, and bound to their expected generic profiles:

```bash
./scripts/test.sh --team github --against-team auth isolation
```

`--against-team` is required only for this mode. It must differ from `--team`.
Run both directional checks when possible. If the current shell cannot safely
address two real teams, record the live isolation check as `NOT RUN` with that
reason. Passing static name construction, doctor, or a one-team communication
test is not proof that one Planner cannot control the other team's Coder.
It is also not filesystem-isolation evidence for either team's root set.

## `start.sh` rejects the project directory

The startup interface is `start.sh [--no-focus] [--team PREFIX] [--cwd
PROJECT_DIR] [--add-dir DIR]... [PROJECT_DIR]`. `PROJECT_DIR` defaults to the
current directory. Do not combine `--cwd` with the legacy positional path.

A Git worktree is not required in either single-root or multi-root mode; the Git
CLI is still required for conservative scope discovery. Every requested
directory must exist, resolve safely, must not be `/`, and must be disjoint from
the others. Equal, ancestor/descendant, symlink-equivalent, or same-effective-
worktree roots are rejected. Malformed or ambiguous Git metadata also fails
closed instead of being treated as ordinary non-Git evidence.

Check:

```bash
git -C /path/to/project rev-parse --show-toplevel
```

The command above is optional evidence diagnosis, not a startup prerequisite.
For a non-Git project, accept the printed evidence warning. If multiple
existing project directories are intentional, pass each extra one with a
repeatable `--add-dir`. Do not initialize an unrelated directory merely to
silence the warning.

## Doctor reports an additional-root mismatch

After managed startup, first run the short form so Doctor checks the saved
ordered roots and recorded workspace/pane identities together:

```bash
./scripts/doctor.sh --team <prefix>
```

To bypass the recorded workspace/pane binding and diagnose a requested live
scope directly, supply the same primary path and additional roots, in the same
order, that started the Team:

```bash
./scripts/doctor.sh --team <prefix> \
  --cwd /path/to/primary-project \
  --add-dir /path/to/second-project
```

Doctor compares each role's structured process argv, including the generic
profile, explicit sandbox, empty inherited-writable-roots override, and
role-specific additional-root policy. Planner/Coder must carry the exact
ordered list; Reviewer must carry none. A missing, extra, reordered, malformed,
or stale writable root is a failure. A short-form mismatch can also mean the
saved workspace/pane IDs are stale; explicit roots distinguish that case
without modifying the record. Restart all three roles through the current
`start.sh` only after preserving evidence and supplying the intended roots;
do not edit private global configuration or `current.json` to make the mismatch
disappear. A passing Doctor proves launch arguments and, in short form, recorded
identity agreement only—not actual file access or change attribution.

## Doctor reports a missing command on a newer version

Version numbers alone do not prove compatibility. A newer release can rename or remove a command the scripts use.

Run the relevant current help:

```bash
herdr --help
herdr agent --help
herdr pane --help
herdr workspace --help
codex --help
```

Update the script only from observed syntax, then update the documented compatibility baseline. Do not add a guessed command merely because an older example used it.

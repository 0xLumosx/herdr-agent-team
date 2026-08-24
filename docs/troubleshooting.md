# Troubleshooting

## Start with evidence

Run diagnostics from the project checkout:

```bash
./scripts/doctor.sh
```

Inside a Herdr-managed pane, also inspect:

```bash
herdr status --json
herdr agent list
```

Do not infer a healthy team from three terminal panes alone. Record which binary, profile file, live name, pane, and lifecycle state actually exist.

## Planner says Coder is working, but the Coder pane is idle

This is the highest-priority failure because it can create false progress.

Likely cause: Planner could not use Herdr and silently created or addressed a Codex-native/internal subagent instead of the live Herdr Coder.

Check:

```bash
herdr agent list
herdr agent get coder
herdr agent read coder --source recent-unwrapped --lines 120
```

Then inspect the Planner profile and confirm that it contains the mandatory `HERDR COMMUNICATION IS MANDATORY` rule and explicitly forbids native subagents, hidden workers, `/root/coder`, `/root/reviewer`, and fallback agent systems.

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

The project default is:

```toml
sandbox_mode = "workspace-write"
```

Keep the Planner developer instructions that prohibit application-source edits. Restart Planner after changing the profile, then re-run `test.sh communication`.

If the error persists, do not broaden to `danger-full-access`. Inspect the exact denied path, verify that the Herdr integration and hooks are current, and run `herdr agent explain` or the diagnostics printed by the current Herdr version.

## All agents appear as `codex`

Agent kind and live name are different. `codex` may correctly describe the executable while the required unique names are absent.

Run:

```bash
herdr agent list
```

On Herdr 0.8.2, rename an existing live target with:

```bash
herdr agent rename <agent-name-or-pane-id> planner
herdr agent rename <agent-name-or-pane-id> coder
herdr agent rename <agent-name-or-pane-id> reviewer
```

Use the actual target returned by Herdr, not sidebar position or a guessed ID. Names must be unique.

## Agent name disappears after restart

In the inspected Herdr 0.8.2 behavior, a live name follows the current pane occupant. It is cleared when the agent exits, is released, or is replaced. A Codex profile does not permanently assign the Herdr name.

Run `start.sh` again or use `herdr agent rename` after the replacement agent is detected. Then run `doctor.sh` before resuming a task. This is expected runtime lifecycle, not proof that the profile was lost.

## Profile changes have no effect

Current Codex profile files live beside the base configuration:

```text
~/.codex/planner.config.toml
~/.codex/coder.config.toml
~/.codex/reviewer.config.toml
```

They are selected with `codex --profile <name>`. An existing Codex session does not automatically reload changes. Exit the affected session and start it again, then restore its Herdr live name.

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
herdr agent start coder --kind codex --pane <pane-id> -- --profile coder
```

## Ping passes but communication fails

Direct ping proves the external shell can address Coder and Reviewer. It does not prove Planner has Herdr access or follows the no-fallback policy.

Check Planner's sandbox, installed prompt, live name, and pane state. Run:

```bash
/path/to/herdr-codex-team/scripts/test.sh communication
```

while watching both downstream panes. If Planner only echoes the expected sentinel itself, treat the test as failed.

## Full test cannot run

The full test needs a live three-agent Herdr team, Git, and Python 3 because it verifies a real working-tree change, executes the demo tests, and checks the review loop. Run it only after ping and communication pass:

```bash
/path/to/herdr-codex-team/scripts/test.sh full
```

The script copies its bundled fixture into `.herdr-codex-test.*` under `${HERDR_TEST_PROJECT_DIR:-$PWD}`, initializes an isolated Git repository there, and removes it after success. Invoke the absolute `test.sh` path while the current directory is the same Git project used by `start.sh`, or set `HERDR_TEST_PROJECT_DIR` to that project explicitly. The script rejects a host outside a Git worktree, without a committed `HEAD`, or whose full worktree is not clean.

The host placement matters: the disposable path must remain inside the live team's workspace-write root. The script preserves the directory after failure for diagnosis; set `KEEP_TEST_WORKSPACE=1` to retain a successful run. Use a clean disposable worktree. If the harness reports a dirty host, inspect and preserve that work yourself; do not ask the test to ignore it.

A pass verifies challenge-derived Coder completion and Reviewer pass responses, unchanged fixture history, the exact changed-file scope, unchanged host Git-visible status/branch/`HEAD`, script-owned assertions, fixture test success, and Planner's run-specific approval. It does not inspect ignored host files or prove filesystem writer identity because Planner also has `workspace-write`. Use a disposable host without sensitive ignored files. If hard attribution is part of your acceptance criteria, this v0.1 test is insufficient.

The test reads the latest 2000 unwrapped terminal rows by default. If a legitimately verbose run scrolls its final run-specific token out of that window, preserve the fixture and rerun with a larger positive `HERDR_TEST_READ_LINES`; do not treat a larger window as a substitute for watching the named panes.

If an audit session cannot safely address the intended live Herdr server—as was true while this repository was assembled—only static shell/configuration checks can be claimed. The live scripts may be invoked from an external human-operated shell when `herdr status server` resolves the intended server, but live communication remains unverified until those scripts actually run against the named agents.

Run the non-live checks from the team repository checkout with:

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static
```

## `start.sh` rejects the project directory

The startup interface is `start.sh [--no-focus] [PROJECT_DIR]`. `PROJECT_DIR` defaults to the current directory and must resolve inside a Git worktree so every handoff has an objective `git status` and `git diff` surface.

Check:

```bash
git -C /path/to/project rev-parse --show-toplevel
```

Choose the intended repository root or initialize a disposable test repository. Do not bypass the check for a directory whose ownership or uncommitted state you have not inspected.

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

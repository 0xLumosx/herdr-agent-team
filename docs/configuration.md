# Configuration

[简体中文](zh-CN/configuration.md)

## Profile locations and precedence

The repository contains reusable role templates under `profiles/`. The installer places generated role files next to the base Codex configuration:

```text
$CODEX_HOME/config.toml
$CODEX_HOME/planner.config.toml
$CODEX_HOME/coder.config.toml
$CODEX_HOME/reviewer.config.toml
```

If `CODEX_HOME` is unset, it defaults to `~/.codex`.

Current Codex CLI layers `$CODEX_HOME/<name>.config.toml` over the base user configuration when launched with:

```bash
codex --profile <name>
```

This is separate-file profile behavior, not a `[profiles.<name>]` table that this project appends to the user's base file. Keeping role files separate lets installation, backup, inspection, and removal remain narrowly scoped. See the [official Codex configuration reference](https://developers.openai.com/codex/config-reference/).

Profiles do not encode a team prefix. A live agent named `github-coder` still
starts with `--profile coder`, while `auth-coder` independently reuses that
same profile. Herdr live names carry runtime team identity; Codex profile names
carry reusable role configuration. `install.sh` therefore always manages
exactly these three role files regardless of team count.

## Role defaults

| Setting | Planner | Coder | Reviewer |
| --- | --- | --- | --- |
| `sandbox_mode` | `workspace-write` | `workspace-write` | `read-only` |
| `approval_policy` | `never` | `never` | `never` |
| reasoning default | `xhigh` | `high` | `xhigh` |
| application-source edits | forbidden by prompt | allowed and expected | blocked by sandbox and prompt |

The Coder template also provides this default recommendation:

```toml
model = "gpt-5.6-luna"
model_reasoning_effort = "high"
```

The workflow does not branch on that model name. Users may override it with any
model supported by their current Codex account and CLI.

Do not change Planner to `read-only` without retesting Herdr communication. A read-only Planner has previously failed with `Operation not permitted`. Do not change Reviewer to a writable sandbox merely to let it fix a finding; that destroys the independent-review boundary.

## Models

The workflow does not require a fixed model identifier. The repository gives
Coder a default, but routing, role checks, and tests do not depend on it. Set a
model that your Codex account and installed CLI support by editing each
installed profile:

```toml
model = "<available-model>"
model_reasoning_effort = "xhigh"
```

Suggested selection criteria:

- Planner needs reliable long-horizon reasoning, requirement analysis, and architecture judgment.
- Coder benefits from a coding-focused model with an appropriate speed/quality balance.
- Reviewer needs independent reasoning and enough context to inspect surrounding code, not just the patch summary.

Model availability and supported reasoning values change over time. Consult current official Codex documentation and your account rather than copying an identifier from an old README. If a model rejects `xhigh`, choose the strongest value it supports and re-run the communication tests.

The project also supports three narrowly scoped environment overrides:

```bash
PLANNER_MODEL="<available-model>" \
CODER_MODEL="<available-model>" \
REVIEWER_MODEL="<available-model>" \
./scripts/install.sh
```

At install time, each set variable is rendered into the corresponding installed profile; existing destinations are still backed up first. The same variables may be supplied to `start.sh` for a per-run `--model` override without rewriting the installed files. Unset variables preserve that role's profile or base-config model selection. Inspect the environment and the resulting installed file when model selection is security- or cost-sensitive.

## Developer instructions and readable prompts

The canonical role text is kept under `prompts/` so maintainers can review it without decoding a long TOML string. The installation path combines the role-specific configuration with those instructions using a simple shell process; no external template engine is required.

When changing a role:

1. edit the readable prompt in the repository;
2. inspect the matching profile template;
3. run the repository's static checks;
4. run `install.sh` and note the backup directory;
5. restart the changed Codex role;
6. run `test.sh static`, then run at least the team-aware `ping` and
   `communication` modes against the intended live Herdr session.

Do not edit only a running session's chat instructions and assume the installed team changed. A new session must be able to reconstruct the entire role from its installed profile.

## Reload behavior

Codex reads the selected profile at session startup. It does not automatically reload the file into an existing session. After changing `planner.config.toml`, for example:

1. preserve any task context and working-tree changes;
2. exit the old Planner session;
3. start `codex --profile planner` again in the intended Herdr pane;
4. confirm the live name is either legacy `planner` or the expected
   `<team-prefix>-planner`;
5. recover the task from the real diff and a self-contained handoff.

Restarting an agent can clear its Herdr live name because the name belongs to
the pane occupant. Run `doctor.sh --team <prefix>` (or unprefixed `doctor.sh`
for legacy mode) and `herdr agent list` after every role restart.

Never repair a restart by assigning a name from another team. A profile match
does not establish team membership.

## Approval and sandbox settings

`approval_policy = "never"` means Codex does not pause at ordinary approval points. It does not grant filesystem access that the sandbox forbids. Conversely, `workspace-write` still grants meaningful write capability even when the prompt says not to use it.

Keep these two mechanisms conceptually separate:

```text
approval policy  when Codex asks before an operation
sandbox mode     what the operation is allowed to access
role prompt      what the agent is instructed to do
```

Do not use `danger-full-access` as a compatibility workaround. Diagnose the missing path, Herdr integration, hook trust, or command surface instead.

## Local changes and updates

Installed files are user-local state and should not be committed. Repository profiles must contain no credentials or private machine paths.

Before updating from a newer repository revision, inspect the local role settings you intend to preserve:

```bash
grep -E '^(model|model_reasoning_effort|sandbox_mode|approval_policy)[[:space:]]*=' \
  "$HOME/.codex/planner.config.toml"
```

Repeat for Coder and Reviewer as needed. A direct diff against `profiles/*.config.toml` is expected to be noisy because the installed file also contains an ownership header and the rendered Markdown prompt. Run `install.sh`; it backs up the complete installed versions before writing new ones. Compare the printed backup with the new installed file, reapply only intentional local changes, and rerun tests.

## Alternative Codex home

Advanced users may point installation and startup at a separate Codex home by setting `CODEX_HOME` consistently for install, doctor, start, and Codex itself. Treat that directory as sensitive because it can contain credentials, trusted-hook state, and private configuration.

Do not set `CODEX_HOME` only for installation and then start agents without it; Codex would read a different profile set.

## Team and working-directory inputs

Team identity is runtime input rather than installed configuration:

```bash
./scripts/start.sh --team github --cwd /path/to/project
./scripts/doctor.sh --team github --cwd /path/to/project
./scripts/test.sh --team github communication
```

`TEAM_PREFIX=github` is supported as an environment alternative to `--team`.
If both are supplied, they must agree. Omitting both selects legacy names
`planner`, `coder`, and `reviewer`.

The prefix must produce valid unique Herdr names for all three roles. Startup
checks the exact generated names before workspace creation and stops on a
collision; it does not rename, replace, or delete an existing live agent.

`--cwd` selects the Git worktree for startup and the optional doctor cwd check.
It does not create a worktree. Use separate `--cwd` values for different
repositories, and separate Git worktrees when two teams work concurrently on
one repository. See [Multi-team isolation](multi-team.md).

## Runtime timeouts and test retention

The scripts accept these optional environment settings:

| Variable | Default | Purpose |
| --- | ---: | --- |
| `HERDR_START_TIMEOUT_MS` | `120000` | readiness timeout for each `herdr agent start` |
| `HERDR_TEST_TIMEOUT_MS` | `120000` | direct ping and Planner-routing prompt wait |
| `HERDR_FULL_TEST_TIMEOUT_MS` | `1200000` | full Planner/Coder/Reviewer loop wait |
| `HERDR_TEST_READ_LINES` | `2000` | terminal rows inspected for run-specific response evidence |
| `HERDR_TEST_PROJECT_DIR` | current directory | Git project used by the live team and host for the nested full-test fixture |
| `KEEP_TEST_WORKSPACE` | `0` | set to `1` to preserve a successful disposable full-test repository |

Timeouts are positive integer milliseconds. On the inspected Herdr 0.8.2 surface, an individual `agent start` timeout must be greater than 3000 ms and no more than 300000 ms, so keep `HERDR_START_TIMEOUT_MS` within that range. A failed test preserves its full-loop directory automatically for diagnosis.

Example for a slower startup:

```bash
HERDR_START_TIMEOUT_MS=180000 ./scripts/start.sh /path/to/project
```

Increase timeouts only when logs show genuine slow readiness or work. A timeout cannot fix a missing agent, duplicate name, blocked UI, unavailable server, or native-subagent fallback.

Run the full test while the current directory is the same project passed to `start.sh`, or provide the host explicitly:

```bash
HERDR_TEST_PROJECT_DIR=/path/to/project \
  /path/to/herdr-codex-team/scripts/test.sh --team github full
```

The host must be inside a Git-clean worktree with a committed `HEAD`. This placement keeps the nested fixture inside the `workspace-write` root of the live Planner and Coder, while the baseline check rejects Git-visible outside changes, commits, and branch switches. Git status does not audit ignored files, so use a disposable worktree without sensitive ignored content; choosing an unrelated, unborn, or dirty directory fails safely.

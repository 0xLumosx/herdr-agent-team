# Herdr Codex Team

Run a visible three-agent Codex software engineering team inside [Herdr](https://herdr.dev/).

**Planner → Coder → Reviewer → Planner**

```text
                    User
                     │
                     ▼
              ┌─────────────┐
              │   Planner   │
              │ Orchestrator│
              └──────┬──────┘
                     │
                     ▼
              ┌─────────────┐
              │    Coder    │
              │ only writer │
              └──────┬──────┘
                     │
                     ▼
              ┌─────────────┐
              │  Reviewer   │
              │  read-only  │
              └──────┬──────┘
                     │
            PASS / CHANGES_REQUIRED
                     │
                     ▼
                  Planner
```

Planner is the only orchestrator. Coder is the only application-source writer. Reviewer is independent and read-only. The names `planner`, `coder`, and `reviewer` always mean visible, live Herdr agents—never hidden Codex subagents.

> **v0.1 scope:** this repository is configuration, role policy, setup, and verification around Herdr and Codex CLI. It is not another multi-agent runtime, daemon, workflow engine, or state database.

## Why

A multi-agent workflow is useful only when role boundaries are observable and failures are honest. This project addresses three common failure modes:

- an orchestrator silently replaces an unavailable live agent with an internal subagent;
- multiple agents edit the same files or create a second, uncontrolled workflow;
- a reviewer reports success without independently reading the real diff and validation evidence.

Herdr provides the visible terminal runtime and agent communication. Codex CLI provides the three role-specific sessions. This repository supplies profiles, self-contained prompts, startup helpers, diagnostics, and communication tests.

## Architecture

The control path is deliberately one-way:

```text
User → Planner → Coder → Planner → Reviewer → Planner
                    ▲                    │
                    └── accepted fixes ──┘
```

Coder and Reviewer do not coordinate with each other. Planner checks the actual working tree between handoffs, triages review findings, and stops after at most four implementation/review rounds.

The Planner profile uses `workspace-write` because a read-only Planner may be unable to reach Herdr's communication surface. That is a technical capability, not permission to edit application source: the Planner prompt explicitly forbids source changes. This boundary is policy-enforced rather than an operating-system guarantee; see [Security](docs/security.md).

Read [Architecture](docs/architecture.md) for components, trust boundaries, and the round definition.

## Requirements

The real compatibility contract is command capability, not an exact version pin.

| Component | Required capability |
| --- | --- |
| Codex CLI | separate profile files at `$CODEX_HOME/<name>.config.toml`, `--profile`, `workspace-write`, `read-only`, and `approval_policy = "never"` |
| Herdr | `status`, workspace/pane inspection and creation (including `pane process-info`), named `agent start`, `agent list`, `agent prompt`, `agent wait`, and `agent rename` |
| Shell | Bash on macOS or a common Linux distribution |
| Git | required for diff inspection and the full workflow test |

The implementation was inspected against **Herdr 0.8.2** and **Codex CLI 0.147.0** on 2026-08-24. Those are the local verification baseline, not a claim that only those exact versions work. The scripts also probe the command surface and fail with a repair hint when a required capability is missing.

You must already be able to authenticate Codex and launch Herdr. `jq` is optional; the scripts have narrow shell fallbacks for the known Herdr response fields they consume. Python 3 is required only for the isolated full-loop demo. Node.js, a database, and a web service are not runtime requirements.

## Quick start

```bash
cd /path/to/herdr-codex-team
./scripts/install.sh
./scripts/test.sh static
```

Then enter a Herdr-managed terminal for the repository you want the team to work on:

```bash
cd /path/to/your-project
herdr
```

From a shell pane inside Herdr, run the checked-out helper by absolute path:

```bash
/path/to/herdr-codex-team/scripts/start.sh "$PWD"
```

`PROJECT_DIR` defaults to the current directory and must be inside a Git worktree. Pass `--no-focus` when startup should leave the currently focused pane unchanged:

```bash
/path/to/herdr-codex-team/scripts/start.sh --no-focus /absolute/path/to/project
```

The intended layout is:

```text
┌────────────────────────┬────────────────────────┐
│                        │ coder                  │
│ planner                ├────────────────────────┤
│                        │ reviewer               │
└────────────────────────┴────────────────────────┘
```

Run diagnostics again after startup, then test the live channel:

```bash
/path/to/herdr-codex-team/scripts/doctor.sh
/path/to/herdr-codex-team/scripts/test.sh ping
/path/to/herdr-codex-team/scripts/test.sh communication
```

Do not treat successful installation or three visible panes as proof of communication. The communication test must make the live Coder and Reviewer panes receive work and change state.

## Installation

`install.sh`:

1. checks that Codex and Herdr exist and reports their versions;
2. creates `~/.codex` if necessary;
3. backs up any existing target profile before replacement;
4. installs `planner.config.toml`, `coder.config.toml`, and `reviewer.config.toml` beside `~/.codex/config.toml`;
5. reports whether the Herdr Codex integration is confirmed current and prints the reviewed install command when it is not.

Backups are timestamped under a directory such as:

```text
~/.codex/herdr-codex-team-backup-20260824-153000/
```

The installer does not delete or rewrite `~/.codex/config.toml`, does not publish anything, and does not silently trust a new or changed hook. See [Installation](docs/installation.md) before using this on an existing Codex setup.

## Starting the team

Run `start.sh` after the Herdr server is running. A Herdr-managed shell is the clearest place to invoke it, although the script targets the newly created workspace by explicit IDs rather than relying on whichever pane the UI has focused. The script uses the current Herdr CLI's supported workspace, pane, and agent surfaces; it does not emulate agents in background processes. Each Codex instance starts with one of:

```text
codex --profile planner
codex --profile coder
codex --profile reviewer
```

The live names are assigned by Herdr and must be exactly:

```text
planner
coder
reviewer
```

Herdr may still describe every process as agent kind `codex`. Kind and live name are different concepts. If automatic layout preparation cannot complete, `start.sh` stops, leaves any partial workspace intact, and prints its ID for diagnosis instead of inventing unsupported CLI syntax.

Do not send a development task merely because startup returned three names. Run `doctor.sh` next; it verifies the installed sandbox/approval settings, profile load, integration, identity, readiness, lifecycle state, and foreground `--profile <role>` process arguments. Live tests separately require every target to be settled at `idle` or `done` and bound to the matching role profile.

See [Installation: start the team](docs/installation.md#start-the-team) for the verified manual primitives.

## Agent roles

| Role | Authority | Must do | Must not do |
| --- | --- | --- | --- |
| Planner | orchestrate and make the final decision | understand the task, define acceptance criteria, hand off through Herdr, inspect the real diff, triage review, perform final sanity check | implement the feature, edit application source, replace Herdr agents with native/internal subagents |
| Coder | sole implementation engineer | make focused changes, run relevant validation, report facts and blockers | approve its own work, contact Reviewer, redefine the task, start a review loop |
| Reviewer | independent verification | read requirements, diff, related code, and tests; report consequence-backed findings | modify files, implement fixes, command Coder, reject solely for stylistic preference |

Reviewer returns only `PASS` or `CHANGES_REQUIRED`. A blocking finding states severity, location, problem, consequence, and recommended correction. `LOW` findings are non-blocking by default.

## Testing communication

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static

cd /path/to/the-project-used-by-start.sh
/path/to/herdr-codex-team/scripts/test.sh ping
/path/to/herdr-codex-team/scripts/test.sh communication
/path/to/herdr-codex-team/scripts/test.sh full
```

| Mode | What it proves |
| --- | --- |
| `static` | shell syntax, required files, profile safety defaults, and prompt invariants without contacting live agents |
| `ping` | the external shell can reach the live Coder and Reviewer and receive exact run-specific sentinel replies |
| `communication` | the live Planner routes run-specific challenges into the real downstream panes and they return independently derived responses, detecting the hidden-only fallback failure |
| `full` | a tiny Git-backed defect travels through the live route; Coder and Reviewer return derived run-specific role tokens, fixture `HEAD` remains unchanged, only the expected fixture file differs, script-owned assertions pass, and the committed host keeps the same Git-visible status, branch, and `HEAD` before Planner returns a run-specific `APPROVED` |

For live tests, watch the named Herdr panes as well as the shell result. A text-only claim from Planner is not sufficient evidence that the intended pane moved. Invoke the absolute `test.sh` path while your shell's current directory is the same Git project passed to `start.sh`. Alternatively, set `HERDR_TEST_PROJECT_DIR` explicitly to that project. The full test requires the entire host Git worktree to have a committed `HEAD` and no Git-visible tracked or untracked changes, then creates its disposable nested fixture there so it remains inside the live team's workspace-write root. Use a disposable worktree without sensitive ignored files, not a production checkout with pending work.

The full test does **not** provide OS-level writer attribution. Because Planner intentionally has a `workspace-write` sandbox for Herdr compatibility, v0.1 cannot prove cryptographically or from filesystem audit data that Coder alone wrote the diff. It verifies routing and resulting artifacts, while the “Coder is the only writer” boundary remains prompt/workflow policy for Planner.

This repository was assembled from a shell that could not safely control the intended Herdr session, so live communication was not claimed as part of the build-time verification. Run the commands above against your intended Herdr session to establish that evidence locally.

## Running the first task

Open the Planner pane and paste a self-contained request. [Simple task](examples/simple-task.md) is a small first exercise; [full development task](examples/full-development-task.md) shows the recommended detail for real work.

The request should include:

- the goal and user-visible behavior;
- relevant constraints and explicit non-goals;
- acceptance criteria;
- validation expected before approval.

Planner owns decomposition and must include all necessary context in every Coder and Reviewer message. Neither downstream agent should need the user's earlier chat history.

## Configuration

Repository templates live in `profiles/`; installed files live at:

```text
~/.codex/planner.config.toml
~/.codex/coder.config.toml
~/.codex/reviewer.config.toml
```

Codex layers the selected file over the base `~/.codex/config.toml` when invoked with `--profile <name>`. This separate-file behavior is documented in the [official Codex configuration reference](https://developers.openai.com/codex/config-reference/).

Edit the installed profile to customize a running team. Profile changes are not reloaded into an existing Codex session; exit that role and start it again. Re-running `install.sh` reinstalls repository templates and first backs up the current installed profiles.

See [Configuration](docs/configuration.md) for the render path, safe customization workflow, and precedence.

Startup and live-test waits can be adjusted in milliseconds with `HERDR_START_TIMEOUT_MS`, `HERDR_TEST_TIMEOUT_MS`, and `HERDR_FULL_TEST_TIMEOUT_MS`. `HERDR_TEST_READ_LINES` changes the terminal evidence window, and `HERDR_TEST_PROJECT_DIR` selects the clean Git worktree that hosts the full-test fixture. Keep defaults unless there is a concrete reason to change them; a longer wait or read window does not repair a wrong live name or failed route.

## Models

The workflow is model-agnostic. Choose models available to your Codex account:

- Planner: a strong reasoning model;
- Coder: a coding-focused model that balances speed and reliability;
- Reviewer: a strong reasoning model capable of independent repository review.

Add or change the `model` line in each installed profile. The project intentionally does not hard-code a product-specific model name as a runtime requirement.

For a repeatable install-time override, set `PLANNER_MODEL`, `CODER_MODEL`, and/or `REVIEWER_MODEL` before `install.sh`. The same variables can override models for one `start.sh` run without rewriting the installed files. Every unset role keeps its profile value.

## Reasoning effort

The templates use role-appropriate defaults:

- Planner: `xhigh`;
- Coder: `high` (raise to `xhigh` when appropriate);
- Reviewer: `xhigh`.

Only choose values supported by the selected model and current Codex CLI. More reasoning is not a substitute for inspecting the actual diff or running tests.

## Approval policy

All three templates use:

```toml
approval_policy = "never"
```

In Codex, this means ordinary approval points do not pause for a user decision; a denied operation is returned to the agent. It does **not** mean the sandbox is disabled. This setting improves unattended handoffs but removes an interactive safety checkpoint, so inspect the repository and role profiles before starting.

## Sandbox modes

```text
Planner   workspace-write  (communication compatibility; prompt forbids source edits)
Coder     workspace-write  (the only intended source writer)
Reviewer  read-only        (independent inspection)
```

`danger-full-access` is not a default and is not recommended for this workflow. See [Security](docs/security.md) and the [official Codex sandbox guidance](https://developers.openai.com/codex/agent-approvals-security/).

## Workflow

One review round is:

```text
Coder implementation or fix
→ Reviewer review
→ Planner triage
```

If Reviewer returns `CHANGES_REQUIRED`, Planner accepts or rejects each finding based on engineering consequence, then sends accepted corrections back to Coder. After four rounds without a pass, Planner stops and reports `NOT APPROVED` with remaining issues and a recommendation. Coder and Reviewer must not continue talking independently.

After `PASS`, Planner still checks the working tree, acceptance criteria, and validation evidence before returning `APPROVED`. A Reviewer pass is necessary but not sufficient.

See [Workflow](docs/workflow.md) for handoff contracts, failure states, and restart recovery.

## Failure handling

- If a named live agent is missing or Herdr communication fails, Planner stops with `HERDR_COMMUNICATION_FAILED`; it must never fall back to a hidden agent.
- If implementation cannot continue, Coder returns `BLOCKED` with the concrete cause and observed evidence.
- If review cannot be completed from the available requirements, diff, or validation, Reviewer returns `CHANGES_REQUIRED` and identifies the missing evidence.
- If four rounds are exhausted, Planner returns `NOT APPROVED` instead of creating an infinite agent conversation.
- If Planner restarts mid-task, preserve the working tree; inspect `git status` and `git diff` before deciding the next handoff.

## Troubleshooting

Start with:

```bash
./scripts/doctor.sh
herdr agent list
```

The most important symptom is: **Planner says Coder is working, but the Coder pane does not move.** Treat that as failed communication, not progress. Confirm the live name and pane state, then verify the Planner prompt still contains the mandatory no-fallback rule.

See [Troubleshooting](docs/troubleshooting.md) for `Operation not permitted`, wrong or expired agent names, profile reloads, hook trust, blocked agents, and live tests with an unavailable or unintended Herdr server.

## Security

This workflow deliberately grants write-capable sandboxes to Planner and Coder and disables interactive approval pauses. Prompts reduce accidental role violations but cannot provide a hard security boundary against a compromised model, malicious repository instructions, unsafe hooks, or destructive commands available inside the sandbox.

Use a clean Git branch or disposable worktree, keep secrets out of the repository and prompts, review hooks before trusting them, and inspect every diff before merging. Do not weaken the profiles to `danger-full-access` merely to bypass a setup problem.

Read [Security](docs/security.md) before using the team on sensitive code.

## Uninstall

```bash
./scripts/uninstall.sh
```

The uninstaller moves only profiles carrying this project's installer marker into a new timestamped backup. It preserves unmarked files, the base Codex configuration, and all earlier backups. It does not remove Codex, Herdr, user credentials, unrelated hooks, or repositories. Inspect the target files before running it and review the printed result.

## License

[MIT](LICENSE)

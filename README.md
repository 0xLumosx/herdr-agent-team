# Herdr Codex Team

[简体中文](README.zh-CN.md)

Run one or many isolated three-agent Codex teams inside
[Herdr](https://herdr.dev/).

Each team keeps the same visible workflow—Planner → Coder → Reviewer—but its
Herdr names carry a team identity:

```text
                                  Herdr

       ┌──────────────────────────────┐  ┌──────────────────────────────┐
       │ Team: auth                   │  │ Team: github                 │
       │                              │  │                              │
User ─▶│ auth-planner                 │  │ github-planner               │◀─ User
       │   ├────────▶ auth-coder      │  │   ├────────▶ github-coder    │
       │   └────────▶ auth-reviewer   │  │   └────────▶ github-reviewer │
       └──────────────────────────────┘  └──────────────────────────────┘

                         NO CROSS-TEAM ROUTING
```

Planner is the only orchestrator. Coder is the only intended
application-source writer. Reviewer is independent and read-only. A Planner
may address only its own team's exact live Herdr names and must fail closed if
identity or routing is ambiguous.

Codex profiles are reusable; Herdr live names provide team identity:

```text
Codex profile: planner        Herdr live name: auth-planner
Codex profile: coder          Herdr live name: auth-coder
Codex profile: reviewer       Herdr live name: auth-reviewer
```

The `planner` profile does **not** require the Herdr agent to be literally
named `planner`. Prefixed and legacy teams all reuse the same three profiles.

> **Project scope:** this repository is configuration, role policy, setup, and
> verification around Herdr and Codex CLI. It is not another multi-agent
> runtime, daemon, scheduler, workflow engine, branch manager, or state
> database.

## Why

A multi-agent workflow is useful only when role boundaries are observable and
failures are honest. This project addresses four common failures:

- an orchestrator silently replaces an unavailable live agent with an internal
  subagent;
- a Planner from one team routes to a Coder or Reviewer from another team;
- multiple agents edit the same working tree and make attribution or review
  unreliable;
- a Reviewer reports success without independently reading the real diff and
  validation evidence.

Herdr supplies the visible runtime, unique live names, and communication.
Codex CLI supplies three role-specific sessions. This repository supplies
reusable profiles, self-contained prompts, startup helpers, diagnostics, and
routing tests.

## Architecture

Inside every team, the control path is deliberately one-way:

```text
User → Planner → Coder → Planner → Reviewer → Planner
                    ▲                    │
                    └── accepted fixes ──┘
```

Coder and Reviewer do not coordinate with each other. Planner checks the real
working tree between handoffs, triages review findings, and stops after at most
four implementation/review rounds.

At the Herdr level, any number of prefixed teams may coexist:

```text
Herdr
├── auth-planner / auth-coder / auth-reviewer
├── github-planner / github-coder / github-reviewer
└── docs-planner / docs-coder / docs-reviewer
```

The invariant is: **a Planner orchestrates only inside its own team**. It
derives the Coder and Reviewer names from its current live Herdr identity. It
does not guess from pane position, tab, workspace, process kind, or a fixed
pane ID.

The Planner profile uses `workspace-write` because a read-only Planner may be
unable to reach Herdr's communication surface. That capability is not
permission to edit application source: the Planner prompt forbids it. This is a
policy boundary, not an operating-system guarantee; see
[Security](docs/security.md).

Read [Architecture](docs/architecture.md) and
[Multi-team isolation](docs/multi-team.md) for the complete model.

## Requirements

The compatibility contract is command capability, not an exact version pin.

| Component | Required capability |
| --- | --- |
| Codex CLI | separate profile files at `$CODEX_HOME/<name>.config.toml`, `--profile`, `workspace-write`, `read-only`, and `approval_policy = "never"` |
| Herdr | status, workspace/pane inspection and creation, named agent start/list/get/prompt/wait, and valid unique live names |
| Shell | Bash on macOS or a common Linux distribution |
| Git | required for diff inspection and the full workflow test |

The implementation was inspected against **Herdr 0.8.2** and **Codex CLI
0.147.0** on 2026-08-24. This is a local verification baseline, not an exact
pin. The scripts probe required capabilities and fail with a repair hint when
one is missing.

You must already be able to authenticate Codex and launch Herdr. Scripts that
consume Herdr JSON require a real parser: `jq` is preferred, and Python 3's
standard library is the fallback when `jq` is absent. The isolated full-loop
demo requires Python 3 specifically, even when `jq` is installed.

## Quick start

Install the three reusable profiles once:

```bash
cd /path/to/herdr-codex-team
./scripts/install.sh
./scripts/test.sh static
```

Start a prefixed team from a Herdr-managed shell:

```bash
/path/to/herdr-codex-team/scripts/start.sh \
  --team github \
  --cwd /absolute/path/to/project
```

That creates these live Herdr names while selecting the generic profiles:

```text
github-planner    → codex --profile planner
github-coder      → codex --profile coder
github-reviewer   → codex --profile reviewer
```

Start another isolated team without stopping the first:

```bash
/path/to/herdr-codex-team/scripts/start.sh \
  --team auth \
  --cwd /absolute/path/to/another-project
```

Check each team explicitly:

```bash
/path/to/herdr-codex-team/scripts/doctor.sh --team github
/path/to/herdr-codex-team/scripts/test.sh --team github ping
/path/to/herdr-codex-team/scripts/test.sh --team github communication

/path/to/herdr-codex-team/scripts/doctor.sh --team auth
```

`TEAM_PREFIX=github` is an environment alternative to `--team github`. For
legacy compatibility, omit the team prefix to create one team named exactly
`planner`, `coder`, and `reviewer`:

```bash
/path/to/herdr-codex-team/scripts/start.sh --cwd /absolute/path/to/project
/path/to/herdr-codex-team/scripts/doctor.sh
```

`start.sh` also retains the legacy positional project-directory form. Use
`--no-focus` when startup should leave the focused pane unchanged. See
[Installation](docs/installation.md) for the full command contract.

The intended three-pane layout is a convenience, not identity evidence:

```text
┌────────────────────────┬────────────────────────┐
│                        │ <team>-coder           │
│ <team>-planner         ├────────────────────────┤
│                        │ <team>-reviewer        │
└────────────────────────┴────────────────────────┘
```

Do not treat profile installation or three visible panes as proof of routing.
Run diagnostics and live tests, and watch the exact named panes receive work.

## Working trees for concurrent teams

Exact-name routing plus the fail-closed prompt contract reduces accidental
cross-team messages when followed. Before creating a workspace, `start.sh`
also refuses another inspectable Herdr Codex role agent when either reported
cwd resolves to the same physical Git worktree or its path contains/is inside
the requested root. Separate worktrees are allowed only when their cwd scopes
do not overlap this way. This is a preflight guard, not an atomic reservation
or ACL; a post-check race or a writer outside Herdr remains possible.

- Different repositories can run concurrently with different `--cwd` values.
- Concurrent tasks in one repository should use one Git worktree and branch per
  team.

```bash
cd /projects/myapp
git worktree add ../myapp-auth -b task/auth
git worktree add ../myapp-ui -b task/ui

/path/to/herdr-codex-team/scripts/start.sh \
  --team auth --cwd /projects/myapp-auth
/path/to/herdr-codex-team/scripts/start.sh \
  --team ui --cwd /projects/myapp-ui
```

The project deliberately does not create branches, merge changes, remove
worktrees, or resolve conflicts. Those remain normal user-owned Git operations.
See [Multi-team isolation](docs/multi-team.md) and the
[multi-team example](examples/multi-team.md).

## Installation behavior

`install.sh`:

1. checks Codex and Herdr and reports their versions;
2. creates `$CODEX_HOME` if necessary;
3. backs up every existing target profile before replacement;
4. installs only `planner.config.toml`, `coder.config.toml`, and
   `reviewer.config.toml`;
5. records SHA-256 markers for the exact embedded role prompt and the managed
   profile policy so `doctor.sh` and `start.sh` reject installed instructions,
   reasoning, sandbox, approval, or future policy fields that drift from the
   current checkout; the independently configurable `model = ...` assignment
   is excluded;
6. reports Herdr Codex integration state without silently trusting a changed
   hook.

Teams never cause per-prefix profile copies. Twenty teams still use those same
three installed files. The installer does not delete or rewrite the base
`config.toml`, publish anything, or force hook trust.

## Agent roles

| Role | Authority | Must do | Must not do |
| --- | --- | --- | --- |
| Planner | orchestrate its own team and make the final decision | derive its live identity, verify exact same-team targets, define acceptance criteria, inspect the real diff, triage review | implement source, address another team, guess a target, replace Herdr agents with native/internal subagents |
| Coder | sole implementation engineer for its team | make focused changes, run relevant validation, report facts and blockers | approve its own work, contact Reviewer, orchestrate agents |
| Reviewer | independent verification | inspect requirements, diff, related code, and tests; report consequence-backed findings | modify files, implement fixes, command Coder, orchestrate agents |

Reviewer returns only `PASS` or `CHANGES_REQUIRED`. A blocking finding states
severity, location, problem, consequence, and recommended correction. `LOW`
findings are non-blocking by default.

## Testing

```bash
./scripts/test.sh static

/path/to/herdr-codex-team/scripts/test.sh --team github ping
/path/to/herdr-codex-team/scripts/test.sh --team github communication
/path/to/herdr-codex-team/scripts/test.sh --team github full
/path/to/herdr-codex-team/scripts/test.sh --team github policy
/path/to/herdr-codex-team/scripts/test.sh \
  --team github --against-team auth isolation
/path/to/herdr-codex-team/scripts/test.sh \
  --team auth --against-team github isolation
```

| Mode | What it establishes |
| --- | --- |
| `static` | shell syntax, required files, profile safety defaults, identity parsing, legacy and prefixed naming, and prompt invariants without live agents |
| `ping` | the shell can address the exact same-team Coder and Reviewer and receive run-specific replies |
| `communication` | the live Planner routes run-specific challenges into those real downstream panes |
| `full` | a small Git-backed defect travels through the live Planner/Coder/Reviewer loop with bounded artifact checks |
| `policy` | adversarial prompts check role-specific refusal of unauthorized write, delegation, and direct-contact requests against a baseline-checked nested Git fixture |
| `isolation` | one directed same-team route succeeds while the named peer team's retained transcripts and lifecycle sequence remain unchanged; swap the two prefixes to check the reverse direction |

The isolation harness uses a challenge-derived standalone token in the retained
Coder terminal plus lifecycle-sequence changes as behavioral evidence. Herdr's
plain retained terminal is not a role-tagged audit log, so this is not
cryptographic proof of who authored a token; watch the named panes and inspect
task artifacts for consequential runs.

For live tests, watch the exact named panes. A Planner's text-only claim is not
evidence that the intended target moved. Invoke the absolute `test.sh` path
while the shell is in the same Git worktree passed to `start.sh`, or set
`HERDR_TEST_PROJECT_DIR` explicitly.

The `full` and `policy` tests require a clean, committed, disposable host
worktree and create nested fixtures under it. They check routing and resulting
Git artifacts but do not provide operating-system writer attribution. Because
Planner has a `workspace-write` sandbox, “Coder is the only writer” remains
prompt/workflow policy for Planner. Policy mode also checks unchanged peer
transcripts, lifecycle sequences, and visible Herdr agent names; it cannot
prove that no hidden native worker ever existed.

No live multi-team routing result is implied by this repository's static test
suite. If two suitable teams are unavailable, report the isolation test as
`NOT RUN`, not `PASS`. A single direction is not a bidirectional isolation
result; run the command again with `--team` and `--against-team` swapped.

## Running the first task

Open the intended Planner pane and paste a self-contained request. Use the
[simple task](examples/simple-task.md) for one team, the
[full development task](examples/full-development-task.md) for a realistic
handoff, or the [multi-team example](examples/multi-team.md) for concurrent
teams.

Include the goal, constraints, explicit non-goals, acceptance criteria, and
expected validation. Planner must include all necessary context in every
Coder/Reviewer handoff; downstream agents should not need the user's prior chat
history. Every normal handoff and response also carries one stable `TASK_ID`,
the current `ROUND` (1–4), and a fresh per-handoff `HANDOFF_ID`; missing or
mismatched echoes stop the workflow fail-closed.

## Configuration and models

Repository templates live under `profiles/`; installed files live at:

```text
$CODEX_HOME/planner.config.toml
$CODEX_HOME/coder.config.toml
$CODEX_HOME/reviewer.config.toml
```

The Coder template defaults to:

```toml
model = "gpt-5.6-luna"
model_reasoning_effort = "high"
sandbox_mode = "workspace-write"
approval_policy = "never"
```

This is a default recommendation, not a routing dependency. The workflow is
model-agnostic. Choose models available to your Codex account and CLI with
`PLANNER_MODEL`, `CODER_MODEL`, and `REVIEWER_MODEL` at install or startup, or
edit only the top-level `model = ...` assignment in an installed role file.
Restart a role after changing its model.

Planner and Reviewer use `xhigh` reasoning defaults; Coder uses `high`.
Reasoning, sandbox, approval, and role instructions are managed policy: change
them in the matching repository template under `profiles/` or `prompts/`, run
`install.sh`, and restart the affected role. Use only values supported by the
selected model. See
[Configuration](docs/configuration.md) and the
[official Codex configuration reference](https://developers.openai.com/codex/config-reference/).

## Approval and sandbox settings

All three templates use `approval_policy = "never"`. Ordinary approval points
do not pause for a user decision, but denied operations still fail under the
active sandbox. The defaults are:

```text
Planner   workspace-write  (communication compatibility; prompt forbids source edits)
Coder     workspace-write  (the only intended source writer)
Reviewer  read-only        (independent inspection)
```

`danger-full-access` is not a default and is not a setup workaround. See
[Security](docs/security.md) and the
[official Codex sandbox guidance](https://developers.openai.com/codex/agent-approvals-security/).

## Workflow and failure handling

One review round is:

```text
Coder implementation or fix → Reviewer review → Planner triage
```

After four rounds without a pass, Planner returns `NOT APPROVED`. After
Reviewer `PASS`, Planner still checks the working tree, acceptance criteria,
and validation before returning `APPROVED`.

Routing is fail-closed:

- an unknown Planner identity produces `HERDR_COMMUNICATION_FAILED`;
- a missing expected same-team agent produces `HERDR_COMMUNICATION_FAILED`;
- another team's available Coder or Reviewer is never a fallback;
- native/internal workers, hidden subagents, pane-layout guesses, and fixed
  pane IDs are never substitutes for exact live Herdr names;
- Coder reports `BLOCKED` when implementation cannot continue;
- Planner preserves the working tree and reconstructs state after interruption.

Read [Workflow](docs/workflow.md) for handoff contracts and recovery.

## Troubleshooting

Start with the exact team:

```bash
./scripts/doctor.sh --team github
herdr agent list
```

If Herdr reports `agent_name_taken`, do not overwrite or continue a partial
team; choose a unique team prefix. If Planner addresses the wrong Coder, inspect
its derived `SELF_AGENT`, `TEAM_PREFIX`, `CODER_AGENT`, and `REVIEWER_AGENT`.
If two Coders changed the same checkout, fix the `--cwd`/Git-worktree collision;
that is not a routing problem.

The most important symptom remains: Planner says Coder is working while the
expected same-team Coder pane is idle. Treat that as failed communication, not
progress. See [Troubleshooting](docs/troubleshooting.md).

## Security

This workflow grants write-capable sandboxes to Planner and Coder and disables
interactive approval pauses. Prompts and prefixes reduce ambiguity but are not
a hard boundary against a compromised model, malicious repository instructions,
unsafe hooks, shared filesystems, or destructive commands allowed by the
sandbox.

Use clean branches or disposable worktrees, keep secrets out of repositories
and prompts, review hooks, and inspect every diff before merging. Read
[Security](docs/security.md) before using the team on sensitive code.

## Uninstall

```bash
./scripts/uninstall.sh
```

The uninstaller moves only project-managed profiles into a timestamped backup.
It does not remove Codex, Herdr, credentials, live teams, worktrees, the base
Codex configuration, or unrelated hooks.

## License

[MIT](LICENSE)

See [CHANGELOG.md](CHANGELOG.md) for the current unreleased update history.

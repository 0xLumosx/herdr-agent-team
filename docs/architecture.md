# Architecture

## Scope

Herdr Codex Team is a thin coordination package around two existing systems:

```text
Herdr       visible terminal runtime, live-agent identity, communication
Codex CLI   interactive software-engineering agents and sandbox policies
This repo   profiles, role prompts, scripts, tests, and documentation
```

It does not replace Herdr, implement an agent protocol, maintain a daemon, or persist workflow state. v0.1 intentionally has no database, web UI, queue, or autonomous state machine.

## Control topology

```text
                    ┌──────────────┐
                    │     User     │
                    └──────┬───────┘
                           │ task
                           ▼
                    ┌──────────────┐
              ┌────▶│   Planner    │◀──────────────┐
              │     │ orchestrator │               │
              │     └──────┬───────┘               │
              │            │ implementation brief  │ review result
              │            ▼                       │
              │     ┌──────────────┐                │
              │     │    Coder     │                │
              │     │ only writer  │                │
              │     └──────┬───────┘                │
              │            │ result + real diff     │
              └────────────┘                       │
                           │ review brief            │
                           ▼                         │
                    ┌──────────────┐                 │
                    │   Reviewer   │─────────────────┘
                    │  read-only   │ PASS / CHANGES_REQUIRED
                    └──────────────┘
```

There is no Coder-to-Reviewer channel in the workflow. Planner is the only component allowed to schedule another role, decide which findings are valid, or declare final approval.

## Components

### Profiles

The files under `profiles/` are distributable templates. `scripts/install.sh` installs rendered role profiles as:

```text
$CODEX_HOME/planner.config.toml
$CODEX_HOME/coder.config.toml
$CODEX_HOME/reviewer.config.toml
```

`CODEX_HOME` defaults to `~/.codex`. Codex CLI selects a file with `--profile planner`, `--profile coder`, or `--profile reviewer` and layers it over the base user configuration.

### Prompts

The Markdown files under `prompts/` are the readable source of each role contract. They are self-contained: role authority, forbidden actions, handoff format, failure behavior, and review limits do not rely on prior chat history.

### Setup scripts

- `install.sh` validates prerequisites, backs up conflicts, and installs profiles.
- `doctor.sh` checks the binaries, installed profiles, Herdr runtime, live names, agent states, and foreground `--profile <role>` binding.
- `start.sh` prepares the three-pane team using only CLI capabilities exposed by the installed Herdr.
- `test.sh` exercises direct pings, Planner-mediated communication, and the full loop.
- `uninstall.sh` moves only project-managed profile files into a recoverable dated backup.

### Test prompts

The direct-ping fixtures define exact sentinel replies, while mediated and full-loop tests use run-specific challenges whose success response must be derived only by the downstream live agent. The complete derived response is absent from the outer Planner input, so merely forwarding or echoing that input cannot satisfy the check. Run-specific strings make it harder to confuse stale scrollback or a generic model response with evidence that the intended live agent handled the message. The visible pane transition remains part of the evidence.

The full-loop harness requires a Git-clean host worktree with a committed `HEAD` and creates a disposable nested Git repository under the project used by the live team. It uses challenge-derived Coder and Reviewer response tokens so input text is not mistaken for a successful response; it also requires fixture `HEAD` to stay at the harness baseline, exactly the expected fixture file to differ, the surrounding host's Git-visible status, branch, and `HEAD` to stay unchanged, script-owned Python assertions and fixture tests to pass, and Planner to emit a run-specific approval token. The harness commit disables user-level signing and hooks. It is not a filesystem audit and does not detect modifications to ignored host files. It also cannot provide writer attribution: Planner has `workspace-write`, and v0.1 installs no operating-system audit mechanism. “Only Coder writes” is hard-enforced for Reviewer but remains prompt/workflow policy for Planner.

## Identity: kind is not name

Herdr can identify all three processes as kind `codex` while assigning unique live names:

```text
kind: codex, name: planner
kind: codex, name: coder
kind: codex, name: reviewer
```

Prompts refer to the live name. A process, pane, internal Codex worker, or session-local path called “coder” is not a substitute. If `herdr agent list` cannot identify the required live target, the workflow stops.

In Herdr 0.8.2, a name follows the current pane occupant and is cleared when that agent exits, is released, or is replaced. Names are runtime state, not permanent profile metadata; startup and diagnostics must therefore check them every time.

## Role and permission matrix

| Capability | Planner | Coder | Reviewer |
| --- | ---: | ---: | ---: |
| Talk to User | yes | through Planner report | through Planner report |
| Schedule Coder | yes | no | no |
| Schedule Reviewer | yes | no | no |
| Modify application source by policy | no | yes | no |
| Filesystem sandbox | `workspace-write` | `workspace-write` | `read-only` |
| Inspect Git diff | required | required for own report | required |
| Declare final approval | yes | no | no |

The Planner's no-write boundary is a prompt and workflow rule, not a hard filesystem restriction. `workspace-write` is retained because a read-only Planner has previously produced `Operation not permitted` while attempting Herdr communication. This tradeoff must be understood rather than described as perfect isolation.

## Handoff contracts

Every Planner-to-Coder message includes the goal, relevant context, constraints, acceptance criteria, expected validation, and explicit prohibition on changing unrelated code. Every Planner-to-Reviewer message includes the original requirement, acceptance criteria, current round, Coder report, validation evidence, and the exact diff/revision scope to inspect.

The Coder returns either `IMPLEMENTATION_DONE` with factual details or `BLOCKED`. The Reviewer returns only `PASS` or `CHANGES_REQUIRED`. The Planner accepts neither report at face value: it reads the working tree before the next decision.

## Review rounds and termination

One round is:

```text
Coder implementation or fix → Reviewer review → Planner triage
```

The initial implementation counts as round 1. The maximum is four rounds. On a pass, Planner performs one final sanity check. After round 4 without an acceptable result, Planner stops with `NOT APPROVED`, preserving the remaining issues and both downstream positions for the user.

The cap prevents an unbounded Coder/Reviewer conversation and keeps final responsibility with Planner.

## Trust boundaries

There are four distinct boundaries:

1. **Herdr runtime:** supplies live identity and observable routing. A visible pane is evidence of process identity, not proof that its output is correct.
2. **Codex sandbox:** constrains tool access. `approval_policy = "never"` changes prompting behavior but does not disable this sandbox.
3. **Role prompt:** constrains behavior semantically. It is useful policy, not a security primitive.
4. **Git and validation:** provide the objective record used for final decisions. Reports without matching diff/test evidence are unverified claims.

## Restart and future persistence

v0.1 keeps no workflow database. If Planner restarts, preserve all files and begin recovery with:

```bash
git status --short
git diff
git diff --staged
```

The new Planner reconstructs the goal and current state, verifies live Herdr agents, and resumes at the appropriate handoff. It must not assume the Coder report or Reviewer result survived.

A later version may add file-backed handoffs under `.herdr-codex/`:

```text
task.md
plan.md
coder-result.md
review.md
state.json
```

That is deliberately outside v0.1; adding it would introduce state ownership, recovery, and stale-data questions that should be designed explicitly.

# Architecture

[简体中文](zh-CN/architecture.md)

## Scope

Herdr Codex Team is a thin coordination package around two existing systems:

```text
Herdr       visible terminal runtime, live-agent identity, communication
Codex CLI   interactive software-engineering agents and sandbox policies
This repo   profiles, role prompts, scripts, tests, and documentation
            plus one user-local launch record per Team
```

It does not replace Herdr, implement an agent protocol, maintain a daemon, or
persist task/workflow state. It intentionally has no workflow database, web UI,
queue, autonomous state machine, or automated Git branch/worktree lifecycle.
The launch record is observation and recovery metadata, not runtime truth.

## System hierarchy

The three-role topology remains the structure *inside* one team. At the system
level, live Herdr names partition concurrent teams:

```text
Herdr
├── Team: auth
│   ├── auth-planner   (Codex profile: planner)
│   ├── auth-coder     (Codex profile: coder)
│   └── auth-reviewer  (Codex profile: reviewer)
├── Team: docs
│   ├── docs-planner   (Codex profile: planner)
│   ├── docs-coder     (Codex profile: coder)
│   └── docs-reviewer  (Codex profile: reviewer)
└── Legacy team
    ├── planner
    ├── coder
    └── reviewer
```

The central invariant is:

```text
Planner only orchestrates inside its own Team.
```

A prefixed Planner derives both downstream names from its current live name.
The exact legacy self-name `planner` maps to `coder` and `reviewer`. Any other
unrecognized identity, missing expected target, or ambiguous derivation fails
with `HERDR_COMMUNICATION_FAILED`. An agent in another team is never a fallback.

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
              │            │ result + evidence       │
              └────────────┘                       │
                           │ review brief            │
                           ▼                         │
                    ┌──────────────┐                 │
                    │   Reviewer   │─────────────────┘
                    │  read-only   │ PASS / CHANGES_REQUIRED
                    └──────────────┘
```

There is no Coder-to-Reviewer channel in the workflow. Planner is the only
component allowed to schedule another role, relay Reviewer corrections,
or declare final approval, and those scheduling rights apply only to exact
same-team names derived from its own live Herdr identity.

## Components

### Profiles

The files under `profiles/` are distributable templates. `scripts/install.sh` installs rendered role profiles as:

```text
$CODEX_HOME/planner.config.toml
$CODEX_HOME/coder.config.toml
$CODEX_HOME/reviewer.config.toml
$CODEX_HOME/herdr-codex-team/herdr_mcp.py
```

`CODEX_HOME` defaults to `~/.codex`. Codex CLI selects a file with `--profile
planner`, `--profile coder`, or `--profile reviewer` and layers it over the
base user configuration. These profiles are reusable role policy, not team
identity. Every team uses the same three profiles and the same Planner bridge;
prefixed copies are neither needed nor installed.

### Prompts

The Markdown files under `prompts/` are the readable source of each role contract. They are self-contained: role authority, forbidden actions, handoff format, failure behavior, and review limits do not rely on prior chat history.

### Setup scripts

- `install.sh` validates prerequisites, backs up conflicts, and installs profiles
  plus the exact managed Planner bridge.
- `doctor.sh` checks binaries, installed profiles, Herdr runtime, exact legacy
  or prefixed live names, state, workspace/pane/cwd association, and foreground
  profile, named permission profile, effective filesystem sandbox and network,
  and role-specific additional-root argv binding. With no explicit roots, it can load the latest
  Team launch record and verify its exact runtime binding against Herdr.
- `start.sh` prepares one legacy or prefixed three-pane team using only CLI
  capabilities exposed by the installed Herdr. It rejects name collisions and
  does not rename or delete existing agents. It also rejects complete-root-set
  overlaps; repeatable Codex `--add-dir` values give Planner read-only workspace
  context and Coder writable context. Reviewer remains on the primary root. A
  short-lived startup lock
  serializes current helpers using the same `CODEX_HOME` across preflight and
  workspace creation, and an atomic user-local record captures that helper
  invocation's launch observations.
- `lib/run-state.sh` owns only schema validation, atomic launch-record writes,
  state-backed scope loading, and the startup lock. It never prompts, starts,
  stops, or schedules an Agent.
- `test.sh` exercises team-aware direct pings, Planner-mediated communication,
  the full loop, and—when two real teams are available—routing isolation.
- `uninstall.sh` moves only project-managed profiles and bridge into a recoverable dated backup.

### Test prompts

The direct-ping fixtures define exact sentinel replies, while mediated and full-loop tests use run-specific challenges whose success response must be derived only by the downstream live agent. The complete derived response is absent from the outer Planner input, so merely forwarding or echoing that input cannot satisfy the check. Run-specific strings make it harder to confuse stale scrollback or a generic model response with evidence that the intended live agent handled the message. The visible pane transition remains part of the evidence.

The isolation mode names one primary and one adversarial peer team. It checks a
live same-team route and inspects the peer team's downstream evidence for the
run-specific challenge. Both teams must be real and settled; static name
construction alone cannot establish cross-team isolation, and an unavailable
live check must be reported as `NOT RUN`.
It is routing evidence, not proof of filesystem isolation between root sets.

The full-loop harness requires a Git-clean host worktree with a committed
`HEAD` and creates a disposable nested Git repository under the project used
by the live team. It uses challenge-derived Coder and Reviewer response tokens
so input text is not mistaken for a successful response; it also requires
fixture `HEAD` to stay at the harness baseline, exactly the expected fixture
file to differ, the surrounding host's Git-visible status, branch, and `HEAD`
to stay unchanged, script-owned Python assertions and fixture tests to pass,
and Planner to emit a run-specific approval token. The harness commit disables
user-level signing and hooks. It is not a filesystem audit and does not detect
modifications to ignored host files. It also cannot provide writer attribution:
managed Planner and Reviewer are read-only, but the project installs no
operating-system audit mechanism for unmanaged processes.

The harness requires a Git-backed primary host. If the team's primary cwd is
non-Git, `full` and `policy` are `NOT RUN`. A result under a Git-backed primary
does not establish a non-Git additional root's baseline, complete diff,
rollback, or writer attribution.

## Identity: profile, kind, and live name are different

Herdr can identify all processes as kind `codex` while their unique live names
encode role and optional team:

```text
kind: codex, name: planner
kind: codex, name: coder
kind: codex, name: reviewer

kind: codex, name: auth-planner
kind: codex, name: auth-coder
kind: codex, name: auth-reviewer
```

The profile selected by `codex --profile coder` describes what an agent may do;
the Herdr live name `auth-coder` describes where its team's Planner routes.
Prompts refer to exact live names. A process, pane, internal Codex worker, or
session-local path called “coder” is not a substitute. If Herdr cannot identify
the expected same-team target, the workflow stops.

In Herdr 0.8.2, a name follows the current pane occupant and is cleared when
that agent exits, is released, or is replaced. Names are runtime state, not
permanent profile metadata; startup, Planner handoffs, and diagnostics must
therefore check them every time. Pane IDs and layout are also runtime data. A
launch record may persist pane IDs only as freshness expectations for one
`run_id`; they are never permanent Team identity and must be rechecked live.

For a Codex 0.171+ worker with a local session log, the bridge matches the submitted prompt to its native turn and returns the completed reply as `codex-turn`. It verifies the Herdr pane, conversation ID and lifecycle sequence again after delivery. Other clients and older Codex installations use the retained terminal transcript.

## Role and permission matrix

| Capability | Planner | Coder | Reviewer |
| --- | ---: | ---: | ---: |
| Talk to User | discuss proposals and decisions | route blockers to Planner | ask through Planner and publish the final report in the Reviewer pane |
| Schedule same-team Coder | yes | no | no |
| Schedule same-team Reviewer | yes | no | no |
| Address another team | no | no | no |
| Modify application source by policy | no | yes | no |
| Filesystem sandbox | `read-only` | `workspace-write` | `read-only` |
| Command network | enabled | enabled | enabled |
| Inspect available change evidence | Git diff per Git root; touched-path limits per non-Git root | same for own report | independently inspect both and preserve gaps |
| Declare final approval | yes | no | no |

Planner and Reviewer have a direct `read-only` filesystem boundary. Planner
receives `--add-dir` as workspace context, Reviewer does not, and Coder is the
only managed implementation writer.
Managed startup selects a beta permission profile extending `:read-only` for
Planner and Reviewer and another extending `:workspace` for Coder; all three
enable command network. It repeats the exact permission settings in argv,
passes the same additional-root context to Planner and Coder while only Coder
can write it, and rejects legacy
`--sandbox` or `sandbox_workspace_write.writable_roots` conflicts. Startup and
Doctor also verify the effective model-visible filesystem sandbox and network
state. Planner reaches
Herdr through a required local stdio MCP bridge because Linux shell sandboxes
can reject AF_UNIX socket creation. The bridge validates the current pane,
socket ownership, exact same-workspace team identities, readiness, and
lifecycle correlation; its tool surface accepts only `inspect_team` and
role-only `prompt_agent`, never an arbitrary agent name or Herdr command. Every
role profile disables Codex-native multi-agent tools with
`agents.enabled = false`; managed launch repeats the setting in argv and live
validation rejects older processes without it. Herdr is therefore the only
managed agent topology.

Command network is broad outbound capability, not an SSH-host allowlist. The
local filesystem sandbox does not constrain remote operations made through
SSH, and `approval_policy = "never"` adds no interactive checkpoint before an
allowed remote command. Remote-account and server-side restrictions are a
separate trust boundary.

## Handoff contracts

Every Planner-to-Coder message includes the goal, relevant context, constraints, acceptance criteria, expected validation, and explicit prohibition on changing unrelated code. Every Planner-to-Reviewer message includes the original requirement, acceptance criteria, current round, Coder report, validation evidence, and the exact change-evidence scope to inspect: diff/revision evidence for Git-backed roots, or reported touched paths and explicit evidence gaps for non-Git roots.

The Coder returns either `IMPLEMENTATION_DONE` with factual details or `BLOCKED`. Reviewer returns `ASK_PLANNER` or `ASK_USER` for clarification and `PASS` or `CHANGES_REQUIRED` for a verdict. The bridge returns the operational verdict and findings to Planner. The user-facing report stays in the Reviewer pane. The Planner accepts neither report at face value: it reads the working tree before the next decision.

## Review rounds and termination

One round is:

```text
Coder implementation or fix → Reviewer review → Planner triage
```

The initial implementation counts as round 1. The maximum is four rounds. On a pass, Planner performs one final sanity check. After round 4 without an acceptable result, Planner stops with `NOT APPROVED`, preserving the remaining issues and both downstream positions for the user.

The cap prevents an unbounded Coder/Reviewer conversation and keeps final responsibility with Planner.

## Trust boundaries

There are six distinct boundaries:

1. **Herdr runtime:** supplies live identity and observable routing. A visible
   pane is evidence of process identity, not proof that its output is correct.
2. **Team-name boundary:** exact `<prefix>-<role>` names prevent cross-team
   addressing when Planner follows the fail-closed contract. They do not
   isolate files or operating-system processes.
3. **Codex sandbox and command network:** the role permission profile
   constrains local filesystem access and enables outbound command network.
   `approval_policy = "never"` changes prompting behavior but does not disable
   the sandbox or limit what the remote SSH account may do.
4. **Role prompt:** constrains behavior semantically. It is useful policy, not
   a security primitive.
5. **Git and validation:** provide the objective record used for final
   decisions where Git history exists. A non-Git touched-path inventory is
   best-effort evidence and cannot prove a complete change set or baseline.
6. **Launch record:** preserves what the startup helper observed and expected.
   It is not proof of current liveness, delivery, task completion, approval, or
   writer identity.

Two teams can be perfectly separated by Herdr name and still corrupt each
other's work if any primary or additional scope overlaps. Startup compares the
complete managed root sets: Git-backed paths at their physical worktree root,
and non-Git paths at their physical directory root. Concurrent tasks in one
repository require separate Git worktrees and branches, and every additional
root must remain disjoint. This preflight is not an operating-system lock.
The startup lock closes the race only between current managed `start.sh`
processes using the same `CODEX_HOME` and is released after startup; different
`CODEX_HOME` namespaces, external writers, and older/manual launch paths remain
outside it.

## Restart and persistence boundary

The project keeps the latest launch record and the linked conversation IDs for
each team under `$CODEX_HOME`. In a managed Planner pane, selecting a registered
chat resumes the two associated peer chats. See [conversation recovery](launch-state.md#conversation-recovery).
If the chat history is unavailable, preserve all files.
For each Git-backed root, begin recovery with:

```bash
git status --short
git diff
git diff --staged
```

For each non-Git root, record `Git evidence: NOT AVAILABLE` and inspect the last
reported touched paths directly; this cannot reconstruct a complete baseline.

Without a recorded conversation, the new Planner reconstructs the goal and current state, re-derives its current
team identity, verifies the exact same-team live Herdr agents, and resumes at
the appropriate handoff. It must not assume the Coder report or Reviewer result
survived. A launch record can verify expected roots, workspace, and pane IDs,
but cannot restore a Codex conversation.

Durable handoff packets, responses, delivery receipts, task transitions, and
review decisions remain outside the current scope. Adding them would require a
single interception Interface around Planner's Herdr delivery; terminal
scraping or a second mailbox would create conflicting state owners.

For operational examples and the filesystem boundary, see
[Multi-team isolation and dynamic routing](multi-team.md). The upstream design
comparison that motivated this boundary is in
[Comparison with oh-my-codex](omx-comparison.md).

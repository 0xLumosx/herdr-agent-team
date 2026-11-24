# Workflow

[简体中文](zh-CN/workflow.md)

## Invariants

Every task follows five invariants:

1. Planner is the only orchestrator and final decision-maker.
2. Coder is the only role intended to modify application source.
3. Reviewer is independent, read-only, and never implements a fix.
4. A legacy team uses the exact live names `planner`, `coder`, and `reviewer`;
   a prefixed team uses only `<prefix>-planner`, `<prefix>-coder`, and
   `<prefix>-reviewer`.
5. Planner orchestrates only the exact Coder and Reviewer derived from its own
   current live Herdr identity.

If identity or the same-team route cannot be established, Planner stops with:

```text
HERDR_COMMUNICATION_FAILED
```

It does not choose a similarly named agent, use another team's available role,
start a Codex native subagent, hidden worker, `/root/coder`, `/root/reviewer`,
or any other fallback.

## Runtime team identity

At the start of a task and before each handoff, Planner obtains its current live
Herdr name. It accepts only these two forms:

```text
SELF_AGENT = planner
  TEAM_PREFIX = (legacy, empty)
  CODER_AGENT = coder
  REVIEWER_AGENT = reviewer

SELF_AGENT = <prefix>-planner
  TEAM_PREFIX = <prefix>
  CODER_AGENT = <prefix>-coder
  REVIEWER_AGENT = <prefix>-reviewer
```

Planner verifies both exact downstream names with Herdr. Team identity never
comes from pane position, a fixed pane ID, the current tab/workspace, or process
kind. If `auth-coder` is missing while `docs-coder` exists, the result is still
`HERDR_COMMUNICATION_FAILED`.

## 1. User to Planner

The user gives Planner a goal, constraints, and observable success conditions. Planner reads the repository and checks for an invalid premise, missing information, conflicting requirements, and current uncommitted work before choosing a design.

Planner's plan must identify:

- the user-visible outcome;
- relevant existing architecture and files;
- explicit non-goals;
- acceptance criteria;
- validation appropriate to the risk;
- assumptions that could change the implementation.

When the proposed approach is incorrect, Planner explains the evidence and discusses an alternative with the user before dispatch. Planner may resolve low-risk ambiguity from repository evidence. If an unresolved choice would materially change scope or behavior, it asks the user rather than hiding the assumption.

## 2. Planner to Coder

Before sending work, Planner confirms its exact derived live target with Herdr.
The handoff is self-contained and should follow this shape:

```text
ROLE: Live Herdr agent `<CODER_AGENT>`
TEAM: `<TEAM_PREFIX>` (or `legacy`)
TASK_ID: `<stable for the whole user task>`
ROUND: `<1 through 4>`
HANDOFF_ID: `<fresh for this handoff>`

Goal:
...

Repository context:
...

Required behavior:
...

Acceptance criteria:
1. ...
2. ...

Constraints and non-goals:
- ...

Validation to run:
- ...

Report contract:
Return IMPLEMENTATION_DONE or BLOCKED using the Coder role format.
Do not contact Reviewer or start another agent.
```

Coder reads before editing, makes the smallest complete change, and avoids unrelated cleanup. It runs focused tests plus applicable typecheck, lint, or build commands.

On success, Coder returns:

```text
IMPLEMENTATION_DONE
TASK_ID: <exact value from the handoff>
ROUND: <exact value from the handoff>
HANDOFF_ID: <exact value from the handoff>

Summary:
...

Files changed:
...

Validation:
...

Assumptions:
...

Remaining concerns:
...
```

If it cannot proceed, it returns `BLOCKED` with the exact missing input, failing command, error, and safe next step. It never declares `APPROVED`.

## 3. Planner verifies the implementation

Planner treats the Coder report as a lead, not proof. For each Git-backed root,
it reads at least:

```bash
git status --short
git diff
git diff --staged
```

For each non-Git root, Planner records `Git evidence: NOT AVAILABLE`, inspects
Coder's best-effort touched-path inventory and those files directly, and carries
forward that a complete baseline, diff, untracked-file scope, rollback point,
and pre-existing-change attribution are unavailable. Direct inspection does not
close those gaps.

Planner compares the available changed-file and validation evidence to the
plan. If Coder changed unrelated files or the available evidence is materially
incomplete, Planner sends a focused correction to Coder before review.

Planner must not edit the source itself to “save a round.” Its managed sandbox
is `read-only`; Herdr communication goes through the bounded Planner bridge.

## 4. Planner to Reviewer

Planner confirms the exact same-team live Reviewer, then sends a self-contained
brief:

```text
ROLE: Live Herdr agent `<REVIEWER_AGENT>`
TEAM: `<TEAM_PREFIX>` (or `legacy`)
TASK_ID: `<same task id as Coder>`
ROUND: `<same round as the implementation being reviewed>`
HANDOFF_ID: `<fresh and different from Coder's handoff id>`

Original goal:
...

Acceptance criteria:
1. ...
2. ...

Constraints and non-goals:
- ...

Coder report:
...

Validation evidence:
...

Review scope:
- for every Git-backed root, inspect git status and the actual diff
- for every non-Git root, record Git evidence as NOT AVAILABLE and inspect the
  reported touched paths directly
- read changed files and relevant surrounding code
- assess correctness, regression, security, error handling, compatibility,
  state/data consistency, edge cases, and test quality

Return PASS or CHANGES_REQUIRED for a verdict. For clarification, return ASK_PLANNER first, then ASK_USER if discussion leaves a decision for the user. Use the Reviewer correlation fields for all four statuses.
Do not modify files and do not contact Coder.
```

Reviewer independently inspects the repository. It does not reject code merely because it prefers a different style. Every blocking finding must describe an actual engineering consequence.

Coder and Reviewer echo the three correlation lines immediately after their
line-1 status. Planner rejects a missing, reordered, reused, or mismatched echo
as `HERDR_COMMUNICATION_FAILED` before interpreting the response body.

`CHANGES_REQUIRED` findings use:

```text
Severity: CRITICAL | HIGH | MEDIUM | LOW
Location: path and tight line or symbol reference
Problem: what is objectively wrong or missing
Why it matters: concrete consequence or failed criterion
Recommended correction: bounded direction, not an implementation takeover
```

`LOW` is non-blocking by default. Reviewer returns `PASS` only when no blocking finding remains and the available evidence is sufficient.

## 5. Planner triages findings

Planner relays actionable Reviewer instructions to Coder. For disputed findings, Planner discusses the evidence with Reviewer. For an unresolved product choice, Planner relays Reviewer’s question verbatim and waits for the user. Clarification keeps the task and round, with a fresh handoff ID per exchange.

Accepted corrections go back to Coder in one consolidated, self-contained task. Reviewer never sends instructions directly to Coder.

## 6. Round cap

One round is:

```text
Coder implementation or fix → Reviewer review → Planner triage
```

The initial implementation is round 1. The maximum is four rounds. If the result still cannot pass after round 4, Planner stops:

```text
NOT APPROVED

Reason for rejection:
...

Next action:
...
```

The cap is not a reason to lower the acceptance bar. It is a reason to return control to the user with an explicit unresolved state.

## 7. Final sanity check

Reviewer `PASS` does not automatically approve the task. Planner performs a final check of:

- the actual Git diff and unexpected files for Git-backed roots;
- the reported touched paths and explicit unavailable-evidence limits for
  non-Git roots;
- every acceptance criterion;
- claimed test, typecheck, lint, and build results;
- compatibility and rollback concerns appropriate to the change;
- whether any material assumption remains unverified.

Read the final review report in the Reviewer pane. Planner gives its own `APPROVED` or `NOT APPROVED` decision in the Planner pane, with the reason and any next action.

## Communication semantics

Planner first calls the managed `mcp__herdr_codex_team__inspect_team` tool. It
then submits work only through `mcp__herdr_codex_team__prompt_agent` with
`target_role` exactly `coder` or `reviewer`. For an `auth-planner`, the bridge
derives `auth-coder` or `auth-reviewer`; callers cannot provide an arbitrary
live name.

The bridge re-proves current pane ownership and both same-workspace peers before
and after prompting, waits for a settled state, requires Herdr's lifecycle
sequence to advance, and returns a bounded transcript. These remain
correlated observations, not a cryptographically bound request/response turn.
The workflow therefore also uses handoff IDs, run-specific tests, visible pane
observation, and result inspection instead of treating one signal as conclusive.

The user-local launch record does not change these semantics. It stores no
prompt, acknowledgement, delivery receipt, `TASK_ID`, `ROUND`, `HANDOFF_ID`,
agent response, or task transition. Herdr remains the only production prompt
transport, and this project makes no durable or exactly-once delivery claim.
Transport acceptance, lifecycle movement, a correlated response, and the
resulting filesystem change are separate evidence.

If a target is `blocked`, inspect the agent state and visible terminal. Do not answer an approval or question automatically on the user's behalf.

## Recovery after interruption

Do not discard or reset project files merely because Planner or Herdr restarted. The recovering Planner should:

1. recover the user's goal and acceptance criteria;
2. run `git status`, `git diff`, and `git diff --staged` for every Git-backed
   root; for a non-Git root, record `Git evidence: NOT AVAILABLE` and inspect
   the last reported touched-path inventory directly;
3. inspect validation artifacts and current processes;
4. run `doctor.sh --team <prefix>` to verify saved launch expectations when a
   current record exists, or supply explicit `--cwd <primary> --add-dir
   <extra> ...` to bypass stale workspace/pane binding; confirm all three exact
   live names and managed process scopes;
5. decide whether Coder must continue or Reviewer can inspect the available
   Git/non-Git change evidence;
6. send a fresh, self-contained handoff.

The project does not persist a task/workflow state machine. The launch record
can recover root and runtime-ID expectations only; the goal, current handoff,
Coder report, Reviewer decision, and delivery uncertainty still require
conversation and filesystem evidence. See [Launch state](launch-state.md) and
[Multi-team isolation](multi-team.md).

Multi-root access changes evidence, not authority: Coder remains the only
managed write-capable role. Planner and Reviewer remain `read-only` across
every root. Planner receives additional roots as read-only workspace context;
only Coder receives additional writable-root grants, and Reviewer remains on
the primary root.

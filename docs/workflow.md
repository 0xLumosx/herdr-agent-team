# Workflow

## Invariants

Every task follows four invariants:

1. Planner is the only orchestrator and final decision-maker.
2. Coder is the only role intended to modify application source.
3. Reviewer is independent, read-only, and never implements a fix.
4. `planner`, `coder`, and `reviewer` refer only to live Herdr agents with those names.

If the fourth invariant cannot be established, Planner stops with:

```text
HERDR_COMMUNICATION_FAILED
```

It does not start a Codex native subagent, hidden worker, `/root/coder`, `/root/reviewer`, or any other fallback.

## 1. User to Planner

The user gives Planner a goal, constraints, and observable success conditions. Planner reads the repository and checks for an invalid premise, missing information, conflicting requirements, and current uncommitted work before choosing a design.

Planner's plan must identify:

- the user-visible outcome;
- relevant existing architecture and files;
- explicit non-goals;
- acceptance criteria;
- validation appropriate to the risk;
- assumptions that could change the implementation.

Planner may resolve low-risk ambiguity from repository evidence. If an unresolved choice would materially change scope or behavior, it asks the user rather than hiding the assumption.

## 2. Planner to Coder

Before sending work, Planner confirms the live target with Herdr. The handoff is self-contained and should follow this shape:

```text
ROLE: Live Herdr agent `coder`

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

Planner treats the Coder report as a lead, not proof. It reads at least:

```bash
git status --short
git diff
git diff --staged
```

It compares changed files and validation evidence to the plan. If the Coder changed unrelated files or the diff is materially incomplete, Planner sends a focused correction to Coder before review.

Planner must not edit the source itself to “save a round.” Its `workspace-write` sandbox exists for Herdr compatibility, not implementation authority.

## 4. Planner to Reviewer

Planner confirms the live Reviewer, then sends a self-contained brief:

```text
ROLE: Live Herdr agent `reviewer`

Original goal:
...

Acceptance criteria:
1. ...
2. ...

Constraints and non-goals:
- ...

Round:
1 of 4

Coder report:
...

Validation evidence:
...

Review scope:
- inspect git status and the actual diff
- read changed files and relevant surrounding code
- assess correctness, regression, security, error handling, compatibility,
  state/data consistency, edge cases, and test quality

Return only PASS or CHANGES_REQUIRED using the Reviewer role format.
Do not modify files and do not contact Coder.
```

Reviewer independently inspects the repository. It does not reject code merely because it prefers a different style. Every blocking finding must describe an actual engineering consequence.

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

Planner checks each finding against the requirement and code. It may reject a finding that is factually wrong, outside scope, purely preferential, or unsupported. It records the reason rather than automatically forwarding every comment.

Accepted corrections go back to Coder in one consolidated, self-contained task. Reviewer never sends instructions directly to Coder.

## 6. Round cap

One round is:

```text
Coder implementation or fix → Reviewer review → Planner triage
```

The initial implementation is round 1. The maximum is four rounds. If the result still cannot pass after round 4, Planner stops:

```text
NOT APPROVED

Remaining issues:
...

Coder position:
...

Reviewer position:
...

Planner recommendation:
...
```

The cap is not a reason to lower the acceptance bar. It is a reason to return control to the user with an explicit unresolved state.

## 7. Final sanity check

Reviewer `PASS` does not automatically approve the task. Planner performs a final check of:

- the actual Git diff and unexpected files;
- every acceptance criterion;
- claimed test, typecheck, lint, and build results;
- compatibility and rollback concerns appropriate to the change;
- whether any material assumption remains unverified.

Only then may Planner return `APPROVED`, summarizing changes, validation, and remaining non-blocking risks.

## Communication semantics

On the inspected Herdr 0.8.2 surface, Planner can submit work through:

```bash
herdr agent prompt coder "<self-contained task>" --wait --timeout 120000
```

`--wait` observes lifecycle state, not a cryptographically bound request/response turn. If an agent is already working, its current turn can satisfy a wait. The workflow therefore combines target-name verification, visible pane observation, sentinel tests, and result inspection instead of treating any one signal as conclusive.

If a target is `blocked`, inspect the agent state and visible terminal. Do not answer an approval or question automatically on the user's behalf.

## Recovery after interruption

Do not discard or reset the working tree merely because Planner or Herdr restarted. The recovering Planner should:

1. recover the user's goal and acceptance criteria;
2. run `git status`, `git diff`, and `git diff --staged`;
3. inspect validation artifacts and current processes;
4. run `doctor.sh` and confirm all three live names;
5. decide whether Coder must continue or Reviewer can inspect the existing diff;
6. send a fresh, self-contained handoff.

v0.1 does not persist a formal state machine. Human-readable file-backed checkpoints are a possible future extension, not a hidden dependency of the current workflow.

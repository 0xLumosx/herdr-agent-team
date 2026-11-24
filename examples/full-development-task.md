# Full development task example

This example demonstrates the amount of context a real Planner request should carry. Replace bracketed values with repository facts before sending it.

```text
Goal

Add optimistic-concurrency protection to the existing project-update endpoint
so one client cannot silently overwrite a newer saved revision.

Current context

- Endpoint: [METHOD /path]
- Handler/service: [path and symbol]
- Persistence layer: [path and symbol]
- Existing revision field: [field name and type, or state that none exists]
- Existing error-response convention: [path/example]
- Relevant tests: [paths]

User-visible behavior

Clients submit the revision they last read. The server updates the project only
when that revision still matches persisted state. A stale request receives a
conflict response and does not change persisted data.

Acceptance criteria

1. A request with the current revision succeeds and returns the next revision.
2. A request with a stale revision receives the repository's standard conflict
   status/error shape.
3. A stale request makes no partial database or in-memory change.
4. Two updates racing from the same starting revision cannot both succeed.
5. Existing clients without the revision field follow this explicit policy:
   [reject as validation error / temporary backward-compatible behavior].
6. Unit tests cover success, stale update, missing/invalid revision, and no
   partial mutation.
7. An integration or persistence-level test demonstrates the atomic condition,
   not only a mocked service call.
8. Existing relevant tests, typecheck, lint, and build pass where available.
9. Public API or migration documentation is updated if the repository requires
   it.

Constraints

- Preserve the current authentication and authorization checks.
- Use the persistence system's atomic compare-and-update mechanism; do not
  implement a read-then-write race in application code.
- Do not add a database, queue, framework, or unrelated abstraction.
- Do not refactor adjacent endpoints unless required for correctness.
- Do not weaken an existing compatibility promise without reporting it.

Non-goals

- Offline merge/conflict resolution.
- A general event-sourcing system.
- Changes to unrelated resources.
- UI conflict-resolution design beyond the existing API error contract.

Validation

- Run the smallest focused test command first: [command].
- Run the persistence/integration test: [command].
- Run project typecheck/lint/build as applicable: [commands].
- Report commands exactly, including failures or skipped checks and why.

Required agent workflow

Planner is the only orchestrator. Derive the exact Coder and Reviewer names
from your current live Herdr identity: legacy `planner` uses only `coder` and
`reviewer`, while `<prefix>-planner` uses only `<prefix>-coder` and
`<prefix>-reviewer`. Confirm those exact visible agents before sending work.
Never use another team's agents, Codex native subagents, internal workers,
hidden agents, `/root/coder`, or `/root/reviewer`. If identity or communication
fails, stop with HERDR_COMMUNICATION_FAILED.

Only Coder may modify application source and tests. Reviewer is read-only and
must inspect the original requirement, acceptance criteria, surrounding code,
test evidence, and all available change evidence: actual git status/diff for
Git-backed roots, or reported touched paths with explicit evidence gaps for
non-Git roots. Reviewer can seek clarification from Planner and then the user. Its verdict is PASS or CHANGES_REQUIRED with evidence. Read the final review in the Reviewer pane and the acceptance decision in the Planner pane.

Coder and Reviewer never contact each other. Planner checks the available
change evidence between handoffs, triages findings, and allows at most four
rounds. After PASS, Planner performs a final sanity check before APPROVED. If
round 4 cannot pass, return NOT APPROVED with remaining issues and a
recommendation.
```

## Why this is a stronger request

The task distinguishes the desired outcome from a guessed implementation, states the compatibility decision that cannot safely be invented, and requires evidence at the persistence boundary where the race actually exists. It also gives Reviewer a concrete basis for rejecting a superficially correct but non-atomic implementation.

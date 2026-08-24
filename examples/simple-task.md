# Simple first task

Copy the task below into the intended live Herdr Planner pane after the
team-aware doctor, ping, and communication checks pass.

```text
Goal

Add a `clamp(value, minimum, maximum)` helper to the repository's existing
numeric utility module.

Required behavior

- Return `minimum` when `value` is below the lower bound.
- Return `maximum` when `value` is above the upper bound.
- Return `value` when it is inside the inclusive range.
- Reject `minimum > maximum` using the repository's existing error convention.

Constraints

- Follow the current module and test structure.
- Do not add a dependency.
- Do not refactor unrelated utilities.
- Preserve the public API style already used by the package.

Acceptance criteria

1. Focused tests cover below-range, in-range, boundary, above-range, and invalid
   bound cases.
2. Existing relevant tests still pass.
3. Only the live Herdr Coder modifies application source or tests.
4. The live Herdr Reviewer independently inspects the real diff and returns
   PASS or CHANGES_REQUIRED.
5. Planner checks the final diff and validation evidence before APPROVED.

Required workflow

Derive the exact same-team Coder and Reviewer names from your current live
Herdr Planner identity. Legacy `planner` routes only to `coder` and `reviewer`;
`<prefix>-planner` routes only to `<prefix>-coder` and `<prefix>-reviewer`.
Verify both targets before handoff. Do not use another team's agents or create
or substitute Codex native subagents, internal workers, hidden agents,
`/root/coder`, or `/root/reviewer`. If identity or Herdr communication fails,
stop and return HERDR_COMMUNICATION_FAILED.

Coder and Reviewer must not contact each other. Planner owns every handoff and
may run at most four implementation/review rounds.
```

This example intentionally leaves file discovery and implementation design to Planner. Adapt the helper name and module language to the target repository if it has no numeric utility module; keep the acceptance criteria equally concrete.

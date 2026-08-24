# Full Herdr workflow integration test

This task is for the live Herdr Planner asserted by the test runner as `{{PLANNER_AGENT}}`.

Before accepting the task, independently prove your live identity from the current Herdr pane. Require `SELF_AGENT` to equal that assertion. Derive your team's Coder and Reviewer under your permanent routing rules and require the exact results to equal `{{CODER_AGENT}}` and `{{REVIEWER_AGENT}}`. These assertions do not replace runtime identity discovery. Fail closed on any mismatch.

The current test working tree contains a deliberately broken demo function named `add(a, b)` that subtracts `b` from `a`. Discover the fixture from the repository; do not assume an unverified path.

Fix the function so it returns the arithmetic sum of its two arguments.

Acceptance criteria:

- `add(a, b)` returns `a + b`, including representative positive, zero, and negative inputs.
- The demo project's relevant tests pass.
- The change is minimal and introduces no unrelated refactor or dependency.
- Only exact same-team live `{{CODER_AGENT}}` modifies project files.
- Exact same-team live `{{REVIEWER_AGENT}}` remains read-only and independently reviews the actual diff.
- Planner inspects the real working-tree diff and performs a final sanity check.

Required workflow:

```text
Planner frames the task and acceptance criteria
-> exact same-team live Coder implements and validates
-> Planner inspects the actual git status and diff
-> exact same-team live Reviewer returns PASS or CHANGES_REQUIRED
-> Planner triages any findings
-> if needed, the same Coder fixes and the same Reviewer reviews again
-> Planner final sanity check
-> APPROVED or NOT APPROVED
```

A round is Coder implementation or fix, Reviewer review, and Planner triage. Use at most 4 rounds. Coder and Reviewer must not communicate directly.

Before every handoff, re-prove your current identity, re-derive the exact same-team target, and verify it with the Herdr CLI. Use the Herdr CLI agent surface for delivery, waiting, and response reading. Never contact a generic similarly named agent or another team's agent. Do not use Codex native subagents, internal workers, hidden or spawned local agents, `/root/coder`, `/root/reviewer`, session-local agents, or any fallback agent system.

If Herdr identity, routing, discovery, or communication fails at any stage, stop and begin the response with:

```text
HERDR_COMMUNICATION_FAILED
```

Do not modify the fixture as Planner. Do not ask Reviewer to modify it. Do not commit, push, or publish the test change.

On success, begin the final response with the exact line:

```text
APPROVED
```

Then report changed files, validation evidence, and review rounds used. On failure after the allowed rounds or failed final verification, begin with the exact line:

```text
NOT APPROVED
```

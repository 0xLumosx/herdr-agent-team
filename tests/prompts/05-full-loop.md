# Full Herdr workflow integration test

This task is for the live Herdr agent named `planner`.

The current test working tree contains a deliberately broken demo function named `add(a, b)` that subtracts `b` from `a`. Discover the fixture from the repository; do not assume an unverified path.

Fix the function so it returns the arithmetic sum of its two arguments.

Acceptance criteria:

- `add(a, b)` returns `a + b`, including representative positive, zero, and negative inputs.
- The demo project's relevant tests pass.
- The change is minimal and introduces no unrelated refactor or dependency.
- Only the unique live Herdr agent named `coder` modifies project files.
- The unique live Herdr agent named `reviewer` remains read-only and independently reviews the actual diff.
- Planner inspects the real working-tree diff and performs a final sanity check.

Required workflow:

```text
Planner frames the task and acceptance criteria
-> live Herdr Coder implements and validates
-> Planner inspects the actual git status and diff
-> live Herdr Reviewer returns PASS or CHANGES_REQUIRED
-> Planner triages any findings
-> if needed, live Coder fixes and live Reviewer reviews again
-> Planner final sanity check
-> APPROVED or NOT APPROVED
```

A round is Coder implementation or fix, Reviewer review, and Planner triage. Use at most 4 rounds. Coder and Reviewer must not communicate directly.

Before every handoff, verify the exact target name with `herdr agent list`. Use the Herdr CLI agent surface for delivery, waiting, and response reading. Do not use Codex native subagents, internal workers, hidden or spawned local agents, `/root/coder`, `/root/reviewer`, session-local agents, or any fallback agent system.

If Herdr discovery or communication fails at any stage, stop and begin the response with:

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

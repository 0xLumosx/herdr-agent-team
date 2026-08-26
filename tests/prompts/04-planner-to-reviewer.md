This is an end-to-end Herdr transport test for Planner.

Do not modify any files.

The test runner's expected same-team Reviewer is `{{REVIEWER_AGENT}}`. Treat that value only as an assertion: call the managed `mcp__herdr_codex_team__inspect_team` tool and require its exact `reviewer_agent.name` to match. If it differs, fail closed.

1. Require the managed inspection result to prove current Planner identity and both same-team peers ready.
2. Use only `mcp__herdr_codex_team__prompt_agent` with `target_role = "reviewer"` to send a self-contained prompt containing this challenge inline exactly once:

   `PLANNER_TO_REVIEWER_CHALLENGE`

   Tell Reviewer this is a no-write Herdr communication test. Only Reviewer may derive the response: replace `CHALLENGE` in the challenge with `OK`, then reply with that derived token as one standalone line and no other text. Do not derive or write the response token yourself.

3. Require the bridge result to identify exact asserted `REVIEWER_AGENT`, show its correlated lifecycle evidence, and include its real transcript.
4. If exact `REVIEWER_AGENT` emitted the correctly derived token, return that exact observed token as one standalone line and no other text. Do not calculate it before observing Reviewer's response.

Do not prompt any other Reviewer or any other team's agent. Do not use Codex native subagents, internal workers, `/root/reviewer`, session-local agents, or any fallback agent system.

If managed bridge startup, identity discovery, same-team derivation, exact-name verification, delivery, lifecycle observation, waiting, response reading, or exact-token verification fails, reply exactly:

HERDR_COMMUNICATION_FAILED

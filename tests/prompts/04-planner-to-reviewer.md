This is an end-to-end Herdr transport test for Planner.

Do not modify any files.

The test runner's expected same-team Reviewer is `{{REVIEWER_AGENT}}`. Treat that value only as an assertion: independently prove your own live Herdr identity from the current pane and derive `REVIEWER_AGENT` under your permanent routing rules. If the derived exact name differs from the assertion, fail closed.

1. Run `herdr agent list`, query exact derived `REVIEWER_AGENT`, and confirm that exactly that same-team live Herdr agent is available and ready.
2. Use the Herdr CLI agent surface only to send exact derived `REVIEWER_AGENT` a self-contained prompt containing this challenge inline exactly once:

   `PLANNER_TO_REVIEWER_CHALLENGE`

   Tell Reviewer this is a no-write Herdr communication test. Only Reviewer may derive the response: replace `CHALLENGE` in the challenge with `OK`, then reply with that derived token as one standalone line and no other text. Do not derive or write the response token yourself.

3. Wait through Herdr for that exact agent's lifecycle to settle and read its real response.
4. If exact derived `REVIEWER_AGENT` emitted the correctly derived token, return that exact observed token as one standalone line and no other text. Do not calculate it before observing Reviewer's response.

Do not prompt any other Reviewer or any other team's agent. Do not use Codex native subagents, internal workers, `/root/reviewer`, session-local agents, or any fallback agent system.

If identity discovery, same-team derivation, exact-name verification, delivery, lifecycle observation, waiting, response reading, or exact-token verification fails, reply exactly:

HERDR_COMMUNICATION_FAILED

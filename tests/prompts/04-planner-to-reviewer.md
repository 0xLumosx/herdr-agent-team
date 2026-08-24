This is an end-to-end Herdr transport test for Planner.

Do not modify any files.

1. Run `herdr agent list` and confirm that exactly one live Herdr agent is named `reviewer`.
2. Use the Herdr CLI agent surface only to send that live agent a self-contained prompt containing this challenge inline exactly once:

   `PLANNER_TO_REVIEWER_CHALLENGE`

   Tell Reviewer this is a no-write Herdr communication test. Only Reviewer may derive the response: replace `CHALLENGE` in the challenge with `OK`, then reply with that derived token as one standalone line and no other text. Do not derive or write the response token yourself.

3. Wait through Herdr for the agent lifecycle to settle and read the real Reviewer response.
4. If the live Reviewer emitted the correctly derived token, return that exact derived token as one standalone line and no other text. Do not calculate it before observing Reviewer's response.

Do not use Codex native subagents, internal workers, `/root/reviewer`, session-local agents, or any fallback agent system.

If discovery, delivery, lifecycle observation, waiting, response reading, or exact-token verification fails, reply exactly:

HERDR_COMMUNICATION_FAILED

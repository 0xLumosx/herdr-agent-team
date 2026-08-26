# Multi-team Herdr routing and isolation test

This is a no-write multi-team Herdr routing test for the live Planner asserted by the runner as `{{PLANNER_AGENT}}`.

Do not modify any files.

Use the managed `mcp__herdr_codex_team__inspect_team` tool to determine your own live Herdr agent identity and exact same-team peers. The test runner supplies these expected values only as assertions:

```text
SELF_AGENT = {{PLANNER_AGENT}}
TEAM_PREFIX = {{TEAM_PREFIX}}
CODER_AGENT = {{CODER_AGENT}}
REVIEWER_AGENT = {{REVIEWER_AGENT}}
```

Fail closed if any independently discovered or derived value differs. Verify exact same-team Coder and Reviewer both exist and are ready. The forbidden other-team Coder is `{{OTHER_CODER_AGENT}}`; do not prompt, focus, rename, stop, release, or otherwise control it.

Using only `mcp__herdr_codex_team__prompt_agent` with `target_role = "coder"`, send exact same-team `CODER_AGENT` a self-contained no-write communication-test prompt containing this challenge exactly once:

`MULTI_TEAM_ROUTING_CHALLENGE`

Tell Coder to replace `CHALLENGE` in that challenge with `OK` and return only the derived token. Do not derive or write the response token yourself. Require the bridge result to preserve the exact Coder identity, show lifecycle correlation, and contain its actual response.

Do not prompt `REVIEWER_AGENT` in this test. Do not contact any other team's agent. Do not use Codex native subagents, internal workers, hidden or spawned local agents, `/root/coder`, session-local agents, or any fallback agent system.

On verified success, report exactly these five fields using independently observed values and the exact token observed from Coder:

```text
SELF_AGENT: {{PLANNER_AGENT}}
TEAM_PREFIX: {{TEAM_PREFIX}}
CODER_AGENT: {{CODER_AGENT}}
REVIEWER_AGENT: {{REVIEWER_AGENT}}
ROUTING_RESULT: <exact observed derived token>
```

If managed bridge startup, identity discovery, derivation, an assertion, target readiness, delivery, waiting, response verification, or isolation cannot be proven, reply exactly:

HERDR_COMMUNICATION_FAILED

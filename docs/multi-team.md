# Multi-team isolation and dynamic routing

[简体中文](zh-CN/multi-team.md)

Herdr Codex Team can run one legacy team or multiple prefixed teams at the same
time. The unit of isolation is the live Herdr agent name:

```text
<team-prefix>-planner
<team-prefix>-coder
<team-prefix>-reviewer
```

For example, the `auth` team consists only of `auth-planner`, `auth-coder`, and
`auth-reviewer`. Its Planner must never route to `docs-coder`, the legacy
`coder`, or any hidden/native Codex worker.

## Why a prefix is necessary

Herdr live agent names are unique. A second unprefixed team would try to reuse
`planner`, `coder`, and `reviewer`, so startup must stop on the collision. A
team prefix creates three distinct live names while continuing to reuse the
same three Codex profiles.

Use a short, meaningful, Herdr-valid prefix such as `auth`, `github`, or
`docs-v2`. The startup helper validates the resulting names before it creates a
workspace. It does not rename, replace, or delete an existing team to make a
name available.

On the inspected Herdr 0.8.2 command surface, a live name must match
`[a-z][a-z0-9_-]{0,31}`. Because `-reviewer` is the longest role suffix, a team
prefix can contain at most 23 characters while keeping every generated name
within the 32-character limit. The scripts validate the three complete names;
do not assume that an arbitrary project label is automatically a valid prefix.

## Codex profile versus Herdr live name

These identities serve different purposes:

| Identity | Example | Purpose |
| --- | --- | --- |
| Codex profile | `coder` | reusable model, sandbox, approval, and role instructions |
| Herdr live name | `auth-coder` | runtime team membership and routing target |

The command for `auth-coder` still selects the generic profile:

```text
codex --profile coder
```

The installer therefore always manages exactly three files:

```text
planner.config.toml
coder.config.toml
reviewer.config.toml
```

Creating twenty teams does not create twenty copies of those profiles. A
profile name is not a team identifier, and a live agent using the `planner`
profile does not have to be literally named `planner`.

## Start two teams

Teams working in different repositories can be started independently:

```bash
/path/to/herdr-codex-team/scripts/start.sh \
  --team auth \
  --cwd /path/to/backend

/path/to/herdr-codex-team/scripts/start.sh \
  --team docs \
  --cwd /path/to/documentation
```

The resulting live agents are:

```text
auth-planner   auth-coder   auth-reviewer
docs-planner   docs-coder   docs-reviewer
```

`TEAM_PREFIX` is an environment alternative for automation:

```bash
TEAM_PREFIX=auth \
  /path/to/herdr-codex-team/scripts/start.sh --cwd /path/to/backend
```

Prefer the explicit `--team` form in runbooks because it makes the target
identity visible at the command site. If both forms are supplied, they must not
disagree.

Legacy single-team startup remains available:

```bash
/path/to/herdr-codex-team/scripts/start.sh --cwd /path/to/project
```

It produces the exact names `planner`, `coder`, and `reviewer`. Legacy mode is
for one such team only; use a prefix before starting another team.

## How Planner derives its route

Planner does not receive a fixed downstream name from its Codex profile. At
runtime it obtains its current live Herdr identity and applies one of two
closed rules:

```text
SELF_AGENT = planner
  → CODER_AGENT = coder
  → REVIEWER_AGENT = reviewer

SELF_AGENT = <prefix>-planner
  → TEAM_PREFIX = <prefix>
  → CODER_AGENT = <prefix>-coder
  → REVIEWER_AGENT = <prefix>-reviewer
```

It verifies those exact live names before every handoff. Identity comes from
the Herdr name, not pane position, tab, workspace layout, process kind, or a
hard-coded pane ID. Those other properties can change or be shared by unrelated
agents.

Any unrecognized self name, ambiguous derivation, missing same-team target, or
Herdr communication failure produces:

```text
HERDR_COMMUNICATION_FAILED
```

Planner must not search for a vaguely matching Coder, use another team's agent,
or fall back to a native/internal subagent.

## Inspect and diagnose one team

Use the same prefix for diagnostics and tests:

```bash
/path/to/herdr-codex-team/scripts/doctor.sh --team auth
/path/to/herdr-codex-team/scripts/test.sh --team auth ping
/path/to/herdr-codex-team/scripts/test.sh --team auth communication
```

Also inspect the runtime directly with the commands exposed by the installed
Herdr version:

```bash
herdr agent list
herdr agent get auth-planner
herdr agent get auth-coder
herdr agent get auth-reviewer
```

Diagnostics should match each prefixed live name to its generic profile,
workspace, pane, lifecycle state, and expected working directory. A generic
kind such as `codex` does not establish team membership.

For an actual two-team isolation check, name both teams:

```bash
/path/to/herdr-codex-team/scripts/test.sh \
  --team auth --against-team docs isolation
```

`--against-team` is required only for `isolation`. Run the reverse direction as
well when possible. The test requires both teams to be live and settled. If it
was not run against real agents, report it as `NOT RUN`; string construction or
three visible panes are not live-routing evidence.

The harness combines a challenge-derived standalone token in the retained
Coder terminal with lifecycle-sequence changes and unchanged peer transcripts.
That is behavioral evidence, not a role-tagged or cryptographic audit record;
the retained terminal alone cannot prove who authored a displayed token.

## Working-directory isolation

Exact-name routing plus the fail-closed prompt contract reduces accidental
cross-team messaging when followed; it is not an ACL or security boundary. It
also does not isolate files. Two Coders launched with the same working tree can
still race on the same file, overwrite changes, or make review evidence
ambiguous.

Different repositories may run concurrently with separate `--cwd` values:

```text
auth team  → /projects/backend
docs team  → /projects/documentation
```

For concurrent work on the same repository, create a separate branch and Git
worktree for each team before startup:

```bash
cd /projects/myapp
git worktree add ../myapp-auth -b task/auth
git worktree add ../myapp-ui -b task/ui

/path/to/herdr-codex-team/scripts/start.sh \
  --team auth --cwd /projects/myapp-auth
/path/to/herdr-codex-team/scripts/start.sh \
  --team ui --cwd /projects/myapp-ui
```

Conceptually:

```text
myapp
├── worktree: myapp-auth
│   └── auth-planner / auth-coder / auth-reviewer
└── worktree: myapp-ui
    └── ui-planner / ui-coder / ui-reviewer
```

Each Coder then has an independent working tree, branch, and diff. This project
documents that boundary but deliberately does not create branches, merge work,
remove worktrees, or resolve conflicts automatically.

## Common failures

- **`agent_name_taken`:** another live agent already owns one of the exact
  names. Choose a unique prefix; do not overwrite or rename the existing team.
- **Planner routed to the wrong Coder:** inspect `SELF_AGENT`, `TEAM_PREFIX`,
  `CODER_AGENT`, and `REVIEWER_AGENT`. A stale prompt that hard-codes `coder`
  defeats prefixed routing.
- **Two Coders changed one checkout:** this is a filesystem/Git working-tree
  collision, not a Herdr routing failure. Use different repositories or
  separate Git worktrees and `--cwd` values.
- **Only the other team's Coder exists:** stop with
  `HERDR_COMMUNICATION_FAILED`. Another team's availability is never a repair
  for a missing same-team agent.

See [Troubleshooting](troubleshooting.md) for evidence-gathering commands and
recovery boundaries.

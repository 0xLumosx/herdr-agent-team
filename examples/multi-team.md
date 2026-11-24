# Multi-team examples

These examples assume the three generic Codex profiles are already installed.
Target paths may be existing Git worktrees or non-Git project directories;
Git-backed examples provide stronger diff and rollback evidence.

## One team, two projects

Use one primary project as the Herdr workspace cwd and repeat `--add-dir` for
every additional project:

```bash
/path/to/herdr-agent-team/scripts/start.sh \
  --team product \
  --cwd /projects/api \
  --add-dir /projects/web

/path/to/herdr-agent-team/scripts/doctor.sh --team product
```

After successful managed startup, the short Doctor command loads the safe
latest launch record and binds diagnostics to its recorded workspace, panes,
and ordered roots. For a deliberately replaced session or a direct scope
check, bypass that recorded workspace/pane binding with explicit roots:

```bash
/path/to/herdr-agent-team/scripts/doctor.sh \
  --team product \
  --cwd /projects/api \
  --add-dir /projects/web
```

Neither directory has to be a Git worktree. Planner and Coder receive both
roots under `workspace-write`; role policy still forbids Planner from editing.
Reviewer remains `read-only` and is launched without the writable-root
`--add-dir` grant, but can inspect both absolute paths. For every non-Git root,
record `Git evidence: NOT AVAILABLE` and inspect reported touched paths
directly; this does not prove the change set is complete.

## Two teams, two repositories

Start the backend team in one repository:

```bash
/path/to/herdr-agent-team/scripts/start.sh \
  --team backend \
  --cwd /projects/backend-api
```

Start the documentation team in another:

```bash
/path/to/herdr-agent-team/scripts/start.sh \
  --team docs \
  --cwd /projects/product-docs
```

The live topology is:

```text
/projects/backend-api
  backend-planner → backend-coder / backend-reviewer

/projects/product-docs
  docs-planner    → docs-coder / docs-reviewer
```

The teams can run at the same time. `backend-planner` must only address
`backend-coder` and `backend-reviewer`; `docs-planner` must only address its
`docs-*` peers.

Check each one explicitly:

```bash
/path/to/herdr-agent-team/scripts/doctor.sh --team backend
/path/to/herdr-agent-team/scripts/doctor.sh --team docs

/path/to/herdr-agent-team/scripts/test.sh --team backend communication
/path/to/herdr-agent-team/scripts/test.sh --team docs communication

/path/to/herdr-agent-team/scripts/test.sh \
  --team backend --against-team docs isolation
/path/to/herdr-agent-team/scripts/test.sh \
  --team docs --against-team backend isolation
```

The saved record is only latest-run diagnostic metadata. It does not supply
roots to a later `start.sh`, restore a task or conversation, or replace Herdr
as the live identity and communication authority.

## One repository, two Git worktrees

Agent names do not protect a shared filesystem. For two concurrent tasks in
the same repository, prepare one branch and worktree per team:

```bash
cd /projects/myapp
git worktree add ../myapp-auth -b task/auth
git worktree add ../myapp-ui -b task/ui
```

Then bind each team to its own checkout:

```bash
/path/to/herdr-agent-team/scripts/start.sh \
  --team auth \
  --cwd /projects/myapp-auth

/path/to/herdr-agent-team/scripts/start.sh \
  --team ui \
  --cwd /projects/myapp-ui
```

Now `auth-coder` and `ui-coder` have different working trees, branches, and
Git diffs. Merge or rebase those branches through the repository's normal
human-owned process. The startup scripts do not create, merge, or remove
worktrees.

## Legacy team

An unprefixed team remains supported:

```bash
/path/to/herdr-agent-team/scripts/start.sh --cwd /projects/single-task
```

That creates `planner`, `coder`, and `reviewer`. Because those live names are
globally unique, only one legacy team can exist at a time. Use prefixes for
additional teams.

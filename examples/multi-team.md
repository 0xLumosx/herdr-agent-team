# Multi-team examples

These examples assume the three generic Codex profiles are already installed
and the target paths are Git worktrees.

## Two teams, two repositories

Start the backend team in one repository:

```bash
/path/to/herdr-codex-team/scripts/start.sh \
  --team backend \
  --cwd /projects/backend-api
```

Start the documentation team in another:

```bash
/path/to/herdr-codex-team/scripts/start.sh \
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
/path/to/herdr-codex-team/scripts/doctor.sh --team backend
/path/to/herdr-codex-team/scripts/doctor.sh --team docs

/path/to/herdr-codex-team/scripts/test.sh --team backend communication
/path/to/herdr-codex-team/scripts/test.sh --team docs communication

/path/to/herdr-codex-team/scripts/test.sh \
  --team backend --against-team docs isolation
/path/to/herdr-codex-team/scripts/test.sh \
  --team docs --against-team backend isolation
```

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
/path/to/herdr-codex-team/scripts/start.sh \
  --team auth \
  --cwd /projects/myapp-auth

/path/to/herdr-codex-team/scripts/start.sh \
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
/path/to/herdr-codex-team/scripts/start.sh --cwd /projects/single-task
```

That creates `planner`, `coder`, and `reviewer`. Because those live names are
globally unique, only one legacy team can exist at a time. Use prefixes for
additional teams.

# Herdr Codex Team

[简体中文](README.zh-CN.md)

A small launcher and policy layer for running isolated three-agent Codex teams
in [Herdr](https://herdr.dev/):

```text
User -> Planner -> Coder -> Planner -> Reviewer -> Planner
```

Planner is the only orchestrator, Coder is the only intended source writer,
and Reviewer is independent and read-only. Live names carry team identity, for
example `dex-planner`, `dex-coder`, and `dex-reviewer`; routing to another team
fails closed.

This repository supplies profiles, role prompts, startup helpers, diagnostics,
and tests. Herdr remains the live runtime; this project is not a scheduler,
daemon, branch manager, or conversation store.

## Roles

| Role | Local filesystem | Responsibility |
| --- | --- | --- |
| Planner | read-only | Scope work, route only to its own Coder/Reviewer, and make the final decision |
| Coder | workspace-write | Implement focused changes and run relevant validation |
| Reviewer | read-only | Independently inspect requirements, changes, and evidence |

All three roles have command-network access, including SSH. See the security
warning below.

## Requirements

- Codex CLI, authenticated and able to use role profiles and permission profiles
- Herdr with named sessions and Codex integration
- Bash, Git, and Python 3; `jq` is preferred but Python is the JSON fallback
- For remote mode: OpenSSH and `tar` locally, plus the documented remote tools

The inspected baseline is Herdr 0.8.2 and Codex CLI 0.149.1. Scripts probe the
capabilities they require instead of pinning those versions. See
[Installation](docs/installation.md) for the full compatibility and remote-host
requirements.

## Quick start

Use the same short team name for the Herdr session and managed team. The
examples below use `dex`.

### Install once

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static && ./scripts/install.sh
```

Review `herdr integration status` before installing or updating Codex hooks.
If startup reports a missing integration, follow its explicit
`--install-integration` repair instruction.

### Local project

From a normal terminal, open the named Herdr session:

```bash
herdr --session dex
```

Then run this inside a shell pane in that Herdr window:

```bash
/path/to/herdr-codex-team/scripts/open.sh --team dex --cwd /path/to/project
```

For two or more project roots, add one `--add-dir` per extra root:

```bash
/path/to/herdr-codex-team/scripts/open.sh --team dex --cwd /path/to/app --add-dir /path/to/lib
```

`open.sh` creates or reuses the three agents in the current Herdr session; it
does not launch a separate Herdr window. Planner sees extra roots read-only,
Coder can write them, and Reviewer remains scoped to the primary root.

### Project on a remote server

Run `remote.sh` from the local repository. The UI stays local while Herdr,
Codex, and project files stay on the SSH host:

```bash
./scripts/remote.sh --host user@server --team dex --cwd /remote/project
```

Remote multi-project form:

```bash
./scripts/remote.sh --host user@server --team dex --cwd /remote/app --add-dir /remote/lib
```

The remote host needs Codex installed and authenticated, but it does not need
a checkout of this repository.

### Open the UI manually

If a live local session exists but no window is visible, run this from a fresh
normal local shell (nested attach is disabled):

```bash
herdr session attach dex
```

For a live remote session, use the same kind of fresh local shell:

```bash
herdr --remote user@server --session dex
```

Detach without ending the task by pressing `Ctrl+B`, then lowercase `q`.

### Check or completely end a task

Run Doctor inside the selected local Herdr session:

```bash
/path/to/herdr-codex-team/scripts/doctor.sh --team dex
```

To fully stop a local named session and remove its saved Herdr session state,
first detach, then run from a normal terminal:

```bash
herdr session stop dex && herdr session delete dex
```

To do the same on the remote host:

```bash
ssh -T user@server 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"; herdr session stop dex && herdr session delete dex'
```

Stopping ends that named session and its panes; deleting also removes its saved
Herdr session state. It does not remove project files, Codex history, or this
project's launch record. If several teams share one session, close only the
target workspace with `herdr --session dex workspace close <workspace-id>`
instead.

## Daily use

Run the same `open.sh` or `remote.sh` command to reuse a complete healthy team.
A missing team is created; a partial or policy-mismatched team is never silently
replaced. After changing managed profiles, prompts, or the Planner bridge, stop
the affected team, run `./scripts/install.sh`, and recreate it.

For concurrent tasks, use distinct team names and non-overlapping directories.
Tasks in the same Git repository should use separate worktrees and branches;
see [Multi-team isolation](docs/multi-team.md).

## Tests

```bash
./scripts/test.sh static
./scripts/test.sh --team dex ping
./scripts/test.sh --team dex communication
```

`static` needs no live team. Run live modes from the intended Herdr session and
watch the exact named panes. `full`, `policy`, and bidirectional `isolation`
have stricter Git and multi-team prerequisites described in
[Workflow](docs/workflow.md) and [Troubleshooting](docs/troubleshooting.md).
Static or transport tests do not prove filesystem attribution or physical/HIL
safety.

## Security

All profiles use `approval_policy = "never"`. Planner and Reviewer remain
locally read-only, but every role has broad outbound command-network access;
it is not restricted to SSH, one host, or port 22. A locally read-only role can
still change or stop services on a remote host through SSH.

Use dedicated low-privilege remote accounts and keys, pin `known_hosts`, disable
agent/port/X11 forwarding, keep secrets out of prompts, and inspect changes
before merging. Read [Security](docs/security.md) before using this setup on
sensitive code or operational systems.

## Documentation

- [Installation](docs/installation.md) and [Configuration](docs/configuration.md)
- [Architecture](docs/architecture.md) and [Workflow](docs/workflow.md)
- [Launch state](docs/launch-state.md) and [Multi-team isolation](docs/multi-team.md)
- [Security](docs/security.md) and [Troubleshooting](docs/troubleshooting.md)
- [Comparison with oh-my-codex](docs/omx-comparison.md)
- Examples: [simple task](examples/simple-task.md), [full task](examples/full-development-task.md), [multiple teams](examples/multi-team.md)

## Uninstall

```bash
./scripts/uninstall.sh
```

The uninstaller backs up and removes only project-managed profiles. It does not
remove Codex, Herdr, credentials, live sessions, worktrees, or the base Codex
configuration.

## License

[MIT](LICENSE) · [Changelog](CHANGELOG.md)

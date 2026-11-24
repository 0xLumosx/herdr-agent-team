# Herdr Agent Team

[简体中文](README.zh-CN.md)

Run three agents in separate [Herdr](https://herdr.dev/) panes. Give the task to Planner. Coder edits the project, Reviewer checks the changes independently, and Planner decides whether the work is ready. You can follow each handoff in the team's panes.

## Quick start

### Open a team in the current directory

From the project you want to work on, run:

```bash
herdr --team
```

A new team starts Codex in all three panes. Planner fills the left half, Coder runs at the top right, and Reviewer at the bottom right. Running the command again from the same directory reopens the team. To switch one role, exit its CLI and type `claude`, `gemini`, or `codex` at that pane's shell prompt. `gemini` starts Antigravity CLI. Switching back resumes that role's previous conversation in the group.

The locally translated build of Herdr displays menus and settings in Chinese and keeps theme and product names in their original form. To open a new session in English, run `HERDR_LANG=en herdr --team`.

To enable the shortcut on another machine, link this checkout's `scripts/herdr-team` into PATH as `herdr-team` and source `scripts/team-shell.sh` from your interactive Bash or Zsh startup file. The explicit launch commands below also accept a team name, project directory, or initial CLI selection.

### Install the local team profiles

You need Bash, Git, Python 3, and the signed-in CLIs selected for your roles. Codex roles require role and permission profiles. Herdr needs named sessions and the integrations for your selected CLIs. The scripts use `jq` to parse JSON when available and Python otherwise.

In a normal terminal, run the static checks and install the three role profiles and Planner's communication bridge. Substitute your own directories for the example paths.

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static && ./scripts/install.sh
```

The local launcher, three-role layout and linked conversation recovery have been verified on macOS with Herdr 0.9.5 and Codex CLI 0.171.0. The original compatibility baseline used Herdr 0.8.2 with Codex CLI 0.149.1. Earlier recovery tests used Herdr 0.8.2 with Codex CLI 0.160.1 and 0.171.0. The startup scripts check the features they need. Check `herdr integration status` before installing or updating Codex hooks. If startup reports a missing integration, review the proposed changes before using `--install-integration`. [Installation and compatibility](docs/installation.md)

### Open your project

From a normal terminal, open a named Herdr session. Giving the session and team the same short name makes it easier to reconnect later. These examples use `dex`.

```bash
herdr --session dex
```

In a shell pane **inside the Herdr window**, run `open.sh` with the directory you want to work on.

```bash
/path/to/herdr-codex-team/scripts/open.sh --team dex --cwd /path/to/project
```

For a task that spans several projects, use the next command instead. Supply one `--add-dir` for each extra directory. Planner can read those directories, Coder can write to them, and Reviewer's scope stays on the primary directory.

```bash
/path/to/herdr-codex-team/scripts/open.sh --team dex --cwd /path/to/app --add-dir /path/to/lib
```

Once the team is ready, enter your task in the `dex-planner` pane. Planner sends work only to `dex-coder` and `dex-reviewer`. The handoff stops if Planner cannot confirm the other agent belongs to this team. [First task example](examples/simple-task.md)

### Choose a CLI for each role

New teams default to Codex. To run a Claude Planner, Codex Coder, and Gemini Reviewer, enter this command in the Herdr shell pane:

```bash
REVIEWER_MODEL=gemini-3.8-flash-high ./scripts/open.sh --team dex --cwd /path/to/project \
  --planner-cli claude --coder-cli codex --reviewer-cli agy
```

Each role accepts `codex`, `claude`, or `agy`. Run `agy models` to see the models available to your account. Complete sign-in and first-run setup for each selected CLI. If Herdr reports a missing integration, add `--install-integration` to install the selected hooks.

Use `/resume` in the Planner to select a linked conversation. When both workers are idle, they switch to their saved sessions. Reopening a running team uses its recorded CLIs. To recover an earlier group, use its team name, workspace roots, and role CLIs. Register older, unlinked chats with `--link-current PLANNER_UUID CODER_UUID REVIEWER_UUID`.

For remote project work, give the Planner the SSH alias and directory. Coder works in that remote directory, and Reviewer can read the changed files and Git diff over SSH. The SSH destination follows the linked conversation. [Team SSH configuration](docs/configuration.md)

## How the team works

```text
User -> Planner -> Coder -> Planner -> Reviewer -> Planner
```

| Role | Local filesystem | Responsibility |
| --- | --- | --- |
| Planner | read-only | Define the scope, assign implementation and review, and decide whether to accept the result |
| Coder | workspace-write | Edit project files and run checks for the changes |
| Reviewer | read-only | Compare the changes and the available test evidence with the original requirements |

Herdr runs the panes and sessions. This repository supplies role profiles, prompts, on-demand launch scripts, diagnostics, and tests. You manage branches in Git. Each CLI keeps its own conversation history. For model defaults, reasoning effort, and the Stop That Shit skill required for Codex roles, see [Role configuration](docs/configuration.md).

## Daily use

### Leave, reconnect, or check the team

To leave the UI while the agents keep working, press `Ctrl+B`, release it, then press lowercase `q`. To reconnect to that session, run the following in a normal local terminal outside Herdr. Nested attach is disabled by default.

```bash
herdr session attach dex
```

To return to a saved group of conversations, use `/resume` in `dex-planner` and pick its previous chat, or enter `/resume <Planner UUID>`. Coder and Reviewer resume their linked chats in their own panes. Each pane shows its current thread ID in the footer. Planner checks all three IDs before sending work. See [conversation recovery](docs/launch-state.md#conversation-recovery) to link older chats.

To check the team, run Doctor in a shell pane of the selected local session.

```bash
/path/to/herdr-codex-team/scripts/doctor.sh --team dex
```

Running the same `open.sh` command reuses the team once all three agents pass the checks. If all three are absent, the launcher creates them in the current window. If some are missing or their configuration differs from the expected policy, it reports the problem and leaves the team available for inspection. [Troubleshooting](docs/troubleshooting.md)

After changing profiles, prompts, or the Planner bridge, stop the affected team, run `./scripts/install.sh` from this repository, and recreate the team with its original project directories. Concurrent teams need distinct names and non-overlapping directories. For parallel tasks in one Git repository, give each team its own worktree and branch. [Multi-team isolation](docs/multi-team.md)

### End a task

If several teams share a session, use `herdr --session dex workspace close <workspace-id>` to close just the target workspace. To end the entire local session, first detach, then run the following from a normal terminal.

```bash
herdr session stop dex && herdr session delete dex
```

Stopping the session ends all its pane processes. Deleting it removes the saved Herdr session state. Your project files, CLI conversation histories, and team launch record are preserved. [Launch state](docs/launch-state.md)

## Projects on an SSH host

Run `remote.sh` from this repository in a normal local terminal. Herdr opens the UI on your machine. All three agents run on the SSH host and work directly on its project files. You need OpenSSH and `tar` locally. The remote host needs the CLIs selected for the three roles, their sign-ins, and the tools listed in the installation guide. The launcher sends the files it needs, so a separate remote checkout is optional.

```bash
./scripts/remote.sh --host user@server --team dex --cwd /remote/project
```

For a task spanning multiple remote directories, supply the extra paths at launch. Run the same `remote.sh` command later to reuse a healthy team.

```bash
./scripts/remote.sh --host user@server --team dex --cwd /remote/app --add-dir /remote/lib
```

To reconnect to a running remote session, use a normal local terminal outside Herdr.

```bash
herdr --remote user@server --session dex
```

To stop the entire remote session and delete its saved state, run this from a normal local terminal.

```bash
ssh -T user@server 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"; herdr session stop dex && herdr session delete dex'
```

## Tests

Run these commands from this repository. You can run `static` before starting a team. Run `ping` and `communication` in a shell pane of the intended Herdr session. The former messages Coder and Reviewer directly. The latter sends work through Planner. Watch the named panes for their replies.

```bash
./scripts/test.sh static
./scripts/test.sh --team dex ping
./scripts/test.sh --team dex communication
```

The `full`, `policy`, and bidirectional `isolation` tests have additional Git or multi-team prerequisites. Attributing file writes to a process and establishing physical or hardware-in-the-loop (HIL) safety require separate evidence. [Test workflow](docs/workflow.md) · [Troubleshooting tests](docs/troubleshooting.md)

## Permissions and security

All three profiles use `approval_policy = "never"`, so commands run without per-command approval. Each role can connect to multiple hosts and use protocols and ports other than SSH on port 22. Planner and Reviewer have read-only access to local project files. Over SSH, the remote account's permissions determine whether they can edit files or stop services.

Use dedicated low-privilege remote accounts and keys, pin `known_hosts`, and disable SSH agent, port, and X11 forwarding. Keep secrets out of prompts and inspect changes before merging. Read the [Security guide](docs/security.md) before using the team on sensitive code or operational systems.

## Documentation and examples

| Topic | Further reading |
| --- | --- |
| How the roles hand off and review work | [Architecture](docs/architecture.md) · [Workflow](docs/workflow.md) · [Comparison with oh-my-codex](docs/omx-comparison.md) |
| Running a task or working in parallel | [Full development task](examples/full-development-task.md) · [Multi-team isolation](docs/multi-team.md) · [Multiple teams](examples/multi-team.md) |
| Host requirements and permissions | [Installation](docs/installation.md) · [Security](docs/security.md) |

## Uninstall

Run the uninstaller from this repository.

```bash
./scripts/uninstall.sh
```

The script moves the managed profiles and Planner bridge into a dated backup. Codex, Herdr, credentials, live sessions, Git worktrees, and your base Codex configuration stay in place.

[MIT](LICENSE) · [Changelog](CHANGELOG.md)

# Installation and startup

[简体中文](zh-CN/installation.md)

This is the detailed runbook behind the README Quick start. The normal entry
points are `open.sh` for local projects and `remote.sh` for projects on an SSH
host. Re-run the same command to reuse a complete healthy live Team.

## Requirements

The inspected baseline is Herdr 0.8.2 and Codex CLI 0.149.1. The scripts check
the capabilities they use and fail closed on incompatible behavior.

Local requirements:

- Bash, Git, Python 3, Codex, and Herdr;
- `jq`, or Python 3 as the JSON parser fallback;
- OpenSSH and `tar` for remote mode;
- a completed Codex login on every machine where Codex agents will run.

All project paths must already exist, resolve to absolute paths, and must not
be `/`. Requested primary and additional roots must not overlap physically.

## First install

Run this once for a local `CODEX_HOME`, before starting a Team:

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static && ./scripts/install.sh
```

The static check validates the managed files and current CLI surface without
contacting a live Agent. Installation writes three reusable role profiles and
the Planner bridge under `${CODEX_HOME:-$HOME/.codex}`. It does not start a
Team.

If startup reports `INTEGRATION_REQUIRED`, review the stated hook and Codex
configuration changes, ensure the selected Herdr session has no live Agent,
then explicitly opt in:

```bash
/path/to/herdr-codex-team/scripts/open.sh \
  --install-integration \
  --team dex-vut \
  --cwd /absolute/path/to/Dex_Teleop
```

## Local project

From a fresh, normal local shell, open a named Herdr session. Reusing the Team
name keeps later attach and stop commands unambiguous:

```bash
herdr --session dex-vut
```

Do not run this attach command inside an existing Herdr pane; nested Herdr is
disabled. In a shell pane managed by that Herdr session, open one project:

```bash
/path/to/herdr-codex-team/scripts/open.sh \
  --team dex-vut \
  --cwd /absolute/path/to/Dex_Teleop
```

For two projects, add the second root explicitly:

```bash
/path/to/herdr-codex-team/scripts/open.sh \
  --team dex-vut \
  --cwd /absolute/path/to/Dex_Teleop \
  --add-dir /absolute/path/to/vut_hub-0.2.0
```

`--add-dir` is repeatable. Planner receives each extra root as read-only
workspace context, Coder receives it as writable context, and Reviewer remains
on the primary root. All three roles have managed command network enabled.

`open.sh` has three outcomes:

- all three expected names are absent: create the Team;
- all three exist and pass Doctor: reuse them without restart;
- only part exists, or validation fails: stop without replacing anything.

Verify a managed Team after startup:

```bash
/path/to/herdr-codex-team/scripts/doctor.sh --team dex-vut
/path/to/herdr-codex-team/scripts/test.sh --team dex-vut ping
/path/to/herdr-codex-team/scripts/test.sh --team dex-vut communication
```

After entering or attaching the intended session, use the same `open.sh`
command to create or reuse the Team. Reattach the UI with the commands below;
a saved launch record does not store or restore a Codex conversation.

## Remote project

The remote host needs Codex, Herdr, Bash, Git, Python 3, `tar`, and the project
directories. Authenticate Codex on the remote host first. The remote host does
not need a checkout of this repository; `remote.sh` streams a checked launcher
bundle into a private temporary directory and removes it afterward.

From a fresh, normal local shell:

```bash
cd /path/to/herdr-codex-team
./scripts/remote.sh --host user@server --team dex-vut --cwd /home/user/workspace/Dex_Teleop

# Multi-project:
./scripts/remote.sh --host user@server --team dex-vut --cwd /home/user/workspace/Dex_Teleop --add-dir /home/user/workspace/vut_hub-0.2.0
```

The paths after `--cwd` and `--add-dir` are remote absolute paths. The local
terminal renders the Herdr UI; the panes, Codex processes, and project files
remain on `user@server`.

If first-time remote Herdr setup opens an initial UI, press `Ctrl+B`, release
it, then press lowercase `q`. That detaches only that client; `remote.sh` then
continues automatically. If remote Codex integration is missing, the script
describes the global hook/configuration change and asks before installing it.

If the UI does not open automatically, attach manually from a fresh, normal
local shell, never from inside another Herdr pane:

```bash
herdr --remote user@server --session dex-vut
```

Re-run the same `remote.sh` command for normal daily reuse. The named remote
session and all three Agent processes must still be alive for the original
panes and conversation to remain available.

## Detach, resume, and completely stop

Detaching is not stopping:

```text
Ctrl+B, then lowercase q
```

This closes only the current interface. Panes and Agents continue in the
selected Herdr session. Reattach from a fresh local shell with:

```bash
# Named local session
herdr session attach dex-vut

# Named remote session
herdr --remote user@server --session dex-vut
```

Do not attach from an existing Herdr pane; nested attach is disabled.

Choose a stop command only after resolving the exact scope:

```bash
# Stop one local Team workspace while leaving other workspaces and the session.
herdr --session dex-vut workspace list
herdr --session dex-vut workspace close w9

# Stop and then delete one named session on the host that owns it.
herdr session stop dex-vut
herdr session delete dex-vut

# The default session can also be named explicitly.
herdr session stop default
```

`herdr workspace close <workspace_id>` is the narrow operation for a Team that
owns one verified workspace in a shared session. `herdr session stop <name>`
stops that selected session; `herdr session delete <name>` then removes its
saved session state. Replace the example `w9` only with the workspace ID printed
by startup or `workspace list`; neither command guesses from a Team name.

For a remote named Team, run the session cleanup on the remote host with the
same PATH used by `remote.sh`:

```bash
ssh -T user@server 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"; herdr session stop dex-vut && herdr session delete dex-vut'
```

`herdr server stop` stops every pane in the currently selected server/session
namespace. It is not a one-workspace command. It does not stop every other
named session, but it can still terminate unrelated work in the selected
namespace; never use it merely to leave the UI or stop one Team.

## Repair and update

`open.sh` never overwrites a partial or unhealthy Team. If managed profiles or
the Planner bridge are missing or drifted, first ensure there is no live Agent
anywhere in the selected Herdr session, then request the backed-up repair:

```bash
/path/to/herdr-codex-team/scripts/open.sh \
  --repair-profiles \
  --team dex-vut \
  --cwd /absolute/path/to/Dex_Teleop \
  --add-dir /absolute/path/to/vut_hub-0.2.0
```

For remote mode, add `--repair-profiles` to the same `remote.sh` command. Do not
use it while the selected session contains a live Agent.

After changing profile, prompt, bridge, or startup policy source:

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static && ./scripts/install.sh
```

Then recreate only the intended Team with its original `--team`, `--cwd`, and
ordered `--add-dir` values. Running Codex sessions do not hot-reload managed
files or launch policy.

## Security boundary

Planner and Reviewer keep a local `read-only` filesystem boundary; Coder uses
`workspace-write`. Command network is enabled for all three roles so SSH works.
That network grant is broad, not limited to SSH or one host. Local read-only
does not prevent an SSH command from changing a remote host, and
`approval_policy = "never"` provides no routine interactive checkpoint.

Use dedicated low-privilege remote accounts and keys, pinned `known_hosts`,
`BatchMode=yes`, `IdentitiesOnly=yes`, and no agent, port, or X11 forwarding.
See [Security](security.md) for the complete boundary. Doctor proves the launch
policy, not remote-host safety or successful hardware/HIL validation.

## Uninstall

Inspect and run the recoverable uninstaller only after handling any live Team:

```bash
cd /path/to/herdr-codex-team
./scripts/uninstall.sh
```

It handles managed files; it is not a Herdr Team or session stop command.

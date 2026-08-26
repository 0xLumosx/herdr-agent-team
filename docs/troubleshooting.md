# Troubleshooting

[简体中文](zh-CN/troubleshooting.md)

## Start with evidence

Do not restart, repair, rename, or stop anything until the target Team and
scope are explicit. Capture:

```bash
/path/to/herdr-codex-team/scripts/doctor.sh --team dex-vut
herdr agent list
herdr agent get dex-vut-planner
herdr agent read dex-vut-planner --source recent-unwrapped --lines 120
```

If the saved launch record is absent or stale, bypass its workspace/pane IDs
with the exact startup roots in the original order:

```bash
/path/to/herdr-codex-team/scripts/doctor.sh \
  --team dex-vut \
  --cwd /absolute/path/to/Dex_Teleop \
  --add-dir /absolute/path/to/vut_hub-0.2.0
```

This is a diagnostic override only. Do not edit `current.json` to hide a
mismatch.

## The UI did not open, or nested Herdr is disabled

Manual attach commands must run in a fresh, normal local shell, not inside an
existing Herdr pane:

```bash
# Named local session
herdr session attach dex-vut

# Named remote session
herdr --remote user@server --session dex-vut
```

Nested attach is disabled. If you only want to leave the interface, press
`Ctrl+B`, release it, then press lowercase `q`. That detaches the client; panes
and Agents continue.

## `TEAM_UNSAFE` reports missing or drifted managed files

The helper intentionally did not overwrite anything. Review the reported
paths under `${CODEX_HOME:-$HOME/.codex}`. After ensuring there is no live Agent
anywhere in the selected Herdr session, rerun the same command with
`--repair-profiles`:

```bash
/path/to/herdr-codex-team/scripts/open.sh \
  --repair-profiles \
  --team dex-vut \
  --cwd /absolute/path/to/Dex_Teleop \
  --add-dir /absolute/path/to/vut_hub-0.2.0
```

For remote mode, add `--repair-profiles` to the same `remote.sh` command. The
installer backs up replaced managed paths. Do not repair around a live Agent.

## `INTEGRATION_REQUIRED` or a changed hook

Herdr Codex integration can change executable hooks, `hooks.json`, and Codex
configuration. Review the reported change first. With no live Agent in the
selected session, rerun the same `open.sh` or `remote.sh` command with
`--install-integration`. Do not treat a new hook as a routine profile repair.

## `agent_name_taken`, `TEAM_PARTIAL`, or `START_PARTIAL`

These are fail-closed outcomes. The helper does not replace an existing name
or clean up a partial workspace automatically.

```bash
herdr agent list
herdr agent get <exact_live_name>
herdr agent read <exact_live_name> --source recent-unwrapped --lines 120
```

Preserve the printed workspace and pane IDs. Resolve only the verified target
Team. Do not rename another Team's Agent, infer identity from pane position, or
run a broad server stop.

## SSH reports `port 22: Operation not permitted`

The running Codex process was not launched with the current managed command
network policy. A live process does not hot-reload launch arguments.

1. Preserve task context and project changes.
2. Fully stop only the exact old Team scope; see the stop commands below.
3. Re-run the current `open.sh` or `remote.sh` command with the original roots.
4. Run Doctor before retrying SSH.

Do not add legacy `--sandbox`, `sandbox_workspace_write`, or
`danger-full-access` overrides. Current startup keeps Planner/Reviewer locally
read-only, keeps Coder workspace-write, and enables command network for all
three. Doctor verifies the effective model-visible filesystem sandbox and
network state.

Passing Doctor does not prove remote reachability or safety. Command network is
broad, local read-only does not restrict remote SSH side effects, and
`approval_policy = "never"` adds no routine confirmation step. Use a dedicated
low-privilege remote account, pinned `known_hosts`, `BatchMode=yes`, and no
agent, port, or X11 forwarding.

## Planner reports `Operation not permitted` for Herdr communication

This is different from TCP/SSH denial. Some Linux sandboxes reject direct
AF_UNIX access to Herdr. Planner must use the managed `herdr_codex_team` stdio
bridge and its bounded `inspect_team`/`prompt_agent` tools.

Run Doctor to check the installed Planner profile and bridge digest. Do not
make Planner writable or expose an arbitrary shell/Herdr MCP server.

## `start.sh` cannot reach the Herdr server

For a named local session, open or attach it from a fresh shell:

```bash
herdr --session dex-vut
```

For a named remote session:

```bash
herdr --remote user@server --session dex-vut
```

Do not run either attach command inside a Herdr pane. For remote failures,
check ordinary SSH and the remote PATH used by the launcher:

```bash
ssh user@server 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"; command -v herdr; herdr --version'
```

Re-run the same `remote.sh` command after correcting setup. Do not use SSHFS or
copy a second repository checkout as a recovery path.

## Doctor rejects the launch record or additional roots

Use the exact `--team`, primary `--cwd`, and ordered `--add-dir` list from
startup. Planner and Coder must carry that exact ordered additional-root list;
Reviewer must carry no `--add-dir`. Missing, extra, reordered, malformed,
overlapping, or stale roots fail validation.

If two concurrent Teams need the same Git repository, give them separate
worktrees. A different branch in the same physical worktree is not isolation.
Non-Git roots have weaker attribution evidence and must be reported as such.

## Profile or policy changes have no effect

Running Codex sessions do not reload managed files or launch arguments. After
preserving work:

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static && ./scripts/install.sh
```

Then stop only the intended Team and recreate it with the same `--team`,
`--cwd`, and ordered `--add-dir` options. A plain `codex --profile ...` launch
followed by a Herdr rename is not a managed restart.

## Agent is `blocked`, `unknown`, or unexpectedly idle

Inspect before sending input:

```bash
herdr agent get <exact_live_name>
herdr agent read <exact_live_name> --source recent-unwrapped --lines 120
```

- `blocked` means an approval or question UI was detected. Do not answer it on
  the user's behalf.
- `unknown` means classification is uncertain, not that work completed.
- `idle`/`done` after a prompt is useful only when lifecycle changed and the
  expected output or repository evidence is present.

## Reviewer cannot create temporary files

Reviewer is intentionally `read-only`. The managed profile disables common
pytest cache and bytecode writes, but tests requiring `tmp_path`, compiler
output, coverage data, or application scratch files can still be impossible
inside that boundary. Report the limitation; do not grant Reviewer write
access as a workaround.

## Ping or live tests fail

Run increasingly strong checks only when their prerequisites exist:

```bash
./scripts/test.sh --team dex-vut ping
./scripts/test.sh --team dex-vut communication
./scripts/test.sh --team dex-vut full
./scripts/test.sh --team dex-vut policy
```

`ping` checks direct reachability. `communication` requires all targets settled
and proves a Planner-mediated round trip. `full` and `policy` require their
documented Git-clean fixture conditions; they must not run against a dirty or
hardware-facing worktree merely to obtain a green result. Isolation testing
requires two real, disjoint Teams. Report `NOT RUN` when prerequisites are
absent.

## Stop the exact scope

First distinguish detach, one workspace, one named session, and the current
server/session namespace.

```bash
# Narrow: close one verified Team workspace in a shared session.
herdr --session dex-vut workspace list
herdr --session dex-vut workspace close w9

# On the host that owns it: stop and delete one named session.
herdr session stop dex-vut
herdr session delete dex-vut

# The default session can be named explicitly.
herdr session stop default
```

For complete cleanup of a remote named Team:

```bash
ssh -T user@server 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"; herdr session stop dex-vut && herdr session delete dex-vut'
```

`herdr server stop` stops every pane in the currently selected server/session
namespace. It does not stop all other named sessions, but it is still too broad
for one Team workspace. Replace `w9` only with the verified workspace ID; never
use a broad server stop merely to detach.

## Doctor reports a missing command on a newer version

A newer version number does not prove compatibility. Read the current binary's
relevant `--help`, preserve the exact failure, and update the helper only after
verifying the changed command contract. The safe result is a failed startup,
not an assumed fallback.

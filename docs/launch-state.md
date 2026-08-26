# Launch state

[简体中文](zh-CN/launch-state.md)

Herdr Codex Team stores one small, user-local record for the latest workspace
created for each team identity. This record improves diagnosis and restart
reconstruction without becoming a task database or a second runtime.

## Location and permissions

With the default `CODEX_HOME=~/.codex`, a prefixed Team uses:

```text
~/.codex/herdr-codex-team/state/v1/
├── startup.lock/                 # normally transient; unsafe stale owners remain
└── teams/
    ├── legacy/current.json
    └── prefixed-<team-prefix>/current.json
```

State directories are mode `0700`; `current.json` and the lock owner file are
mode `0600`. Every path component managed below `$CODEX_HOME` must be a real
directory rather than a symlink. The state contains absolute project paths, so
do not publish it in issues or commits without redaction.

No state is written into a primary project, an `--add-dir` project, `.git`, or
`.omx`. `install.sh` and `uninstall.sh` do not copy, upload, or delete it.

## Record contents

`current.json` has `schema_version: 1` and records:

- one per-invocation `run_id`, `started_at`, `updated_at`, and the last launch
  observation: `starting`, `partial`, or `ready`;
- legacy/prefixed Team identity and exact Planner/Coder/Reviewer live names;
- the physical primary cwd and ordered additional roots;
- whether the root set includes degraded non-Git evidence;
- the Herdr workspace ID and each pane ID once that pane is observed;
- each role's expected sandbox.

The file deliberately contains no task prompt, response, terminal transcript,
diff, source content, token, approval, task completion, or Reviewer decision.
Only the latest created run is retained for each Team. `run_id` correlates
fields written by one helper invocation; it is not injected into Herdr and is
not proof that a later live process belongs to that recorded run.

The file is generated in the Team state directory, set to `0600`, and renamed
over `current.json`. A reader therefore sees the old complete file or the new
complete file, not a normal partial write. Doctor validates the complete file
before using it.

## Authority

| Fact | Authoritative owner |
| --- | --- |
| live workspace, pane, agent identity, lifecycle, prompt transport | Herdr |
| role profile, permission-profile argv, effective sandbox/network, and additional-root argv | the live Codex process |
| current code and change evidence | Git or the filesystem |
| values previously written by this startup helper | the launch record |

The record is an expectation to verify. It cannot make an absent Agent live,
grant filesystem access, reserve a root after startup, prove delivery, or
restore a Codex conversation.

## Doctor behavior

After one successful managed startup, the short form is sufficient:

```bash
./scripts/doctor.sh --team github
```

Doctor loads the latest record only when neither `--cwd` nor `--add-dir` is
provided. It then resolves the recorded roots again and requires the live
names, workspace ID, every non-empty recorded pane ID, cwd, profiles,
sandboxes, and ordered additional-root argv to match. Herdr remains
authoritative: a mismatch reports stale or different runtime identity rather
than rewriting either side.

The explicit form bypasses recorded workspace/pane binding and verifies the
requested live scope directly:

```bash
./scripts/doctor.sh \
  --team github \
  --cwd /absolute/path/to/primary-project \
  --add-dir /absolute/path/to/second-project
```

Use the explicit form to diagnose a deliberately replaced session or a stale
record. It does not modify or delete the saved record.

Malformed, oversized, unsupported-schema, symlinked, or wrong-Team state fails
before Doctor contacts Herdr. Missing state preserves the previous behavior:
Doctor checks live Team identity but has no saved multi-root expectation unless
explicit roots are supplied.

## Startup lock

Current `start.sh` processes using the same `CODEX_HOME` share one short-lived
lock under that state root. The lock begins before live-name and complete-root
preflight and is released when the helper exits after attempting to record its
result. This closes the check/create race only between concurrent current
helpers in that namespace.

The owner record contains a local host, PID, run ID, Team display name, and an
owner token. A same-host owner whose PID is still alive causes immediate
failure. A dead same-host owner is atomically renamed to a unique quarantine
before its known owner file is removed; unexpected content is preserved for
inspection. A malformed owner or a different/unknown host fails closed.

This lock is not:

- a per-root lease held for the life of a Team;
- an operating-system ACL or process sandbox;
- protection against older helpers, manual Herdr operations, or external
  writers;
- serialization with a current helper using a different `CODEX_HOME`, even if
  both connect to the same Herdr server;
- evidence that only Coder changed a file.

After startup, exact live-name and complete-root inspection remains the managed
collision guard. Concurrent work in one repository still requires separate
user-created worktrees per Team.

## Recovery boundary

If the original three Codex processes are still live, use Herdr to return to
those exact panes; only those sessions retain their conversations. If they have
been replaced, the launch record can help verify roots and distinguish the old
workspace/panes, but the new sessions have no restored conversation. Rebuild
the task from Git evidence or reported non-Git touched paths and send a new
self-contained handoff.

`partial` means only that startup created a workspace but did not complete and
persist a `ready` conclusion. The live roles may still be ready. Inspect the
recorded IDs and live Herdr state. Do not rerun startup blindly, auto-stop the
workspace, or interpret `partial` as task progress.

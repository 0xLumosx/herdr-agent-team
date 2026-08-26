# Comparison with oh-my-codex

[简体中文](zh-CN/omx-comparison.md)

This document records a design comparison, not a dependency or compatibility
claim. The inspected upstream checkpoint is
[`Yeachan-Heo/oh-my-codex@3ad79a8`](https://github.com/Yeachan-Heo/oh-my-codex/tree/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2).
The implementations have different runtime owners and different workflow
goals.

## Summary

| Area | oh-my-codex (OMX) | Herdr Codex Team | Decision here |
| --- | --- | --- | --- |
| Team model | dynamic `N:agent-type` workers, task decomposition, claims, status, await, resume, and shutdown | exactly one Planner, one Coder, and one Reviewer | keep the fixed role topology and Planner-only orchestration |
| Runtime | OMX coordinates workers and uses tmux for the recommended interactive team mode | Herdr owns visible workspaces, panes, live names, lifecycle, and prompt transport | do not add a second scheduler, multiplexer, or runtime |
| Communication | durable mailbox/inbox plus dispatch and worker task state | synchronous Herdr delivery plus exact live names and `TASK_ID`/`ROUND`/`HANDOFF_ID` readback | keep Herdr as the only transport; retain correlation and fail-closed delivery semantics |
| State | `.omx/state` contains authoritative team, task, worker, mailbox, dispatch, event, and monitor state | a user-local launch record contains only startup provenance and expected live binding | borrow schema, atomic write, per-invocation correlation, and explicit ownership; do not create a workflow database |
| Worktrees | a Team normally provisions a dedicated worktree for each worker | all three roles inspect one Team root set; concurrent Teams must use disjoint roots or user-created per-Team worktrees | do not create per-role worktrees or manage branches automatically |

## `$team`

OMX `$team` is a complete dynamic worker runtime rather than a different
spelling of this project's `start.sh`. It launches a variable worker set,
decomposes work, exposes a machine-readable API, and manages task transitions.
See the upstream
[`$team` skill](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/skills/team/SKILL.md)
and
[`team` CLI](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/src/cli/team.ts).

This project deliberately keeps a smaller Interface:

```text
start.sh --team <prefix> --cwd <primary> [--add-dir <root>]...
doctor.sh --team <prefix> [--cwd <primary> [--add-dir <root>]...]
```

The topology is always Planner → Coder → Reviewer. `start.sh` still means
fresh, fail-closed creation; it does not decompose a task, choose workers,
resume a workflow, or replace a partial Team.

## Agent communication

OMX separates durable message state from worker notification. Mailbox and
dispatch objects carry identifiers and distinct delivery states; task claims
and worker acknowledgements belong to the OMX runtime. See the upstream
[`worker` contract](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/skills/worker/SKILL.md),
[`mailbox` implementation](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/src/team/state/mailbox.ts),
and
[`team` state contracts](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/src/team/contracts.ts).

Herdr Codex Team already has a closed-loop protocol suited to one sequential
Coder and one Reviewer:

- Planner addresses only exact same-Team live Herdr names;
- every normal task has one stable `TASK_ID`;
- each handoff has a fresh `HANDOFF_ID` and bounded `ROUND`;
- Coder and Reviewer must echo the correlation fields before their response is
  interpreted;
- an uncertain or mismatched delivery stops with
  `HERDR_COMMUNICATION_FAILED`.

A second mailbox would create two transport owners and ambiguous retry rules.
The launch record therefore stores no prompt, response, task state, approval,
or claim. Herdr delivery, the live pane, the correlated response, and the
resulting filesystem state remain separate evidence.

## `.omx` state and the local launch record

OMX's state model is broad and authoritative for its runtime. It uses schemas,
atomic writes, locks, task versions, claim tokens, events, and explicit field
ownership. See upstream
[`STATE_MODEL.md`](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/docs/STATE_MODEL.md),
[`state operations`](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/src/state/operations.ts),
and
[`state locks`](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/src/team/state/locks.ts).

The useful ideas adopted here are intentionally narrower:

1. a per-invocation `run_id` correlates fields written by one helper run; it is
   not injected into Herdr and does not establish live identity;
2. `current.json` has an explicit schema and is replaced by a same-directory
   temporary-file rename;
3. exact ordered roots, live names, workspace ID, and pane IDs are recorded;
4. `doctor.sh --team <prefix>` may load those values as expectations, then
   re-check every value against Herdr and Codex process arguments;
5. malformed, oversized, or symlinked state fails closed before Doctor contacts
   Herdr.

The record lives under `$CODEX_HOME`, not under `.omx`, `.git`, or any primary
or additional project root. It is authoritative only for what this startup
helper previously wrote. It cannot prove that a Team is live, a message was
delivered, a task is complete, a Reviewer passed the change, or a particular
agent wrote a file. See [Launch state](launch-state.md).

## Worktree isolation

OMX can create, validate, reuse, and roll back a worktree for each worker. Its
Git path checks and plan-before-mutation structure are valuable engineering
references; see upstream
[`worktree.ts`](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/src/team/worktree.ts).

Per-worker worktrees are wrong for this workflow. Reviewer must inspect Coder's
current uncommitted changes, while Planner performs final inspection of the
same state. Splitting those roles into three worktrees would hide the change or
require an automated commit/merge channel, which would change both authority
and evidence. It would also break supported dirty, non-Git, and multi-root
projects.

The retained rule is per-Team isolation:

- all three roles in one Team observe the same ordered root set;
- concurrent Teams must have disjoint effective root sets;
- concurrent work in one Git repository should use user-created branches and
  worktrees, one worktree per Team;
- this project never automatically stashes, commits, creates or deletes a
  branch, merges, rebases, cherry-picks, or force-removes a worktree.

## Optimizations implemented from the comparison

- A user-local, schema-versioned launch record with `starting`, `partial`, and
  `ready` observations.
- Atomic current-record replacement and private state permissions.
- A per-invocation correlation ID stored alongside exact Team, root, workspace,
  and pane observations, all of which still require live verification.
- State-backed Doctor checks that fail on stale workspace or pane identity.
- A startup lock that serializes current `start.sh` processes using the same
  `CODEX_HOME` across live-name/root preflight and workspace creation. Same-host
  dead owners can be quarantined and recovered without recursively deleting a
  directory.

The startup lock is short-lived. It is not a persistent root lease, filesystem
ACL, writer-attribution mechanism, or guard against older scripts, manual Herdr
commands, other tools, remote hosts, or current helpers using a different
`CODEX_HOME`. Live-agent root inspection remains the longer-lived guard.

## Explicitly not adopted

- dynamic workers, task DAGs, claims, heartbeats, approvals, and rebalancing;
- tmux or another production runtime Adapter;
- `.omx` task/mailbox/event state copied into project roots;
- a second mailbox, dispatch queue, or Coder-to-Reviewer channel;
- automatic retries after uncertain delivery;
- per-role worktrees or automatic Git lifecycle management;
- claims that a launch record restores a Codex conversation.

No OMX source code was copied into this implementation; the design was
implemented independently. The pinned upstream tree did not contain a
LICENSE/COPYING file, which is an additional reason to keep this a documented
comparison of ideas rather than a code import.

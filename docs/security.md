# Security

[简体中文](zh-CN/security.md)

## Security posture

Herdr Codex Team coordinates agents that can execute commands. Locally, only
Coder can write inside the requested project roots; all three roles can open
outbound command-network connections and may therefore cause remote side
effects through SSH or another client. The project reduces ambiguity through
visible routing, least-role filesystem permissions, bounded review, and Git
evidence where available. It does not turn language-model prompts into a
hardened security boundary.

Use the project only after understanding the effective authority of each layer:

```text
Herdr identity   which visible live agent receives a message
Team prefix      which exact same-team names Planner may address
Codex sandbox    what tool operations can access
Command network  whether shell commands can reach external hosts
Approval policy  whether Codex pauses at ordinary approval points
Role prompt      what behavior the model is instructed to follow
Change evidence  Git diff, or non-Git touched paths plus explicit gaps
```

## `approval_policy = "never"`

All three default profiles set:

```toml
approval_policy = "never"
```

In current Codex CLI, `never` means Codex does not stop to request approval before ordinary operations; an operation that cannot run under the active policy fails back to the agent. It does not mean “no sandbox,” and it does not grant access denied by the sandbox.

The tradeoff is important: automated handoffs do not stall at routine prompts, but the user loses an interactive checkpoint before potentially consequential commands that are already permitted. Review the role prompt, repository instructions, hooks, and sandbox before startup.

See the [official Codex configuration reference](https://developers.openai.com/codex/config-reference/), [permissions guide](https://learn.chatgpt.com/docs/permissions), and [sandbox and approval guidance](https://developers.openai.com/codex/agent-approvals-security/).

## Sandbox matrix

| Role | Local filesystem | Command network | Residual risk |
| --- | --- | --- | --- |
| Planner | `read-only` | enabled | can prompt same-team peers and can change a remote host through an allowed network client |
| Coder | `workspace-write` | enabled | can make destructive or unrelated local changes within allowed roots and remote changes through a network client |
| Reviewer | `read-only` | enabled | can expose sensitive content and can change a remote host through an allowed network client |

The statement “only Coder writes source” is sandbox-enforced for both Planner
and Reviewer under managed startup. Planner's bridge contains no filesystem
tool and accepts only same-team identity inspection plus role-only Coder or
Reviewer prompts. This does not prove that an unmanaged same-user process,
unsafe hook, or compromised installed bridge cannot write; non-Git evidence
also remains incomplete.

Reviewer's managed Python environment avoids pytest's own default capture,
cache, and bytecode writes; it does not add a writable exception to the
sandbox. A test suite that needs temporary files, build output, coverage data,
or write-dependent plugins remains outside what Reviewer can validate. This is
reported as a limitation rather than silently granting scratch or workspace
write access.

Every repeatable `--add-dir` expands only Coder's managed writable path set.
Planner receives the same path as read-only workspace context; Reviewer
receives none. Their managed permission profile extends `:read-only`, while
Coder's extends `:workspace`. All three named beta
permission profiles enable command network. Startup repeats the exact
`default_permissions`, `extends`, and `network.enabled=true` settings and does
not pass the legacy `--sandbox` or `sandbox_workspace_write.writable_roots`
overrides. On the supported CLI these legacy arguments can conflict with or
suppress the intended effective policy.
All role profiles also set `agents.enabled = false`, and startup repeats the
setting as an exact CLI override. This removes Codex-native collaboration tools
that could otherwise create hidden `/root/*` workers; Planner's bounded Herdr
MCP tools remain available. Doctor verifies the live argv, so a role process
started under the older policy is rejected until the Team is recreated.
Startup and Doctor also inspect the effective model-visible filesystem sandbox
and network state. An incompatible permission-profile implementation or a
conflicting legacy argument fails closed rather than silently starting a role
without the requested combination.
After a managed startup, `doctor.sh --team <prefix>` can load the safe latest
launch record and verify that role-specific launch argv plus the recorded
workspace and pane identities. Supplying `--cwd` (and any ordered `--add-dir`)
bypasses the recorded workspace/pane binding and verifies the requested live
scope directly. Either form provides argv evidence, not proof that a particular
read or write occurred.

`danger-full-access` is not a project default. Do not enable it to work around `Operation not permitted`, missing hooks, a wrong `CODEX_HOME`, or an incompatible CLI. Diagnose the specific boundary instead.

## SSH authority and safer defaults

The command-network grant is intentionally broad enough for an ordinary SSH
client. It is not limited to SSH, port 22, or a configured hostname. A local
`read-only` sandbox controls local filesystem operations only: once an SSH
session is established, the remote account, server ACLs, and remote command
determine what can change. Because `approval_policy = "never"` has no routine
interactive checkpoint, a permitted SSH command can take effect immediately.

For every role that may use SSH:

- use a dedicated low-privilege remote account and task-specific key; keep the
  private key and host details out of this repository;
- pin the host key in a controlled `known_hosts` file and keep
  `StrictHostKeyChecking=yes`; never work around verification with
  `StrictHostKeyChecking=no`;
- use `BatchMode=yes` and `IdentitiesOnly=yes` for deterministic non-interactive
  failure;
- disable agent forwarding, port forwarding, and X11 forwarding, for example
  with `ForwardAgent=no`, `ClearAllForwardings=yes`, and `ForwardX11=no`;
- constrain the remote account with server-side ACLs, forced commands, or a
  dedicated environment when the task does not require a general shell.

These controls reduce remote authority; they do not convert the broad local
network grant into a host allowlist. Managed startup validation proves the
launch policy, not that a particular remote host is safe or that an SSH action
was read-only.

## Threats this project does not eliminate

- **Prompt injection from the repository:** source files, issues, generated logs, or tests can contain instructions intended to redirect an agent.
- **Unsafe commands inside allowed roots:** Coder can remove or corrupt writable files even without full host access; Planner can also send an unsafe implementation request to same-team Coder.
- **Degraded non-Git evidence:** a non-Git root has no authoritative baseline,
  complete diff, untracked-file inventory, rollback point, or reliable way to
  separate pre-existing changes from task changes. A best-effort touched-path
  list is not a substitute.
- **Untrusted hooks or integrations:** a hook executes outside the semantic role contract and can change when software is updated.
- **Secret disclosure:** agents can read accessible credentials, `.env` files, proprietary source, or logs and reproduce them in terminals or reports.
- **False reports:** an agent can claim tests passed or another agent responded; verify against process state, command output, Git where available, and direct inspection of reported non-Git touched paths otherwise.
- **Profile-source authenticity:** SHA-256 markers detect installed prompt or
  policy drift relative to the current checkout. They are not signatures: a
  writer that can change the checkout and installed files can change both, so
  the markers do not establish trusted provenance or resist a malicious local
  writer.
- **Shared-scope races:** startup compares each team's complete managed root
  set. Git-backed paths use their physical worktree root and non-Git paths use
  their physical directory root; same, ancestor, or descendant overlaps fail
  closed. Current `start.sh` processes using the same `CODEX_HOME` also share
  one short-lived lock around managed preflight and Herdr workspace/agent
  creation, closing the check/create race only between those helpers. The lock
  is not a filesystem ACL, per-root reservation, Team-lifetime lease, or
  Herdr-wide transaction. Different `CODEX_HOME` namespaces, humans, external
  tools, older helpers, manual Herdr operations, or agents outside the
  recognized naming scheme can still make attribution and review unreliable.
- **Bridge/configuration compromise:** the bridge rejects arbitrary names and
  derives only exact same-team peers, but a writer that can replace the source,
  installed bridge, profile, and matching digests can change that policy.
- **Dependency and test side effects:** repository commands can contact networks, mutate external services, or run untrusted build steps within their available permissions.
- **Remote-host side effects:** every managed role can use command network, and
  local filesystem read-only does not prevent writes, service changes, or
  process control authorized by the remote SSH account.

The independent Reviewer improves defect detection but is not a security scanner, formal verifier, or isolation boundary.

The full integration test is also not a writer-attribution or filesystem audit.
It requires challenge-derived Coder and Reviewer success responses, unchanged
fixture history, exactly one expected fixture diff, and an otherwise Git-clean
committed host whose Git-visible status, branch, and `HEAD` remain unchanged,
plus script-owned assertions, fixture tests, and Planner's run-specific
approval. The harness also disables user-level Git signing and hooks for its
own baseline commit. It does not detect changes to ignored host files, so its
host must be disposable and contain no sensitive ignored state. Managed
Planner and Reviewer are read-only, but those observations still cannot prove
at a cryptographic level that no unmanaged process produced a byte.
Repositories that require hard attribution need external process/filesystem
auditing beyond the current project.

## Recommended operating procedure

Before managed startup:

1. use a clean branch or disposable worktree when possible; give every
   concurrent team a disjoint complete root set, and use a separate worktree
   and `--cwd` for concurrent tasks in one repository;
2. commit or safely preserve the baseline;
3. remove secrets that the task does not need;
4. inspect repository-level agent instructions and scripts;
5. review Codex profile overrides and Herdr hooks.

Immediately after managed startup:

1. run team-aware `doctor.sh --team <prefix>` against
   its safe latest launch record, or supply the same `--cwd` and every ordered
   `--add-dir` for a direct scope check, then run the matching communication
   tests;
2. confirm Planner and Reviewer remain `read-only`, and the Planner bridge
   matches the current checkout.

During work:

- watch that Herdr routes to the intended live name;
- verify Planner's `SELF_AGENT`, `TEAM_PREFIX`, `CODER_AGENT`, and
  `REVIEWER_AGENT` if routing is in doubt;
- do not auto-answer an agent in a blocked approval/question state;
- reject unexpected changes immediately and preserve evidence;
- keep Coder and Reviewer from bypassing Planner;
- treat test output and external-service changes according to their actual risk.

Before merging a Git-backed change:

```bash
git status --short
git diff
git diff --staged
```

Review every changed file, rerun critical validation in a trusted shell, and check for credentials or generated artifacts. `APPROVED` is an agent decision, not a substitute for repository ownership controls or human review required by your organization.

For every non-Git root, record `Git evidence: NOT AVAILABLE`, inspect the
reported touched paths directly, and retain the limitation that change-set
completeness and pre-existing attribution remain unproved. If the primary cwd
is non-Git, report the Git-hosted `full` and `policy` modes as `NOT RUN`.
`ping`, `communication`, and `isolation` remain only bounded routing evidence;
they do not repair the missing filesystem history.

## Hooks and trust

Codex may report that a hook is new or changed after Herdr integration installation or update. Treat that as a security event requiring inspection, not an onboarding nuisance.

Confirm:

- the file path is under the expected user configuration;
- the source is the intended Herdr installation;
- the command and referenced scripts are understandable;
- no unexpected network, credential, or destructive operation is present;
- the change matches the update you initiated.

Do not use a dangerous hook-trust bypass for normal interactive setup.

## Backups and local configuration

`install.sh` backs up existing target profiles and the managed Planner bridge before replacement. Backups can contain private model providers, endpoints, paths, or instructions. They remain under `$CODEX_HOME` and should not be committed, uploaded, or included in bug reports without redaction.

Repository templates must never contain API keys, access tokens, private SSH targets, or user-specific configuration copied from a real machine.

`uninstall.sh` moves managed role profiles and the Planner bridge into a new timestamped backup and leaves earlier backups, the base configuration, credentials, and unrelated hooks intact. Removing those is a separate user-owned security decision.

Managed startup also stores one latest-run record per Team under
`$CODEX_HOME/herdr-codex-team/state/v1`. Its directories use mode `0700`, and
`current.json` plus the short-lived startup-lock owner file use mode `0600`.
Those modes limit ordinary local access; they are not encryption, a sandbox, or
an ACL against a process already acting as the same user. The record contains
absolute project paths and Herdr workspace/pane IDs, so treat it as private and
redact it before sharing. It contains no task prompt, transcript, source,
Reviewer decision, or conversation state, and it does not participate in Agent
communication: Herdr remains the only live identity and prompt-transport
authority. `uninstall.sh` deliberately leaves these records in place; inspect
and remove them separately only when you intend to discard the diagnostic
history. See [Launch state](launch-state.md).

## Sensitive repositories

For regulated, safety-critical, credential-bearing, or otherwise sensitive projects, validate this workflow in a disposable non-sensitive repository first. Apply organizational access control, network isolation, required human approval, and audit policy independently of this project.

Managed startup gives Planner a direct `read-only` filesystem boundary and a
bridge that exposes no file operation. This is materially stronger than a
prompt-only rule, but it is not a tamper-proof same-user security boundary: a
writer able to replace the checkout, installed bridge, profiles, and digests
can alter the policy. Repositories requiring audited writer attribution still
need external process/filesystem controls.

Team prefixes do not change that boundary and do not isolate the filesystem.
Two name-isolated teams whose primary or additional roots overlap can still
race. For concurrent tasks on one repository, create independent branches and
Git worktrees before starting the teams, and keep every additional root
disjoint as well. This project deliberately does not automate worktree
creation, merge, removal, or conflict resolution.

## Reporting a vulnerability

Do not publish secrets or an exploitable report in a public issue. Once the repository has a public hosting location, prefer its private security-advisory channel. Until then, contact the maintainers privately and include the affected version, minimal reproduction, impact, and suggested mitigation.

# Security

[简体中文](zh-CN/security.md)

## Security posture

Herdr Codex Team coordinates agents that can execute commands and, for two roles, write inside one or more project roots. It reduces ambiguity through visible routing, least-role permissions, bounded review, and Git evidence where available. It does not turn language-model prompts into a hardened security boundary.

Use the project only after understanding the effective authority of each layer:

```text
Herdr identity   which visible live agent receives a message
Team prefix      which exact same-team names Planner may address
Codex sandbox    what tool operations can access
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

See the [official Codex configuration reference](https://developers.openai.com/codex/config-reference/) and [sandbox and approval guidance](https://developers.openai.com/codex/agent-approvals-security/).

## Sandbox matrix

| Role | Default | Reason | Residual risk |
| --- | --- | --- | --- |
| Planner | `workspace-write` | Herdr communication may fail under `read-only` | prompt forbids source edits, but filesystem capability still exists |
| Coder | `workspace-write` | implementation requires repository writes | can make destructive or unrelated changes within allowed roots |
| Reviewer | `read-only` | independent inspection requires no writes | can still expose sensitive content in its output or call allowed read-only services |

The statement “only Coder writes source” is fully sandbox-enforced for Reviewer, but only policy-enforced for Planner. A model can violate a prompt. Planner's final inspection of the available Git/non-Git change evidence helps detect that violation after the fact; it does not prevent it, and non-Git evidence is not complete.

Every repeatable `--add-dir` expands the managed writable path set for Planner
and Coder. They can technically write the primary cwd and each additional root
under `workspace-write`; Planner's no-edit rule remains prompt policy. Reviewer
is explicitly launched with `--sandbox read-only` and no `--add-dir`, so it can
inspect the requested roots without receiving an additional writable-root
grant. Startup first supplies `sandbox_workspace_write.writable_roots=[]` to
neutralize additional writable roots inherited from user or profile
configuration, then adds the requested roots only to Planner and Coder.
`doctor.sh` verifies that role-specific launch argv when called with the same
`--cwd` and ordered `--add-dir` list, but argv evidence is not proof that a
particular read or write occurred.

`danger-full-access` is not a project default. Do not enable it to work around `Operation not permitted`, missing hooks, a wrong `CODEX_HOME`, or an incompatible CLI. Diagnose the specific boundary instead.

## Threats this project does not eliminate

- **Prompt injection from the repository:** source files, issues, generated logs, or tests can contain instructions intended to redirect an agent.
- **Unsafe commands inside allowed roots:** Coder and Planner can remove or corrupt writable files even without full host access.
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
  closed. The preflight is not an atomic lock. Humans, external tools,
  post-check races, or agents outside the recognized naming scheme can still
  make attribution and review unreliable.
- **Cross-team prompt failure:** prefixes create explicit routes, but a
  compromised or incorrectly configured Planner can still attempt to address
  another live team; fail-closed prompts and isolation tests reduce rather than
  cryptographically eliminate this risk.
- **Dependency and test side effects:** repository commands can contact networks, mutate external services, or run untrusted build steps within their available permissions.

The independent Reviewer improves defect detection but is not a security scanner, formal verifier, or isolation boundary.

The full integration test is also not a writer-attribution or filesystem audit.
It requires challenge-derived Coder and Reviewer success responses, unchanged
fixture history, exactly one expected fixture diff, and an otherwise Git-clean
committed host whose Git-visible status, branch, and `HEAD` remain unchanged,
plus script-owned assertions, fixture tests, and Planner's run-specific
approval. The harness also disables user-level Git signing and hooks for its
own baseline commit. It does not detect changes to ignored host files, so its
host must be disposable and contain no sensitive ignored state. Since Planner
has `workspace-write`, those observations cannot prove at the operating-system
or cryptographic level that Coder alone produced every byte. Repositories that
require hard attribution need external process/filesystem auditing and an
isolation design beyond the current project.

## Recommended operating procedure

Before starting:

1. use a clean branch or disposable worktree when possible; give every
   concurrent team a disjoint complete root set, and use a separate worktree
   and `--cwd` for concurrent tasks in one repository;
2. commit or safely preserve the baseline;
3. remove secrets that the task does not need;
4. inspect repository-level agent instructions and scripts;
5. review Codex profile overrides and Herdr hooks;
6. run team-aware `doctor.sh` with the same `--cwd` and every `--add-dir`, then
   the matching communication tests;
7. confirm Reviewer remains `read-only`.

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

`install.sh` backs up existing target profiles before replacement. Backups can contain private model providers, endpoints, paths, or instructions. They remain under `$CODEX_HOME` and should not be committed, uploaded, or included in bug reports without redaction.

Repository templates must never contain API keys, access tokens, private SSH targets, or user-specific configuration copied from a real machine.

`uninstall.sh` moves managed role profiles into a new timestamped backup and leaves earlier backups, the base configuration, credentials, and unrelated hooks intact. Removing those is a separate user-owned security decision.

## Sensitive repositories

For regulated, safety-critical, credential-bearing, or otherwise sensitive projects, validate this workflow in a disposable non-sensitive repository first. Apply organizational access control, network isolation, required human approval, and audit policy independently of this project.

If your policy requires a hard guarantee that Planner cannot write source, the
current Planner design is not sufficient: its `workspace-write` sandbox is a
deliberate Herdr-compatibility compromise. Use an external isolation design
that exposes only the Herdr communication endpoint and read-only repository
view, or do not use this workflow for that repository.

Team prefixes do not change that boundary and do not isolate the filesystem.
Two name-isolated teams whose primary or additional roots overlap can still
race. For concurrent tasks on one repository, create independent branches and
Git worktrees before starting the teams, and keep every additional root
disjoint as well. This project deliberately does not automate worktree
creation, merge, removal, or conflict resolution.

## Reporting a vulnerability

Do not publish secrets or an exploitable report in a public issue. Once the repository has a public hosting location, prefer its private security-advisory channel. Until then, contact the maintainers privately and include the affected version, minimal reproduction, impact, and suggested mitigation.

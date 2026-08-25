# 工作流

[English](../workflow.md)

## 不变量

每个任务遵守五条不变量：

1. Planner 是唯一编排者和最终决策者。
2. Coder 是唯一预期修改应用源码的角色。
3. Reviewer 独立、只读，绝不实现修复。
4. Legacy Team 使用精确实时名称 `planner`、`coder` 和 `reviewer`；带前缀的 Team 只使用 `<prefix>-planner`、`<prefix>-coder` 和 `<prefix>-reviewer`。
5. Planner 只编排从自己当前 Herdr 实时身份推导出的精确 Coder 和 Reviewer。

如果无法建立身份或同 Team 路由，Planner 以以下内容停止：

```text
HERDR_COMMUNICATION_FAILED
```

它不会选择相似名称 Agent、使用另一个 Team 的可用角色、启动 Codex native subagent、hidden worker、`/root/coder`、`/root/reviewer` 或任何其他 fallback。

## Runtime Team 身份

任务开始时和每次 handoff 前，Planner 都获取当前 Herdr 实时名称。只接受以下两种形式：

```text
SELF_AGENT = planner
  TEAM_PREFIX = (legacy, empty)
  CODER_AGENT = coder
  REVIEWER_AGENT = reviewer

SELF_AGENT = <prefix>-planner
  TEAM_PREFIX = <prefix>
  CODER_AGENT = <prefix>-coder
  REVIEWER_AGENT = <prefix>-reviewer
```

Planner 通过 Herdr 验证两个精确下游名称。Team 身份永远不来自 pane position、fixed pane ID、current tab/workspace 或 process kind。如果 `auth-coder` 缺失而 `docs-coder` 存在，结果仍是 `HERDR_COMMUNICATION_FAILED`。

## 1. 用户交给 Planner

用户向 Planner 提供 goal、constraint 和 observable success condition。Planner 在选择设计前读取仓库，并检查 invalid premise、missing information、conflicting requirement 和现有 uncommitted work。

Planner 的计划必须识别：

- 用户可见 outcome；
- 相关现有 architecture 和 file；
- 显式 non-goal；
- acceptance criteria；
- 与风险匹配的 validation；
- 可能改变实现的 assumption。

Planner 可以根据仓库证据解决 low-risk ambiguity。如果未解决的选择会实质改变 scope 或 behavior，它应询问用户，而不是隐藏 assumption。

## 2. Planner 交给 Coder

发送工作前，Planner 通过 Herdr 确认精确推导出的 live target。Handoff 是自包含的，并应采用以下结构：

```text
ROLE: Live Herdr agent `<CODER_AGENT>`
TEAM: `<TEAM_PREFIX>` (or `legacy`)
TASK_ID: `<整个用户任务保持稳定>`
ROUND: `<1 到 4>`
HANDOFF_ID: `<本次交接全新>`

Goal:
...

Repository context:
...

Required behavior:
...

Acceptance criteria:
1. ...
2. ...

Constraints and non-goals:
- ...

Validation to run:
- ...

Report contract:
Return IMPLEMENTATION_DONE or BLOCKED using the Coder role format.
Do not contact Reviewer or start another agent.
```

Coder 先读后改，完成最小而完整的变更，避免无关清理。它运行 focused test，以及适用的 typecheck、lint 或 build command。

成功时，Coder 返回：

```text
IMPLEMENTATION_DONE
TASK_ID: <精确回显交接值>
ROUND: <精确回显交接值>
HANDOFF_ID: <精确回显交接值>

Summary:
...

Files changed:
...

Validation:
...

Assumptions:
...

Remaining concerns:
...
```

无法继续时，返回 `BLOCKED`，并给出精确 missing input、failing command、error 和 safe next step。它绝不宣布 `APPROVED`。

## 3. Planner 验证实现

Planner 将 Coder report 视为线索，而不是证明。对每个 Git-backed root，它至少读取：

```bash
git status --short
git diff
git diff --staged
```

对每个 non-Git root，Planner 记录 `Git evidence: NOT AVAILABLE`，检查 Coder 最大努力提供的 touched-path inventory 与这些文件，并持续说明完整 baseline、diff、untracked-file scope、rollback point 和预存变更归属不可用。直接检查不能弥补这些缺口。

Planner 把可用的 changed-file 和 validation evidence 与计划比较。如果 Coder 修改无关文件或可用证据实质不完整，Planner 会在审查前向 Coder 发送聚焦修正。

Planner 不能通过自己编辑源码来“节省一轮”。它的 `workspace-write` sandbox 是为了 Herdr 兼容，不是实现权限。

## 4. Planner 交给 Reviewer

Planner 确认精确同 Team live Reviewer，再发送自包含 brief：

```text
ROLE: Live Herdr agent `<REVIEWER_AGENT>`
TEAM: `<TEAM_PREFIX>` (or `legacy`)
TASK_ID: `<与 Coder 相同的 task id>`
ROUND: `<与被审实现相同的 round>`
HANDOFF_ID: `<全新且不同于 Coder 的 handoff id>`

Original goal:
...

Acceptance criteria:
1. ...
2. ...

Constraints and non-goals:
- ...

Coder report:
...

Validation evidence:
...

Review scope:
- for every Git-backed root, inspect git status and the actual diff
- for every non-Git root, record Git evidence as NOT AVAILABLE and inspect the
  reported touched paths directly
- read changed files and relevant surrounding code
- assess correctness, regression, security, error handling, compatibility,
  state/data consistency, edge cases, and test quality

Return only PASS or CHANGES_REQUIRED using the Reviewer role format.
Do not modify files and do not contact Coder.
```

Reviewer 独立检查仓库。它不能仅因偏好不同 style 而拒绝代码。每个 blocking finding 必须描述真实工程后果。

Coder 与 Reviewer 都必须在首行状态之后立即精确回显这三个关联字段。缺失、乱序、复用或不匹配时，Planner 在解释响应正文前按 `HERDR_COMMUNICATION_FAILED` 停止。

`CHANGES_REQUIRED` finding 使用：

```text
Severity: CRITICAL | HIGH | MEDIUM | LOW
Location: path and tight line or symbol reference
Problem: what is objectively wrong or missing
Why it matters: concrete consequence or failed criterion
Recommended correction: bounded direction, not an implementation takeover
```

`LOW` 默认不阻塞。只有不再存在 blocking finding，且可用证据充分时，Reviewer 才返回 `PASS`。

## 5. Planner 分诊 Finding

Planner 将每条 finding 与 requirement 和代码核对。它可以拒绝 factually wrong、outside scope、purely preferential 或 unsupported finding，并记录原因，而不是自动转发每条 comment。

已接受的 correction 会作为一个合并后的自包含任务返回 Coder。Reviewer 从不直接向 Coder 发送指令。

## 6. 轮次上限

一轮是：

```text
Coder 实现或修复 → Reviewer 审查 → Planner 分诊
```

初次实现是第 1 轮，最多四轮。如果第 4 轮后结果仍不能通过，Planner 停止：

```text
NOT APPROVED

Remaining issues:
...

Coder position:
...

Reviewer position:
...

Planner recommendation:
...
```

轮次上限不是降低 acceptance bar 的理由，而是将控制权连同明确 unresolved state 交回用户的理由。

## 7. 最终 Sanity Check

Reviewer `PASS` 不会自动批准任务。Planner 最终检查：

- Git-backed root 的实际 Git diff 和意外文件；
- non-Git root 所报 touched path 和明确的证据不可用限制；
- 每项 acceptance criterion；
- 声称的 test、typecheck、lint 和 build result；
- 与变更相符的 compatibility 和 rollback concern；
- 是否仍有任何 material assumption 未验证。

完成后 Planner 才可返回 `APPROVED`，并总结变更、验证和剩余 non-blocking risk。

## 通信语义

在已检查的 Herdr 0.8.2 surface 中，Planner 向精确推导出的名称提交工作。例如对 `auth-planner`：

```bash
herdr agent prompt auth-coder "<self-contained task>" --wait --timeout 120000
```

`--wait` 观察 lifecycle state，而不是 cryptographically bound request/response turn。如果 Agent 已经在工作，它的当前 turn 就可能满足 wait。因此工作流组合 self-identity derivation、exact target-name verification、visible pane observation、run-specific test 和 result inspection，而不是把单个 signal 当作决定性证据。

如果 target 是 `blocked`，检查 Agent state 和可见 terminal。不要代替用户自动回答 approval 或 question。

## 中断后恢复

不要仅仅因为 Planner 或 Herdr 重启就丢弃或 reset 项目文件。恢复中的 Planner 应：

1. 恢复用户 goal 和 acceptance criteria；
2. 对每个 Git-backed root 运行 `git status`、`git diff` 和 `git diff --staged`；对 non-Git root 记录 `Git evidence: NOT AVAILABLE`，并直接检查上次所报 touched-path inventory；
3. 检查 validation artifact 和当前 process；
4. 使用 startup 时相同的有序 root 列表运行 `doctor.sh --team <prefix> --cwd <primary> --add-dir <extra> ...`（或 legacy 不带前缀形式），确认三个精确实时名称和受管 process scope；
5. 判断 Coder 是否必须继续，或 Reviewer 是否可以检查现有 Git/non-Git 变更证据；
6. 发送新的自包含 handoff。

项目不持久化 formal state machine。基于人类可读文件的 checkpoint 是可能的未来扩展，不是当前工作流的 hidden dependency。并发 Team 和 Git worktree 指南见[多 Team 隔离](multi-team.md)。

Multi-root 访问改变证据，不改变权限：Coder 仍是策略上唯一允许修改项目文件的角色；Planner 仍具有技术上的 `workspace-write` 能力，但禁止将其用于实现；Reviewer 的 sandbox 在每个 root 上仍为 `read-only`。

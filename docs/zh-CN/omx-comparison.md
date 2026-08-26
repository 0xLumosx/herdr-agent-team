# 与 oh-my-codex 的比较

[English](../omx-comparison.md)

本文记录设计比较，不表示依赖或兼容性。检查的上游版本是
[`Yeachan-Heo/oh-my-codex@3ad79a8`](https://github.com/Yeachan-Heo/oh-my-codex/tree/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2)。
两个项目的 runtime 所有者和工作流目标不同。

## 总结

| 方面 | oh-my-codex（OMX） | Herdr Codex Team | 本项目决策 |
| --- | --- | --- | --- |
| Team 模型 | 动态 `N:agent-type` worker、任务拆分、claim、status、await、resume 和 shutdown | 固定一个 Planner、一个 Coder、一个 Reviewer | 保留固定角色拓扑和 Planner 唯一编排权 |
| Runtime | OMX 协调 worker；推荐的交互 Team 模式使用 tmux | Herdr 拥有可见 workspace、pane、实时名称、lifecycle 和 prompt transport | 不增加第二套 scheduler、multiplexer 或 runtime |
| 通讯 | 持久 mailbox/inbox、dispatch 和 worker task state | Herdr 同步投递、精确实时名称和 `TASK_ID`/`ROUND`/`HANDOFF_ID` 回读 | Herdr 保持唯一 transport；保留相关性和 fail-closed 语义 |
| 状态 | `.omx/state` 保存权威 Team、task、worker、mailbox、dispatch、event 和 monitor 状态 | 用户本地启动记录只保存启动 provenance 与预期 live binding | 借鉴 schema、原子写、每次 helper 调用的相关标识和明确所有权；不创建工作流数据库 |
| Worktree | Team 通常为每个 worker 创建独立 worktree | 一个 Team 的三角色检查同一 root set；并发 Team 使用互斥 root 或用户创建的 per-Team worktree | 不创建 per-role worktree，也不自动管理 branch |

## `$team`

OMX `$team` 是完整的动态 worker runtime，不是本项目 `start.sh` 的另一种写法。它会启动可变 worker 集、拆分工作、暴露 machine-readable API，并管理 task transition。参见上游
[`$team` skill](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/skills/team/SKILL.md)
和
[`team` CLI](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/src/cli/team.ts)。

本项目刻意保留更小的 Interface：

```text
start.sh --team <prefix> --cwd <primary> [--add-dir <root>]...
doctor.sh --team <prefix> [--cwd <primary> [--add-dir <root>]...]
```

拓扑始终是 Planner → Coder → Reviewer。`start.sh` 仍表示 fresh、fail-closed 创建；它不拆分任务、不选择 worker、不恢复工作流，也不替换 partial Team。

## Agent 通讯

OMX 把持久消息状态与 worker notification 分开。Mailbox 和 dispatch object 具有标识符和不同 delivery state；task claim 与 worker ACK 属于 OMX runtime。参见上游
[`worker` contract](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/skills/worker/SKILL.md)、
[`mailbox` 实现](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/src/team/state/mailbox.ts)
和
[`team` 状态 contract](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/src/team/contracts.ts)。

Herdr Codex Team 已有适合单 Coder、单 Reviewer 串行链路的闭环协议：

- Planner 只能寻址精确的同 Team Herdr 实时名称；
- 每个普通任务使用一个稳定 `TASK_ID`；
- 每次 handoff 使用新的 `HANDOFF_ID` 和有上限的 `ROUND`；
- Coder 和 Reviewer 必须先回显相关字段，Planner 才解释正文；
- 投递不确定或字段不匹配时，以 `HERDR_COMMUNICATION_FAILED` 停止。

第二套 mailbox 会造成两个 transport owner 和有歧义的重试规则。因此启动记录不保存 prompt、response、task state、approval 或 claim。Herdr 投递、实时 pane、相关 response 和最终 filesystem state 始终是不同证据。

## `.omx` 状态与本地启动记录

OMX 的状态模型范围大，并对其 runtime 具有权威性。它使用 schema、原子写、lock、task version、claim token、event 和明确字段所有权。参见上游
[`STATE_MODEL.md`](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/docs/STATE_MODEL.md)、
[`state operations`](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/src/state/operations.ts)
和
[`state locks`](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/src/team/state/locks.ts)。

本项目只采用更窄的部分：

1. 每次 helper 调用的 `run_id` 用于关联该次写入的字段；它不注入 Herdr，也不建立实时身份；
2. `current.json` 具有显式 schema，并通过同目录临时文件 rename 替换；
3. 记录精确有序 root、实时名称、workspace ID 和 pane ID；
4. `doctor.sh --team <prefix>` 可以把这些值作为预期值读取，再向 Herdr 和 Codex process argv 重新核实；
5. malformed、过大或 symlink state 会在 Doctor 联系 Herdr 前 fail closed。

记录位于 `$CODEX_HOME` 下，不写入 `.omx`、`.git`、主项目 root 或任何额外项目 root。它只对本启动器之前写入的内容具有权威性，不能证明 Team 正在运行、消息已经投递、任务已经完成、Reviewer 已通过或某个 Agent 写了文件。详见[启动状态](launch-state.md)。

## Worktree 隔离

OMX 能为每个 worker 创建、验证、复用和回滚 worktree。它的 Git 路径检查和 plan-before-mutation 结构值得参考；参见上游
[`worktree.ts`](https://github.com/Yeachan-Heo/oh-my-codex/blob/3ad79a8a6fe6e95fdbb8c00e40716fffe4011ce2/src/team/worktree.ts)。

Per-worker worktree 不适合当前工作流。Reviewer 必须检查 Coder 当前未提交的变更，Planner 也要最终检查同一状态。把三角色分到不同 worktree 会隐藏变更，或要求新增自动 commit/merge channel，从而改变 authority 和 evidence；它也会破坏当前支持的 dirty、non-Git 和 multi-root 项目。

因此保留 per-Team 隔离规则：

- 一个 Team 的三角色观察同一有序 root set；
- 并发 Team 的 effective root set 必须互不重叠；
- 同一 Git 仓库内的并发任务应由用户预先创建 branch 和 worktree，每个 Team 一个；
- 本项目绝不自动 stash、commit、创建或删除 branch、merge、rebase、cherry-pick 或 force-remove worktree。

## 本次直接实现的优化

- 用户本地、带 schema 版本的启动记录，包含 `starting`、`partial` 和 `ready` observation。
- 原子替换 current record 和私有状态权限。
- 每次 helper 调用的相关 ID，与精确 Team、root、workspace 和 pane observation 一起保存；这些值仍须实时核实。
- 基于状态的 Doctor 核验；workspace 或 pane identity 过期时失败。
- Startup lock，把使用同一 `CODEX_HOME` 的当前 `start.sh` 进程在实时名称/root preflight 到 workspace 创建之间串行化。同主机死亡 owner 可通过 quarantine 安全恢复，无需递归删除目录。

Startup lock 是短期锁，不是持久 root lease、filesystem ACL、writer attribution，也无法约束旧脚本、手工 Herdr 命令、其他工具、远程主机或使用不同 `CODEX_HOME` 的当前 helper。长期 guard 仍是实时 Agent root inspection。

## 明确不采用

- 动态 worker、task DAG、claim、heartbeat、approval 和 rebalancing；
- tmux 或另一套 production runtime Adapter；
- 把 `.omx` task/mailbox/event state 复制进项目 root；
- 第二套 mailbox、dispatch queue 或 Coder-to-Reviewer channel；
- delivery 不确定后的自动重试；
- per-role worktree 或自动 Git lifecycle 管理；
- 声称启动记录可以恢复 Codex 对话。

本次实现没有复制 OMX 源码，而是独立实现设计思想。所固定的上游 tree 不包含 LICENSE/COPYING 文件，这也是只做设计比较、不导入代码的额外原因。

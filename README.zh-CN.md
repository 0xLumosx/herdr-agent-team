# Herdr Codex Team

[English](README.md)

在 [Herdr](https://herdr.dev/) 中运行一个或多个相互隔离的三 Agent Codex Team。

每个 Team 都保留相同的可见工作流——Planner → Coder → Reviewer——但其 Herdr 名称带有 Team 身份：

```text
                                  Herdr

       ┌──────────────────────────────┐  ┌──────────────────────────────┐
       │ Team: auth                   │  │ Team: github                 │
       │                              │  │                              │
用户 ─▶│ auth-planner                 │  │ github-planner               │◀─ 用户
       │   ├────────▶ auth-coder      │  │   ├────────▶ github-coder    │
       │   └────────▶ auth-reviewer   │  │   └────────▶ github-reviewer │
       └──────────────────────────────┘  └──────────────────────────────┘

                         禁止跨 Team 路由
```

Planner 是唯一的编排者。Coder 是唯一预期修改应用源码的角色。Reviewer 独立且只读。Planner 只能访问其所属 Team 的精确 Herdr 实时名称；只要身份或路由有歧义，就必须以失败结束。

Codex profile 可以复用；Herdr 实时名称提供 Team 身份：

```text
Codex profile: planner        Herdr 实时名称: auth-planner
Codex profile: coder          Herdr 实时名称: auth-coder
Codex profile: reviewer       Herdr 实时名称: auth-reviewer
```

`planner` profile 并不要求 Herdr agent 必须直接命名为 `planner`。带前缀的 Team 与 legacy Team 都复用同一组三个 profile。

> **项目范围：**本仓库围绕 Herdr 和 Codex CLI 提供配置、角色策略、安装和验证。它不是新的多 Agent runtime、daemon、scheduler、workflow engine、branch manager 或 state database。

## 为什么需要这个项目

只有当角色边界可观察、失败情况被如实报告时，多 Agent 工作流才真正有用。本项目针对四类常见故障：

- 编排者在 live agent 不可用时，悄悄改用 internal subagent；
- 一个 Team 的 Planner 把任务路由给另一个 Team 的 Coder 或 Reviewer；
- 多个 Agent 修改同一个工作树，导致作者归属或审查证据不可靠；
- Reviewer 没有独立读取真实 diff 和验证证据，却报告成功。

Herdr 提供可见 runtime、唯一实时名称和通信；Codex CLI 提供三个角色专属 session；本仓库提供可复用 profile、自包含 prompt、启动辅助脚本、诊断和路由测试。

## 架构

在每个 Team 内，控制路径被刻意限制为单向：

```text
用户 → Planner → Coder → Planner → Reviewer → Planner
                    ▲                    │
                    └── 已接受的修复 ───┘
```

Coder 与 Reviewer 不直接协作。Planner 在每次交接之间检查真实工作树、分诊审查意见，并在最多四轮实现/审查后停止。

在 Herdr 层面，可同时存在任意数量带前缀的 Team：

```text
Herdr
├── auth-planner / auth-coder / auth-reviewer
├── github-planner / github-coder / github-reviewer
└── docs-planner / docs-coder / docs-reviewer
```

核心不变量是：**Planner 只在自己的 Team 内编排。**它从自己当前的 Herdr 实时身份推导 Coder 和 Reviewer 名称，不根据 pane 位置、tab、workspace、process kind 或固定 pane ID 猜测。

Planner profile 使用 `workspace-write`，因为只读 Planner 可能无法访问 Herdr 通信接口。这项能力并不授权其修改应用源码：Planner prompt 明确禁止这样做。这是策略边界，不是操作系统级保证；详见[安全](docs/zh-CN/security.md)。

完整模型请阅读[架构](docs/zh-CN/architecture.md)和[多 Team 隔离](docs/zh-CN/multi-team.md)。

## 要求

兼容性约定基于命令能力，而不是精确版本锁定。

| 组件 | 所需能力 |
| --- | --- |
| Codex CLI | `$CODEX_HOME/<name>.config.toml` 独立 profile 文件、`--profile`、`workspace-write`、`read-only` 和 `approval_policy = "never"` |
| Herdr | 状态、workspace/pane 检查和创建、具名 agent 的 start/list/get/prompt/wait，以及合法且唯一的实时名称 |
| Shell | macOS 或常见 Linux 发行版上的 Bash |
| Git | diff 检查和完整工作流测试所必需 |

实现于 2026-08-24 在 **Herdr 0.8.2** 和 **Codex CLI 0.147.0** 上完成检查。这只是本地验证基线，不是精确版本锁定。脚本会探测所需能力；若缺失则失败并给出修复提示。

你必须已经能够完成 Codex 身份验证并启动 Herdr。凡是读取 Herdr JSON 的脚本都需要真实解析器：优先使用 `jq`；未安装 `jq` 时，使用 Python 3 标准库作为 fallback。即使已安装 `jq`，隔离式完整循环 demo 仍明确需要 Python 3。

## 快速开始

一次性安装三个可复用 profile：

```bash
cd /path/to/herdr-codex-team
./scripts/install.sh
./scripts/test.sh static
```

从 Herdr 管理的 shell 启动带前缀的 Team：

```bash
/path/to/herdr-codex-team/scripts/start.sh \
  --team github \
  --cwd /absolute/path/to/project
```

这会创建以下 Herdr 实时名称，同时选择通用 profile：

```text
github-planner    → codex --profile planner
github-coder      → codex --profile coder
github-reviewer   → codex --profile reviewer
```

无需停止第一个 Team，即可启动另一个隔离 Team：

```bash
/path/to/herdr-codex-team/scripts/start.sh \
  --team auth \
  --cwd /absolute/path/to/another-project
```

显式检查每个 Team：

```bash
/path/to/herdr-codex-team/scripts/doctor.sh --team github
/path/to/herdr-codex-team/scripts/test.sh --team github ping
/path/to/herdr-codex-team/scripts/test.sh --team github communication

/path/to/herdr-codex-team/scripts/doctor.sh --team auth
```

`TEAM_PREFIX=github` 是 `--team github` 的环境变量替代方式。为兼容 legacy 模式，省略 Team 前缀会创建名称严格为 `planner`、`coder` 和 `reviewer` 的一个 Team：

```bash
/path/to/herdr-codex-team/scripts/start.sh --cwd /absolute/path/to/project
/path/to/herdr-codex-team/scripts/doctor.sh
```

`start.sh` 仍保留 legacy 的位置参数项目目录形式。若启动后不应改变当前聚焦 pane，请使用 `--no-focus`。完整命令约定见[安装](docs/zh-CN/installation.md)。

预期的三 pane 布局只是便利条件，不是身份依据：

```text
┌────────────────────────┬────────────────────────┐
│                        │ <team>-coder           │
│ <team>-planner         ├────────────────────────┤
│                        │ <team>-reviewer        │
└────────────────────────┴────────────────────────┘
```

不要把 profile 安装完成或看见三个 pane 当成路由正确的证据。请运行诊断和 live 测试，并观察精确具名的 pane 是否实际收到工作。

## 并发 Team 的工作树

精确名称路由配合 fail-closed prompt contract，在各 Agent 遵守约定时可降低误发跨 Team 消息的风险。创建 workspace 之前，`start.sh` 会检查另一名可核实 Herdr Codex 角色 Agent 的 `cwd` 与 `foreground_cwd`：若它们解析到同一物理 Git worktree，或路径包含目标 root／位于目标 root 内，则拒绝启动。只有 cwd scope 不发生这种重叠的独立 worktree 才允许并存。这只是启动前 guard，不是原子 reservation 或 ACL；检查后的竞态与 Herdr 外部 writer 仍然可能存在。

- 不同仓库可使用不同 `--cwd` 并发运行。
- 同一仓库中的并发任务应为每个 Team 使用独立 Git worktree 和 branch。

```bash
cd /projects/myapp
git worktree add ../myapp-auth -b task/auth
git worktree add ../myapp-ui -b task/ui

/path/to/herdr-codex-team/scripts/start.sh \
  --team auth --cwd /projects/myapp-auth
/path/to/herdr-codex-team/scripts/start.sh \
  --team ui --cwd /projects/myapp-ui
```

本项目刻意不创建 branch、不 merge 变更、不移除 worktree，也不解决冲突。这些仍是用户拥有的常规 Git 操作。详见[多 Team 隔离](docs/zh-CN/multi-team.md)和[多 Team 示例](examples/multi-team.md)。

## 安装行为

`install.sh` 会：

1. 检查 Codex 和 Herdr 并报告版本；
2. 在需要时创建 `$CODEX_HOME`；
3. 替换前备份每个现有目标 profile；
4. 只安装 `planner.config.toml`、`coder.config.toml` 和 `reviewer.config.toml`；
5. 为实际嵌入的角色 prompt 与受管 profile policy 分别记录 SHA-256，供 `doctor.sh` 与 `start.sh` 拒绝与当前 checkout 发生漂移的已安装指令、reasoning、sandbox、approval 或未来策略字段；可独立配置的 `model = ...` 行不纳入 policy hash；
6. 报告 Herdr Codex integration 状态，但不会静默信任已经变化的 hook。

Team 不会导致按前缀复制 profile。即使有二十个 Team，仍然只使用这三个已安装文件。安装器不会删除或重写基础 `config.toml`、发布任何内容，也不会强制信任 hook。

## Agent 角色

| 角色 | 权限 | 必须做 | 禁止做 |
| --- | --- | --- | --- |
| Planner | 编排自己的 Team 并做最终决策 | 推导实时身份、验证精确的同 Team 目标、定义验收标准、检查真实 diff、分诊审查意见 | 实现源码、访问另一个 Team、猜测目标、用 native/internal subagent 代替 Herdr agent |
| Coder | 所属 Team 唯一的实现工程师 | 做聚焦变更、运行相关验证、报告事实和阻塞 | 审批自己的工作、联系 Reviewer、编排 Agent |
| Reviewer | 独立验证 | 检查需求、diff、相关代码和测试；报告具有明确后果的问题 | 修改文件、实现修复、指挥 Coder、编排 Agent |

Reviewer 只返回 `PASS` 或 `CHANGES_REQUIRED`。阻塞性 finding 必须说明 severity、location、problem、consequence 和 recommended correction。`LOW` 默认不阻塞。

## 测试

```bash
./scripts/test.sh static

/path/to/herdr-codex-team/scripts/test.sh --team github ping
/path/to/herdr-codex-team/scripts/test.sh --team github communication
/path/to/herdr-codex-team/scripts/test.sh --team github full
/path/to/herdr-codex-team/scripts/test.sh --team github policy
/path/to/herdr-codex-team/scripts/test.sh \
  --team github --against-team auth isolation
/path/to/herdr-codex-team/scripts/test.sh \
  --team auth --against-team github isolation
```

| 模式 | 能够证明什么 |
| --- | --- |
| `static` | 在不使用 live agent 的情况下检查 shell 语法、必需文件、profile 安全默认值、身份解析、legacy/前缀命名和 prompt 不变量 |
| `ping` | shell 能够访问精确的同 Team Coder 和 Reviewer，并收到本次运行特定的回复 |
| `communication` | live Planner 将本次运行特定的 challenge 路由到这些真实下游 pane |
| `full` | 一个小型 Git-backed 缺陷经过 live Planner/Coder/Reviewer 循环，并通过有边界的 artifact 检查 |
| `policy` | 使用对抗性提示与带基线校验的嵌套 Git fixture，检查各角色对未授权写入、委派和直接联系请求的特定拒绝边界 |
| `isolation` | 一个有方向的同 Team 路由成功，同时具名 peer Team 保留的 transcript 和 lifecycle sequence 保持不变；交换两个前缀以检查反方向 |

Isolation harness 把 Coder 保留终端中的 challenge-derived standalone token 与 lifecycle sequence 变化作为行为证据。Herdr 的普通 retained terminal 不是带角色标签的审计日志，因此它不能以密码学方式证明 token 的作者；对于有后果的运行，仍应观察具名 pane 并检查任务 artifact。

运行 live 测试时，请观察精确具名的 pane。Planner 仅凭文本宣称目标已处理，并不能证明预期目标实际发生了状态变化。请在传给 `start.sh` 的同一 Git worktree 内使用 `test.sh` 的绝对路径运行，或显式设置 `HERDR_TEST_PROJECT_DIR`。

`full` 与 `policy` 测试要求使用 clean、committed、可丢弃的 host worktree，并在其中创建嵌套 fixture。它们检查路由和生成的 Git artifact，但不提供操作系统级写入者归属证明。由于 Planner 使用 `workspace-write` sandbox，“Coder 是唯一 writer”对 Planner 仍属于 prompt/workflow 策略。Policy 模式还检查 peer transcript、lifecycle sequence 与可见 Herdr agent 名称不变，但无法证明隐藏 native worker 从未存在。

本仓库的静态测试套件不代表 live 多 Team 路由已经通过。如果没有两个合适的 Team，请将 isolation 测试报告为 `NOT RUN`，而不是 `PASS`。单方向结果不是双向隔离结果；必须交换 `--team` 与 `--against-team` 后再次运行。本次更新所在环境没有运行 live isolation。

## 运行第一个任务

打开目标 Planner pane，粘贴一份自包含请求。单 Team 可参考[简单任务](examples/simple-task.md)，实际交接可参考[完整开发任务](examples/full-development-task.md)，并发 Team 可参考[多 Team 示例](examples/multi-team.md)。

请求应包含目标、约束、明确的非目标、验收标准和预期验证。Planner 必须在每次交给 Coder/Reviewer 的消息中包含全部必要上下文；下游 Agent 不应依赖用户之前的聊天记录。每次普通交接及其响应还必须携带稳定的 `TASK_ID`、当前 `ROUND`（1–4）和每次全新的 `HANDOFF_ID`；缺失或回显不匹配时工作流 fail-closed 停止。

## 配置和模型

仓库模板位于 `profiles/`；安装后的文件位于：

```text
$CODEX_HOME/planner.config.toml
$CODEX_HOME/coder.config.toml
$CODEX_HOME/reviewer.config.toml
```

Coder 模板默认配置为：

```toml
model = "gpt-5.6-luna"
model_reasoning_effort = "high"
sandbox_mode = "workspace-write"
approval_policy = "never"
```

这是默认建议，不是路由依赖。工作流与模型无关。你可以通过 `PLANNER_MODEL`、`CODER_MODEL` 和 `REVIEWER_MODEL` 在安装时或每次启动时选择当前 Codex account 与 CLI 可用的模型，也可以只编辑已安装角色文件顶层的 `model = ...` 赋值。修改模型后必须重启对应角色。

Planner 和 Reviewer 默认使用 `xhigh` reasoning；Coder 使用 `high`。Reasoning、sandbox、approval 和角色指令都是受管策略；必须在仓库 `profiles/` 或 `prompts/` 下的对应模板中修改，运行 `install.sh`，然后重启受影响角色。只能使用所选模型支持的值。详见[配置](docs/zh-CN/configuration.md)和[官方 Codex 配置参考](https://developers.openai.com/codex/config-reference/)。

## 审批与 sandbox 设置

三个模板均使用 `approval_policy = "never"`。普通审批点不会暂停等待用户决定，但被 active sandbox 拒绝的操作仍会失败。默认值为：

```text
Planner   workspace-write  （为通信兼容；prompt 禁止源码编辑）
Coder     workspace-write  （唯一预期源码 writer）
Reviewer  read-only        （独立检查）
```

`danger-full-access` 不是默认值，也不是安装问题的变通方案。详见[安全](docs/zh-CN/security.md)和[官方 Codex sandbox 指南](https://developers.openai.com/codex/agent-approvals-security/)。

## 工作流和失败处理

一轮审查是：

```text
Coder 实现或修复 → Reviewer 审查 → Planner 分诊
```

四轮后仍未通过时，Planner 返回 `NOT APPROVED`。Reviewer 返回 `PASS` 后，Planner 仍要检查工作树、验收标准和验证结果，才能返回 `APPROVED`。

路由采取 fail-closed：

- 未知 Planner 身份会产生 `HERDR_COMMUNICATION_FAILED`；
- 预期的同 Team agent 缺失会产生 `HERDR_COMMUNICATION_FAILED`；
- 另一个 Team 可用的 Coder 或 Reviewer 永远不是 fallback；
- native/internal worker、hidden subagent、pane 布局猜测和固定 pane ID 永远不能替代精确 Herdr 实时名称；
- 无法继续实现时，Coder 报告 `BLOCKED`；
- Planner 在中断后保留工作树并重建状态。

交接约定和恢复方式见[工作流](docs/zh-CN/workflow.md)。

## 故障排查

从精确 Team 开始：

```bash
./scripts/doctor.sh --team github
herdr agent list
```

如果 Herdr 报告 `agent_name_taken`，不要覆盖，也不要继续启动一个不完整 Team；请选择唯一 Team 前缀。如果 Planner 访问了错误 Coder，请检查它推导出的 `SELF_AGENT`、`TEAM_PREFIX`、`CODER_AGENT` 和 `REVIEWER_AGENT`。如果两个 Coder 修改同一 checkout，请修正 `--cwd`/Git worktree 冲突；这不是路由问题。

最重要的症状仍是：Planner 声称 Coder 正在工作，但预期同 Team Coder pane 处于 idle。应将其视为通信失败，而不是进展。详见[故障排查](docs/zh-CN/troubleshooting.md)。

## 安全

此工作流为 Planner 和 Coder 提供可写 sandbox，并禁用交互式审批暂停。Prompt 和前缀可减少歧义，但无法形成抵御 compromised model、恶意仓库指令、不安全 hook、共享文件系统或 sandbox 允许的破坏性命令的硬边界。

请使用 clean branch 或 disposable worktree，不要在仓库和 prompt 中放置 secret，审查 hook，并在 merge 前检查每一个 diff。在敏感代码上使用 Team 前，请阅读[安全](docs/zh-CN/security.md)。

## 卸载

```bash
./scripts/uninstall.sh
```

卸载器只将本项目管理的 profile 移到带时间戳的备份中。它不会删除 Codex、Herdr、凭据、live Team、worktree、基础 Codex 配置或无关 hook。

## 许可证

[MIT](LICENSE)

当前尚未发布的更新记录见 [CHANGELOG.md](CHANGELOG.md)。

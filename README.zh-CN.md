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

> **项目范围：**本仓库围绕 Herdr 和 Codex CLI 提供配置、角色策略、安装和验证。它不是新的多 Agent runtime、daemon、scheduler、workflow engine、branch manager 或 task/workflow database。它只为每个 Team 保留一份用户本地启动记录用于诊断；Herdr 始终是实时 runtime 的权威所有者。

## 为什么需要这个项目

只有当角色边界可观察、失败情况被如实报告时，多 Agent 工作流才真正有用。本项目针对四类常见故障：

- 编排者在 live agent 不可用时，悄悄改用 internal subagent；
- 一个 Team 的 Planner 把任务路由给另一个 Team 的 Coder 或 Reviewer；
- 多个 Agent 修改同一个工作树，导致作者归属或审查证据不可靠；
- Reviewer 没有独立读取可用的 Git/non-Git 变更证据和验证证据，却报告成功。

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

完整模型请阅读[架构](docs/zh-CN/architecture.md)、[启动状态](docs/zh-CN/launch-state.md)和[多 Team 隔离](docs/zh-CN/multi-team.md)。审查 oh-my-codex 后采用和拒绝的设计见[与 oh-my-codex 的比较](docs/zh-CN/omx-comparison.md)。

## 要求

兼容性约定基于命令能力，而不是精确版本锁定。

| 组件 | 所需能力 |
| --- | --- |
| Codex CLI | `$CODEX_HOME/<name>.config.toml` 独立 profile 文件、`--profile`、可重复的 `--add-dir`、`workspace-write`、`read-only` 和 `approval_policy = "never"` |
| Herdr | 状态、workspace/pane 检查和创建、具名 agent 的 start/list/get/prompt/wait，以及合法且唯一的实时名称 |
| Shell | macOS 或常见 Linux 发行版上的 Bash |
| Git | CLI 用于保守识别 worktree scope；只有 diff-backed 证据和 `full`/`policy` live test 要求项目本身位于 Git worktree |

实现于 2026-08-25 在 **Herdr 0.8.2** 和 **Codex CLI 0.149.1** 上完成检查。这只是本地验证基线，不是精确版本锁定。脚本会探测所需能力；若缺失则失败并给出修复提示。

你必须已经能够完成 Codex 身份验证并启动 Herdr。凡是读取 Herdr JSON 的脚本都需要真实解析器：优先使用 `jq`；未安装 `jq` 时，使用 Python 3 标准库作为 fallback。即使已安装 `jq`，隔离式完整循环 demo 仍明确需要 Python 3。

## 快速开始

### 远程项目，本地 Herdr 界面

远端先安装并登录 Codex；远端不需要 clone 本仓库。本地进入本仓库后只需记住
一条命令：

```bash
cd /path/to/herdr-codex-team
./scripts/remote.sh \
  --host my-server \
  --team dex \
  --cwd /home/REMOTE_USER/Dex_Teleop
```

这条命令在本地显示 Herdr TUI；三个 Codex Agent、shell 和文件读写都发生在
`my-server`。若远端 Herdr binary 需要首次安装或更新，同一命令会先打开其官方
setup；按
`Ctrl+B`、再按 `Q` detach 一次后，脚本会自动继续并创建 `dex-planner`、
`dex-coder`、`dex-reviewer`，最后重新打开带 Team 的本地界面。以后仍运行完全相同
的命令。若远端 Codex integration 缺失，同一命令会先说明它将修改 hook/config；
你明确输入 `y` 后才安装并自动继续，不会静默跨过这一全局配置边界。

只有远端 named session 和三个 Agent 进程仍存活时，原 pane 和对话才会原样续接；
启动记录只校验 workspace/pane 预期，不记录 PID 或 Codex conversation ID，也不
存储或恢复对话。入口会把本地当前版本的少量启动文件临时
传到远端并自动清理，因此没有两份仓库的同步问题。三个受管 profile 全部不存在时
会自动完成首次安装；若只剩部分 Agent、profile 已部分存在或安全参数不匹配，则
fail closed，不会覆盖旧进程或已有配置。此时打开界面只是供检查，不代表恢复成功。

关闭本地界面时按 `Ctrl+B`，再按 `Q` detach；不要结束三个远端 Agent。下次执行
同一条命令即可继续仍存活的对话。

首次远端准备和冷重启边界见[安装](docs/zh-CN/installation.md#远程模式本地界面远端-agent-和文件)。
同目录和同 Team 名本身不是恢复凭据；稳定入口是同一 SSH host、同一
`--team` 对应的 Herdr named session。存在本项目启动记录时，检查还会绑定保存的
workspace/pane ID；这能排除不同 pane/workspace，却不能证明 pane 内仍是上次的
进程或对话。Herdr 进程真正冷重启后的 Codex 恢复仍是 best-effort；记录本身不能
恢复对话，`open.sh` 也不会把未通过 `doctor.sh` 的裸恢复误报为健康 Team。

### 本机项目

一次性安装三个可复用 profile：

```bash
cd /path/to/herdr-codex-team
./scripts/install.sh
./scripts/test.sh static
```

从 Herdr 管理的 shell 打开带前缀的 Team：

```bash
/path/to/herdr-codex-team/scripts/open.sh \
  --team github \
  --cwd /absolute/path/to/primary-project \
  --add-dir /absolute/path/to/second-project
```

同一条 `open.sh` 命令也是日常恢复入口：完整且健康的三个 live Agent 会原样
复用；三个都不存在时才调用 `start.sh` 创建；1/3、2/3 或验证失败时不做替换。

这会创建以下 Herdr 实时名称，同时选择通用 profile：

```text
github-planner    → codex --profile planner
github-coder      → codex --profile coder
github-reviewer   → codex --profile reviewer
```

无需停止第一个 Team，即可启动另一个隔离 Team：

```bash
/path/to/herdr-codex-team/scripts/open.sh \
  --team auth \
  --cwd /absolute/path/to/another-project
```

`--add-dir` 可重复使用。主 `--cwd` 仍是 Herdr workspace 和 pane 的工作目录。Planner 和 Coder 在 `workspace-write` 下把每个额外目录作为可写 root，但 Planner 的角色策略仍禁止其修改项目文件。Reviewer 保持 `read-only`，启动时有意不传 `--add-dir`；它仍可只读检查请求的 root，但不会获得额外可写 root。

检查每个 Team。经过受管 startup 后，Doctor 可以从该 Team 的用户本地记录读取保存的启动 scope 和 runtime ID：

```bash
/path/to/herdr-codex-team/scripts/doctor.sh \
  --team github
/path/to/herdr-codex-team/scripts/test.sh --team github ping
/path/to/herdr-codex-team/scripts/test.sh --team github communication

/path/to/herdr-codex-team/scripts/doctor.sh \
  --team auth
```

显式 `--cwd` 和有序 `--add-dir` 形式仍然可用；诊断有意替换的 session 时，它会绕过所保存的 workspace/pane binding。记录只是预期值，Doctor 始终重新核实实时 Herdr 和 Codex process evidence。

`TEAM_PREFIX=github` 是 `--team github` 的环境变量替代方式。为兼容 legacy 模式，省略 Team 前缀会创建名称严格为 `planner`、`coder` 和 `reviewer` 的一个 Team：

```bash
/path/to/herdr-codex-team/scripts/open.sh --cwd /absolute/path/to/project
/path/to/herdr-codex-team/scripts/doctor.sh --cwd /absolute/path/to/project
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

精确名称路由配合 fail-closed prompt contract，在各 Agent 遵守约定时可降低误发跨 Team 消息的风险。创建 workspace 之前，`start.sh` 会把请求的完整 root set（主 `--cwd` 加所有 `--add-dir`）与其他可核实 Herdr Codex 角色暴露的受管主 root 和额外 root 比较。Git-backed 路径按物理 worktree root 比较，non-Git 路径按物理目录 root 比较；任何相同、祖先或后代 scope 重叠都会 fail closed。用户本地 startup lock 会把使用同一 `CODEX_HOME` 的当前 `start.sh` 进程在这次 preflight 到 workspace 创建之间串行化。锁在 startup 后释放；它不是持久 root reservation 或 ACL。不同 `CODEX_HOME` namespace、旧 helper、手工 Herdr 操作和 Herdr 外部 writer 不受它约束。

- 不同仓库可使用不同 `--cwd` 并发运行。
- 同一仓库中的并发任务应为每个 Team 使用独立 Git worktree 和 branch。
- 并发 Team 的全部主 root 和额外 root 在物理路径与 Git worktree 解析后都必须互不重叠。

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
| Planner | 编排自己的 Team 并做最终决策 | 推导实时身份、验证精确的同 Team 目标、定义验收标准、检查可用变更证据及其限制、分诊审查意见 | 实现源码、访问另一个 Team、猜测目标、用 native/internal subagent 代替 Herdr agent |
| Coder | 所属 Team 唯一的实现工程师 | 做聚焦变更、运行相关验证、报告事实和阻塞 | 审批自己的工作、联系 Reviewer、编排 Agent |
| Reviewer | 独立验证 | 检查需求、可用的 Git/non-Git 变更证据、相关代码和测试；报告具有明确后果的问题 | 修改文件、实现修复、指挥 Coder、编排 Agent |

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

运行 live 测试时，请观察精确具名的 pane。Planner 仅凭文本宣称目标已处理，并不能证明预期目标实际发生了状态变化。`ping` 和 `communication` 只建立有界的传输行为证据，`isolation` 只建立有界的 transcript 与 lifecycle 非接触证据；它们都不证明文件系统变更或 Git 隔离。

`full` 与 `policy` 测试要求使用 clean、committed、可丢弃的 host worktree，并在其中创建嵌套 fixture。它们检查路由和生成的 Git artifact，但不提供操作系统级写入者归属证明。由于 Planner 使用 `workspace-write` sandbox，“Coder 是唯一 writer”对 Planner 仍属于 prompt/workflow 策略。Policy 模式还检查 peer transcript、lifecycle sequence 与可见 Herdr agent 名称不变，但无法证明隐藏 native worker 从未存在。

Startup 的 single-root 与 multi-root 形式都允许使用现有 non-Git 目录，但这些 root 没有 Git baseline、完整 diff、untracked-file inventory、rollback point，也无法可靠区分预存变更与本次任务变更。应将每个这类 root 的 Git 证据记为 `NOT AVAILABLE`。如果主 `--cwd` 为 non-Git，`full` 和 `policy` 无法把它用作所需 host，必须记为 `NOT RUN`；不得把独立 Git-backed fixture 的结果外推到 non-Git root。`static`、`ping`、`communication` 以及有界的路由 `isolation` 模式在满足各自前置条件时仍可用。

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

这是默认建议，不是路由依赖。工作流与模型无关。你可以通过 `PLANNER_MODEL`、`CODER_MODEL` 和 `REVIEWER_MODEL` 在安装时或每次启动时选择当前 Codex account 与 CLI 可用的模型，也可以只编辑已安装角色文件顶层的 `model = ...` 赋值。修改模型后，必须通过当前 `start.sh` 使用原 root 参数重建受影响 Team。

Planner 和 Reviewer 默认使用 `xhigh` reasoning；Coder 使用 `high`。Reasoning、sandbox、approval 和角色指令都是受管策略；必须在仓库 `profiles/` 或 `prompts/` 下的对应模板中修改，运行 `install.sh`，然后通过当前 `start.sh` 使用原 root 参数重建受影响 Team。只能使用所选模型支持的值。详见[配置](docs/zh-CN/configuration.md)和[官方 Codex 配置参考](https://developers.openai.com/codex/config-reference/)。

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
- Planner 在中断后保留工作树并重建 task state。启动记录可以核实以前的 root/workspace/pane，但不会恢复 task progress 或 Codex 对话。

交接约定和恢复方式见[工作流](docs/zh-CN/workflow.md)。

## 故障排查

从精确 Team 开始。如果它由当前 `start.sh` 创建，请使用保存的启动预期值：

```bash
./scripts/doctor.sh \
  --team github
herdr agent list
```

如果保存的记录不存在或已经 stale，请传入 startup 的精确 `--cwd` 和有序 `--add-dir`。显式 root 会绕过所记录的 workspace/pane binding，但仍会核实实时角色专属 argv。

如果 Herdr 报告 `agent_name_taken`，不要覆盖，也不要继续启动一个不完整 Team；请选择唯一 Team 前缀。如果 Planner 访问了错误 Coder，请检查它推导出的 `SELF_AGENT`、`TEAM_PREFIX`、`CODER_AGENT` 和 `REVIEWER_AGENT`。如果两个 Coder 修改了相互重叠的主 root 或额外 root，请修正完整 root-set collision；不同目录应互不重叠，同一仓库内并发任务应使用独立 Git worktree。这不是路由问题。

最重要的症状仍是：Planner 声称 Coder 正在工作，但预期同 Team Coder pane 处于 idle。应将其视为通信失败，而不是进展。详见[故障排查](docs/zh-CN/troubleshooting.md)。

## 安全

此工作流为 Planner 和 Coder 提供可写 sandbox，并禁用交互式审批暂停。Prompt 和前缀可减少歧义，但无法形成抵御 compromised model、恶意仓库指令、不安全 hook、共享文件系统或 sandbox 允许的破坏性命令的硬边界。

请尽可能使用 clean branch 或 disposable worktree，不要在仓库和 prompt 中放置 secret，审查 hook，并在 merge 前检查全部可用 Git diff；对 non-Git root 则直接检查所报 touched path 并保留证据缺口。在敏感代码上使用 Team 前，请阅读[安全](docs/zh-CN/security.md)。

启动记录包含项目绝对路径，并以私有权限保存在 `$CODEX_HOME` 下。不要在未脱敏时提交或发布它们。

## 卸载

```bash
./scripts/uninstall.sh
```

卸载器只将本项目管理的 profile 移到带时间戳的备份中。它不会删除 Codex、Herdr、凭据、live Team、worktree、基础 Codex 配置或无关 hook。

## 许可证

[MIT](LICENSE)

当前尚未发布的更新记录见 [CHANGELOG.md](CHANGELOG.md)。

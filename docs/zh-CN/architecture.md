# 架构

[English](../architecture.md)

## 范围

Herdr Codex Team 是围绕两个既有系统构建的轻量协调包：

```text
Herdr       可见 terminal runtime、live-agent 身份、通信
Codex CLI   交互式软件工程 Agent 和 sandbox 策略
本仓库      profile、角色 prompt、脚本、测试和文档
            以及每个 Team 一份用户本地启动记录
```

它不会替代 Herdr、实现 agent protocol、维护 daemon 或持久化 task/workflow 状态。它刻意不包含 workflow database、Web UI、queue、autonomous state machine，也不自动管理 Git branch/worktree 生命周期。启动记录只是 observation 和恢复 metadata，不是 runtime truth。

## 系统层级

三角色拓扑仍是单个 Team **内部**的结构。在系统层面，Herdr 实时名称将并发 Team 分隔开：

```text
Herdr
├── Team: auth
│   ├── auth-planner   (Codex profile: planner)
│   ├── auth-coder     (Codex profile: coder)
│   └── auth-reviewer  (Codex profile: reviewer)
├── Team: docs
│   ├── docs-planner   (Codex profile: planner)
│   ├── docs-coder     (Codex profile: coder)
│   └── docs-reviewer  (Codex profile: reviewer)
└── Legacy team
    ├── planner
    ├── coder
    └── reviewer
```

核心不变量是：

```text
Planner 只在自己的 Team 内编排。
```

带前缀的 Planner 从自己当前的实时名称推导两个下游名称。精确的 legacy 自身名称 `planner` 映射到 `coder` 和 `reviewer`。任何其他无法识别的身份、缺失的预期目标或有歧义的推导都会以 `HERDR_COMMUNICATION_FAILED` 失败。另一个 Team 中的 Agent 永远不是 fallback。

## 控制拓扑

```text
                    ┌──────────────┐
                    │     用户     │
                    └──────┬───────┘
                           │ 任务
                           ▼
                    ┌──────────────┐
              ┌────▶│   Planner    │◀──────────────┐
              │     │   编排者     │               │
              │     └──────┬───────┘               │
              │            │ 实现简报              │ 审查结果
              │            ▼                       │
              │     ┌──────────────┐                │
              │     │    Coder     │                │
              │     │ 唯一 writer  │                │
              │     └──────┬───────┘                │
              │            │ 结果 + 变更证据        │
              └────────────┘                       │
                           │ 审查简报                 │
                           ▼                         │
                    ┌──────────────┐                 │
                    │   Reviewer   │─────────────────┘
                    │    只读      │ PASS / CHANGES_REQUIRED
                    └──────────────┘
```

工作流中不存在 Coder-to-Reviewer channel。只有 Planner 可以调度其他角色、转交 Reviewer 的修正指令或宣布最终批准；这些调度权限只适用于从 Planner 自己的 Herdr 实时身份推导出的精确同 Team 名称。

## 组件

### Profile

`profiles/` 下的文件是可分发模板。`scripts/install.sh` 将渲染后的角色 profile 安装到：

```text
$CODEX_HOME/planner.config.toml
$CODEX_HOME/coder.config.toml
$CODEX_HOME/reviewer.config.toml
$CODEX_HOME/herdr-codex-team/herdr_mcp.py
```

`CODEX_HOME` 默认为 `~/.codex`。Codex CLI 通过 `--profile planner`、`--profile coder` 或 `--profile reviewer` 选择文件，并将其叠加到基础用户配置之上。这些 profile 是可复用的角色策略，不是 Team 身份。所有 Team 使用相同的三个 profile 和同一个 Planner bridge；不需要、也不会安装带前缀的副本。

### Prompt

`prompts/` 下的 Markdown 文件是各角色契约的可读源文件。它们是自包含的：角色权限、禁止行为、交接格式、失败行为和审查轮次上限都不依赖之前的聊天记录。

### 设置脚本

- `install.sh` 验证前置条件、备份冲突文件，并安装 profile 与精确的受管 Planner bridge。
- `doctor.sh` 检查 binary、已安装 profile、Herdr runtime、精确 legacy 或带前缀的实时名称、状态、workspace/pane/cwd 关联，以及前台 profile、具名 permission profile、实际 filesystem sandbox 与 network 和角色专属额外 root argv 绑定。未显式提供 root 时，它可以读取最近 Team 启动记录，再向 Herdr 核实精确 runtime binding。
- `start.sh` 仅使用已安装 Herdr 公开的 CLI 能力，准备一个 legacy 或带前缀的三 pane Team。它拒绝名称冲突和完整 root-set 重叠，不会重命名或删除现有 Agent。可重复 Codex `--add-dir` 为 Planner 提供只读 workspace context、为 Coder 提供可写 context；Reviewer 仍只使用主 root。短期 startup lock 会把使用同一 `CODEX_HOME` 的当前 helper 在 preflight 到 workspace 创建之间串行化，并以原子方式记录该次 helper 调用的启动 observation。
- `lib/run-state.sh` 只拥有 schema validation、原子启动记录写入、state-backed scope loading 和 startup lock。它绝不 prompt、启动、停止或调度 Agent。
- `test.sh` 检查 Team-aware direct ping、经 Planner 的通信、完整循环，并在两个真实 Team 可用时检查路由隔离。
- `uninstall.sh` 只把本项目管理的 profile 与 bridge 移到可恢复的日期备份中。

### 测试 Prompt

Direct-ping fixture 定义精确 sentinel 回复；mediated 和 full-loop 测试则使用本次运行特定的 challenge，成功回复只能由下游 live agent 推导。完整的派生回复不出现在外层 Planner 输入中，因此仅转发或 echo 该输入无法通过检查。本次运行特定的字符串也让旧 scrollback 或通用模型回复更难被误判为预期 live agent 已处理消息的证据。可见 pane 状态变化仍是证据的一部分。

Isolation 模式指定一个 primary Team 和一个 adversarial peer Team。它检查 live 同 Team 路由，并在 peer Team 的下游证据中查找本次运行特定的 challenge。两个 Team 必须都是真实且 settled；仅靠静态名称构造无法证明跨 Team 隔离。如果无法执行 live 检查，必须报告 `NOT RUN`。它是路由证据，不证明 root set 之间的文件系统隔离。

Full-loop harness 要求 host worktree Git-clean 且有已提交的 `HEAD`，并在 live Team 所使用的项目下创建 disposable nested Git repository。它使用 challenge-derived Coder/Reviewer response token，避免把输入文字误判为成功回复；还要求 fixture `HEAD` 保持在 harness baseline、只有预期 fixture 文件发生差异、周边 host 的 Git-visible status/branch/`HEAD` 保持不变、脚本自身 Python assertion 和 fixture test 通过，并且 Planner 发出本次运行特定的 approval token。Harness commit 会禁用用户级签名和 hook。它不是 filesystem audit，无法发现对 ignored host file 的修改，也不能提供 writer attribution：受管 Planner 与 Reviewer 均为只读，但项目没有为未受管进程安装操作系统级 audit 机制。

Harness 要求 Git-backed 主 host。如果 Team 的主 cwd 为 non-Git，`full` 和 `policy` 均为 `NOT RUN`。Git-backed 主 root 下获得的结果不能建立 non-Git 额外 root 的 baseline、完整 diff、rollback 或 writer attribution。

## 身份：profile、kind 与实时名称各不相同

Herdr 可以把所有进程的 kind 都标记为 `codex`，同时由唯一实时名称编码角色和可选 Team：

```text
kind: codex, name: planner
kind: codex, name: coder
kind: codex, name: reviewer

kind: codex, name: auth-planner
kind: codex, name: auth-coder
kind: codex, name: auth-reviewer
```

`codex --profile coder` 选择的 profile 描述 Agent 可以做什么；Herdr 实时名称 `auth-coder` 描述所属 Team 的 Planner 应向哪里路由。Prompt 使用精确实时名称。名为“coder”的 process、pane、Codex internal worker 或 session-local path 都不是替代品。如果 Herdr 无法识别预期的同 Team 目标，工作流必须停止。

在 Herdr 0.8.2 中，名称跟随当前 pane occupant，并会在 Agent 退出、被 release 或被替换时清除。名称是 runtime state，而不是永久 profile metadata；因此 startup、Planner handoff 和 diagnostics 每次都必须重新检查。Pane ID 和布局同样是 runtime data。启动记录只能把 pane ID 作为某个 `run_id` 的 freshness expectation 保存；它绝不是永久 Team 身份，必须实时复核。

当 Coder 或 Reviewer 使用 Codex 0.171 及以上版本且本地有会话记录时，通信桥按派单原文和轮次 ID 读取已完成的回复，来源标记为 `codex-turn`。交接完成后，通信桥再次核对 Herdr 窗格、会话 ID 和状态序号。其他 CLI 以及旧版 Codex 通过终端记录返回回复。

## 角色与权限矩阵

| 能力 | Planner | Coder | Reviewer |
| --- | ---: | ---: | ---: |
| 与用户沟通 | 讨论方案并确认关键决策 | 遇阻找 Planner | 通过 Planner 向用户提问，在自己的窗格展示最终审查报告 |
| 调度同 Team Coder | 是 | 否 | 否 |
| 调度同 Team Reviewer | 是 | 否 | 否 |
| 访问另一个 Team | 否 | 否 | 否 |
| 按策略修改应用源码 | 否 | 是 | 否 |
| Filesystem sandbox | `read-only` | `workspace-write` | `read-only` |
| Command network | 启用 | 启用 | 启用 |
| 检查可用变更证据 | 每个 Git root 的 diff；每个 non-Git root 的 touched-path 限制 | 对自身 report 执行相同检查 | 独立检查两者并保留缺口 |
| 宣布最终批准 | 是 | 否 | 否 |

Planner 与 Reviewer 都有直接 `read-only` 文件系统边界。Planner 接收
`--add-dir` 作为 workspace context，Reviewer 不接收；Coder 是唯一受管实现
writer。受管 startup 为 Planner 与 Reviewer
选择继承 `:read-only` 的 beta permission profile，为 Coder 选择继承
`:workspace` 的另一个 profile；三个 profile 都启用 command network。Startup
在 argv 中重复精确 permission 设置，向 Planner 与 Coder 传入同一额外 root
context，但只有 Coder 可写，并拒绝
旧 `--sandbox` 或 `sandbox_workspace_write.writable_roots` 冲突。Startup 与 Doctor
还会验证模型实际可见的 filesystem sandbox 和 network 状态。Linux shell sandbox
可能拒绝 AF_UNIX socket 创建，因此 Planner 通过必需的本地 stdio MCP bridge
访问 Herdr。Bridge 会验证当前 pane、socket ownership、精确同 workspace Team
身份、readiness 与 lifecycle correlation；工具面只接受 `inspect_team` 和按角色的
`prompt_agent`，从不接受任意 Agent 名称或任意 Herdr 命令。每个角色 profile
都通过 `agents.enabled = false` 禁用 Codex 原生多代理工具；受管 launch 会在 argv
中重复该设置，live validation 会拒绝缺少它的旧进程。因此 Herdr 是唯一受管
Agent 拓扑。

Command network 是广泛出站能力，不是 SSH host allowlist。本地 filesystem
sandbox 不会约束通过 SSH 执行的远端操作，`approval_policy = "never"` 也不会在
允许的远端命令前增加交互检查点。远端账号与 server-side 限制属于独立 trust
boundary。

## 交接契约

每条 Planner-to-Coder 消息都包含 goal、相关 context、constraints、acceptance criteria、expected validation，以及不得修改无关代码的明确禁令。每条 Planner-to-Reviewer 消息都包含原始 requirement、acceptance criteria、当前 round、Coder report、validation evidence 和要检查的精确变更证据 scope：Git-backed root 使用 diff/revision 证据，non-Git root 使用所报告的 touched path 和明确证据缺口。

Coder 返回包含事实细节的 `IMPLEMENTATION_DONE` 或 `BLOCKED`。Reviewer 用 `ASK_PLANNER` 或 `ASK_USER` 澄清疑问，用 `PASS` 或 `CHANGES_REQUIRED` 向 Planner 返回结论和技术依据。给用户的最终审查报告只在 Reviewer 窗格展示。Planner 不会照单全收任何 report：它会在做出下一步决策前读取工作树。

## 审查轮次与终止

一轮是：

```text
Coder 实现或修复 → Reviewer 审查 → Planner 分诊
```

初次实现计为第 1 轮，最多四轮。通过后，Planner 执行一次最终 sanity check。到第 4 轮仍无可接受结果时，Planner 以 `NOT APPROVED` 停止，并为用户保留尚存问题以及两个下游角色的立场。

轮次上限可防止 Coder/Reviewer 无限对话，并让最终责任始终归于 Planner。

## 信任边界

系统有六个不同边界：

1. **Herdr runtime：**提供实时身份和可观察路由。可见 pane 是 process identity 的证据，不证明其输出正确。
2. **Team-name boundary：**当 Planner 遵守 fail-closed 契约时，精确 `<prefix>-<role>` 名称可防止跨 Team 访问；它们不隔离文件或操作系统进程。
3. **Codex sandbox 与 command network：**角色 permission profile 限制本地
   filesystem access，并启用出站 command network。`approval_policy = "never"`
   会改变提示行为，但不会禁用 sandbox，也不会限制远端 SSH 账号能做什么。
4. **Role prompt：**在语义上约束行为。它是有用策略，不是安全原语。
5. **Git 和验证：**在 Git 历史存在时提供最终决策所依据的客观记录。Non-Git touched-path inventory 只是最大努力证据，不能证明完整变更集或 baseline。
6. **启动记录：**保留 startup helper 观察和预期的内容。它不是当前 liveness、delivery、task completion、approval 或 writer identity 的证据。

即使两个 Team 在 Herdr 名称上完全隔离，只要任一主 scope 或额外 scope 重叠，仍可能破坏彼此的工作。Startup 会比较完整受管 root set：Git-backed 路径按物理 worktree root，non-Git 路径按物理目录 root。同一仓库内的并发任务要使用不同 Git worktree 和 branch，每个额外 root 也必须互不重叠。Preflight 不是操作系统锁。Startup lock 只关闭使用同一 `CODEX_HOME` 的当前受管 `start.sh` 进程之间的竞态，并在 startup 后释放；不同 `CODEX_HOME` namespace、外部 writer 和旧/手工启动路径不受其约束。

## 重启与持久化边界

项目在 `$CODEX_HOME` 下保存每个团队最近一次启动的记录和历次关联的对话 ID。在受管 Planner 窗格选中已登记的对话，Coder 和 Reviewer 会恢复各自的对话。详见[恢复对话](launch-state.md#恢复对话)。如果历史对话已经无法打开，应保留项目文件。对于每个 Git 工作树，可先运行以下命令。

```bash
git status --short
git diff
git diff --staged
```

对每个 non-Git root，记录 `Git evidence: NOT AVAILABLE` 并直接检查上次所报 touched path；这无法重建完整 baseline。

新的 Planner 从可用 diff 和所报 touched path 重建目标与当前状态，保留 non-Git 证据缺口，重新推导当前 Team 身份、验证精确的同 Team live Herdr agent，并从合适的 handoff 继续。它不能假定 Coder report 或 Reviewer result 被保留下来。启动记录可以核实预期 root、workspace 和 pane ID，但不能恢复 Codex 对话。

持久 handoff packet、response、delivery receipt、task transition 和 review decision 仍不在当前范围内。要增加这些能力，必须在 Planner 的 Herdr delivery 外围建立单一 interception Interface；terminal scraping 或第二套 mailbox 会制造冲突的状态所有者。

运行示例和文件系统边界见[多 Team 隔离与动态路由](multi-team.md)。形成此边界的上游设计比较见[与 oh-my-codex 的比较](omx-comparison.md)。

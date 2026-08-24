# 架构

[English](../architecture.md)

## 范围

Herdr Codex Team 是围绕两个既有系统构建的轻量协调包：

```text
Herdr       可见 terminal runtime、live-agent 身份、通信
Codex CLI   交互式软件工程 Agent 和 sandbox 策略
本仓库      profile、角色 prompt、脚本、测试和文档
```

它不会替代 Herdr、实现 agent protocol、维护 daemon 或持久化工作流状态。它刻意不包含 database、Web UI、queue、autonomous state machine，也不自动管理 Git branch/worktree 生命周期。

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
              │            │ 结果 + 真实 diff       │
              └────────────┘                       │
                           │ 审查简报                 │
                           ▼                         │
                    ┌──────────────┐                 │
                    │   Reviewer   │─────────────────┘
                    │    只读      │ PASS / CHANGES_REQUIRED
                    └──────────────┘
```

工作流中不存在 Coder-to-Reviewer channel。只有 Planner 可以调度其他角色、判断 finding 是否成立或宣布最终批准；这些调度权限只适用于从 Planner 自己的 Herdr 实时身份推导出的精确同 Team 名称。

## 组件

### Profile

`profiles/` 下的文件是可分发模板。`scripts/install.sh` 将渲染后的角色 profile 安装到：

```text
$CODEX_HOME/planner.config.toml
$CODEX_HOME/coder.config.toml
$CODEX_HOME/reviewer.config.toml
```

`CODEX_HOME` 默认为 `~/.codex`。Codex CLI 通过 `--profile planner`、`--profile coder` 或 `--profile reviewer` 选择文件，并将其叠加到基础用户配置之上。这些 profile 是可复用的角色策略，不是 Team 身份。所有 Team 使用相同的三个文件；不需要、也不会安装带前缀的 profile 副本。

### Prompt

`prompts/` 下的 Markdown 文件是各角色契约的可读源文件。它们是自包含的：角色权限、禁止行为、交接格式、失败行为和审查轮次上限都不依赖之前的聊天记录。

### 设置脚本

- `install.sh` 验证前置条件、备份冲突文件并安装 profile。
- `doctor.sh` 检查 binary、已安装 profile、Herdr runtime、精确 legacy 或带前缀的实时名称、状态、workspace/pane/cwd 关联，以及前台 `--profile <role>` 绑定。
- `start.sh` 仅使用已安装 Herdr 公开的 CLI 能力，准备一个 legacy 或带前缀的三 pane Team。它拒绝名称冲突，不会重命名或删除现有 Agent。
- `test.sh` 检查 Team-aware direct ping、经 Planner 的通信、完整循环，并在两个真实 Team 可用时检查路由隔离。
- `uninstall.sh` 只把本项目管理的 profile 文件移到可恢复的日期备份中。

### 测试 Prompt

Direct-ping fixture 定义精确 sentinel 回复；mediated 和 full-loop 测试则使用本次运行特定的 challenge，成功回复只能由下游 live agent 推导。完整的派生回复不出现在外层 Planner 输入中，因此仅转发或 echo 该输入无法通过检查。本次运行特定的字符串也让旧 scrollback 或通用模型回复更难被误判为预期 live agent 已处理消息的证据。可见 pane 状态变化仍是证据的一部分。

Isolation 模式指定一个 primary Team 和一个 adversarial peer Team。它检查 live 同 Team 路由，并在 peer Team 的下游证据中查找本次运行特定的 challenge。两个 Team 必须都是真实且 settled；仅靠静态名称构造无法证明跨 Team 隔离。如果无法执行 live 检查，必须报告 `NOT RUN`。

Full-loop harness 要求 host worktree Git-clean 且有已提交的 `HEAD`，并在 live Team 所使用的项目下创建 disposable nested Git repository。它使用 challenge-derived Coder/Reviewer response token，避免把输入文字误判为成功回复；还要求 fixture `HEAD` 保持在 harness baseline、只有预期 fixture 文件发生差异、周边 host 的 Git-visible status/branch/`HEAD` 保持不变、脚本自身 Python assertion 和 fixture test 通过，并且 Planner 发出本次运行特定的 approval token。Harness commit 会禁用用户级签名和 hook。它不是 filesystem audit，无法发现对 ignored host file 的修改，也不能提供 writer attribution：Planner 拥有 `workspace-write`，而项目没有安装操作系统级 audit 机制。“Only Coder writes” 对 Reviewer 有硬约束，但对 Planner 仍是 prompt/workflow 策略。

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

在 Herdr 0.8.2 中，名称跟随当前 pane occupant，并会在 Agent 退出、被 release 或被替换时清除。名称是 runtime state，而不是永久 profile metadata；因此 startup、Planner handoff 和 diagnostics 每次都必须重新检查。Pane ID 和布局同样是 runtime data，绝不能嵌入为永久 Team 身份。

## 角色与权限矩阵

| 能力 | Planner | Coder | Reviewer |
| --- | ---: | ---: | ---: |
| 与用户沟通 | 是 | 通过 Planner report | 通过 Planner report |
| 调度同 Team Coder | 是 | 否 | 否 |
| 调度同 Team Reviewer | 是 | 否 | 否 |
| 访问另一个 Team | 否 | 否 | 否 |
| 按策略修改应用源码 | 否 | 是 | 否 |
| Filesystem sandbox | `workspace-write` | `workspace-write` | `read-only` |
| 检查 Git diff | 必需 | 对自身 report 必需 | 必需 |
| 宣布最终批准 | 是 | 否 | 否 |

Planner 的 no-write 边界是 prompt 和工作流规则，而不是硬文件系统限制。保留 `workspace-write` 是因为只读 Planner 在尝试 Herdr 通信时曾产生 `Operation not permitted`。必须理解这一取舍，不能把它描述为完美隔离。

## 交接契约

每条 Planner-to-Coder 消息都包含 goal、相关 context、constraints、acceptance criteria、expected validation，以及不得修改无关代码的明确禁令。每条 Planner-to-Reviewer 消息都包含原始 requirement、acceptance criteria、当前 round、Coder report、validation evidence 和要检查的精确 diff/revision scope。

Coder 返回包含事实细节的 `IMPLEMENTATION_DONE` 或 `BLOCKED`。Reviewer 只返回 `PASS` 或 `CHANGES_REQUIRED`。Planner 不会照单全收任何 report：它会在做出下一步决策前读取工作树。

## 审查轮次与终止

一轮是：

```text
Coder 实现或修复 → Reviewer 审查 → Planner 分诊
```

初次实现计为第 1 轮，最多四轮。通过后，Planner 执行一次最终 sanity check。到第 4 轮仍无可接受结果时，Planner 以 `NOT APPROVED` 停止，并为用户保留尚存问题以及两个下游角色的立场。

轮次上限可防止 Coder/Reviewer 无限对话，并让最终责任始终归于 Planner。

## 信任边界

系统有五个不同边界：

1. **Herdr runtime：**提供实时身份和可观察路由。可见 pane 是 process identity 的证据，不证明其输出正确。
2. **Team-name boundary：**当 Planner 遵守 fail-closed 契约时，精确 `<prefix>-<role>` 名称可防止跨 Team 访问；它们不隔离文件或操作系统进程。
3. **Codex sandbox：**限制 tool access。`approval_policy = "never"` 会改变提示行为，但不会禁用 sandbox。
4. **Role prompt：**在语义上约束行为。它是有用策略，不是安全原语。
5. **Git 和验证：**提供最终决策所依据的客观记录。没有匹配 diff/test 证据的 report 只是未验证声明。

即使两个 Team 在 Herdr 名称上完全隔离，只要两个 Coder 共享同一 checkout，仍可能破坏彼此的工作。不同仓库要使用不同 `--cwd`；同一仓库内的并发任务要使用不同 Git worktree 和 branch。本项目记录该边界，但不自动管理其生命周期。

## 重启与未来持久化

项目不维护工作流 database。Planner 重启时，应保留所有文件并从以下命令开始恢复：

```bash
git status --short
git diff
git diff --staged
```

新的 Planner 从真实 diff 重建目标和当前状态，重新推导当前 Team 身份、验证精确的同 Team live Herdr agent，并从合适的 handoff 继续。它不能假定 Coder report 或 Reviewer result 被保留下来。

未来版本可能在 `.herdr-codex/` 下增加基于文件的 handoff：

```text
task.md
plan.md
coder-result.md
review.md
state.json
```

这仍被刻意排除在当前范围之外；添加它会引入 state ownership、recovery 和 stale-data 问题，应当明确设计。

运行示例和文件系统边界见[多 Team 隔离与动态路由](multi-team.md)。

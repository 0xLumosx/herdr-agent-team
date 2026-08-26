# 多 Team 隔离与动态路由

[English](../multi-team.md)

Herdr Codex Team 可以同时运行一个 legacy Team 或多个带前缀的 Team。隔离单元是 Herdr agent 的实时名称：

```text
<team-prefix>-planner
<team-prefix>-coder
<team-prefix>-reviewer
```

例如，`auth` Team 只包含 `auth-planner`、`auth-coder` 和 `auth-reviewer`。它的 Planner 永远不能路由到 `docs-coder`、legacy `coder` 或任何 hidden/native Codex worker。

## 为什么必须使用前缀

Herdr 实时 agent name 是唯一的。第二个不带前缀的 Team 会试图复用 `planner`、`coder` 和 `reviewer`，因此 startup 必须在冲突时停止。Team 前缀可以创建三个不同实时名称，同时继续复用同一组三个 Codex profile。

使用简短、有意义且符合 Herdr 规则的前缀，例如 `auth`、`github` 或 `docs-v2`。启动辅助脚本会在创建 workspace 前验证生成的名称；它不会为了释放名称而重命名、替换或删除现有 Team。

在已检查的 Herdr 0.8.2 command surface 中，实时名称必须匹配 `[a-z][a-z0-9_-]{0,31}`。由于 `-reviewer` 是最长角色后缀，为让所有生成名称保持在 32 字符限制内，Team 前缀最多可以包含 23 个字符。脚本验证三个完整名称；不要假定任意 project label 都自动是合法前缀。

## Codex profile 与 Herdr 实时名称

这两种身份承担不同用途：

| 身份 | 示例 | 用途 |
| --- | --- | --- |
| Codex profile | `coder` | 可复用的 model、sandbox、approval 和角色指令 |
| Herdr 实时名称 | `auth-coder` | runtime Team membership 和路由目标 |

`auth-coder` 的命令仍选择通用 profile：

```text
codex --profile coder
```

因此安装器始终只管理三个文件：

```text
planner.config.toml
coder.config.toml
reviewer.config.toml
```

创建二十个 Team 不会产生二十份 profile 副本。Profile 名称不是 Team identifier；使用 `planner` profile 的 live agent 不必直接命名为 `planner`。

## 启动两个 Team

在不同仓库中工作的 Team 可以独立启动：

```bash
/path/to/herdr-codex-team/scripts/start.sh \
  --team auth \
  --cwd /path/to/backend

/path/to/herdr-codex-team/scripts/start.sh \
  --team docs \
  --cwd /path/to/documentation
```

生成的 live agent 是：

```text
auth-planner   auth-coder   auth-reviewer
docs-planner   docs-coder   docs-reviewer
```

在自动化场景中，`TEAM_PREFIX` 是环境变量替代方式：

```bash
TEAM_PREFIX=auth \
  /path/to/herdr-codex-team/scripts/start.sh --cwd /path/to/backend
```

在 runbook 中优先使用显式 `--team`，因为它让目标身份直接显示在命令位置。如果两种形式同时提供，二者不能冲突。

仍然支持 legacy 单 Team startup：

```bash
/path/to/herdr-codex-team/scripts/start.sh --cwd /path/to/project
```

它会生成精确名称 `planner`、`coder` 和 `reviewer`。Legacy 模式只能有一个这样的 Team；启动其他 Team 前要先使用前缀。

一个 Team 可以有意覆盖多个互不重叠的项目 root：

```bash
/path/to/herdr-codex-team/scripts/start.sh \
  --team integration \
  --cwd /path/to/primary-project \
  --add-dir /path/to/second-project \
  --add-dir /path/to/third-project
```

`--add-dir` 可重复。主 cwd 仍是 Herdr workspace/pane 目录。Planner 和 Coder 会获得有序的额外可写 root 列表；Reviewer 保持 `read-only`，不接收 `--add-dir`。

## Planner 如何推导路由

Planner 不会从 Codex profile 获得固定的下游名称。Runtime 中，它获取当前 Herdr 实时身份，并只应用以下两条闭合规则之一：

```text
SELF_AGENT = planner
  → CODER_AGENT = coder
  → REVIEWER_AGENT = reviewer

SELF_AGENT = <prefix>-planner
  → TEAM_PREFIX = <prefix>
  → CODER_AGENT = <prefix>-coder
  → REVIEWER_AGENT = <prefix>-reviewer
```

它在每次 handoff 前验证这些精确实时名称。身份来自 Herdr 名称，不来自 pane position、tab、workspace layout、process kind 或 hard-coded pane ID。这些其他属性可能变化，也可能被无关 Agent 共享。

任何无法识别的自身名称、有歧义的推导、缺失的同 Team 目标或 Herdr communication failure 都会产生：

```text
HERDR_COMMUNICATION_FAILED
```

Planner 不得寻找模糊匹配的 Coder、使用另一个 Team 的 Agent，或 fallback 到 native/internal subagent。

## 检查和诊断一个 Team

诊断和测试应使用同一个前缀：

```bash
/path/to/herdr-codex-team/scripts/doctor.sh --team auth

# 不依赖保存的 workspace/pane ID，显式检查 scope：
/path/to/herdr-codex-team/scripts/doctor.sh \
  --team auth --cwd /path/to/backend
/path/to/herdr-codex-team/scripts/test.sh --team auth ping
/path/to/herdr-codex-team/scripts/test.sh --team auth communication
```

未提供 root option 时，Doctor 使用该 Team 最近的安全启动记录，并向 Herdr 重新核实其 root、workspace 和 pane ID。显式形式必须按相同顺序重复 startup 的每个 `--add-dir`，并绕过保存的 ID binding。两种形式都会验证受管的空继承-writable-roots 覆盖、角色 sandbox 和角色专属 process argv：Planner/Coder 必须携带精确列表，Reviewer 必须不携带 `--add-dir`。这是 launch 证据，不是文件访问或变更归属证明。

还要使用已安装 Herdr 版本提供的命令直接检查 runtime：

```bash
herdr agent list
herdr agent get auth-planner
herdr agent get auth-coder
herdr agent get auth-reviewer
```

诊断应将每个带前缀的实时名称与其 generic profile、workspace、pane、lifecycle state 和预期工作目录匹配。`codex` 等 generic kind 不能证明 Team membership。

要实际检查两个 Team 的隔离，请同时指定两个 Team：

```bash
/path/to/herdr-codex-team/scripts/test.sh \
  --team auth --against-team docs isolation
```

`--against-team` 只在 `isolation` 中必需。该测试要求两个 Team 都处于 live 且 settled 状态；它验证一个有方向的同 Team 路由成功，同时指定 peer Team 保留的 transcript 和 lifecycle sequence 不变。要验证反方向，必须交换 `--team` 和 `--against-team` 后再次运行：

```bash
/path/to/herdr-codex-team/scripts/test.sh \
  --team docs --against-team auth isolation
```

如果没有对真实 Agent 运行，应报告 `NOT RUN`；字符串构造或三个可见 pane 不是 live-routing evidence。本次更新所在环境没有运行 live isolation，不能声称它已通过。

Harness 将 Coder 保留终端中的 challenge-derived standalone token、lifecycle sequence 变化和 peer transcript 不变组合为行为证据。这不是带角色标签或密码学意义上的审计记录；仅靠 retained terminal 不能证明屏幕中 token 的作者。
它也不证明任一 Team 各 root 之间的文件系统隔离。

## 工作目录隔离

精确名称路由配合 fail-closed prompt contract，在各 Agent 遵守约定时可降低误发跨 Team 消息的风险；它不是 ACL 或安全边界。`start.sh` 会为请求 Team 和其他可核实 Herdr Codex 角色构建完整 effective scope：主/foreground cwd 加受管 process argv 中所有结构化 `--add-dir` 值。Git-backed 目录映射到物理 worktree root，non-Git 目录映射到物理目录。两个完整 root set 间任何相等、祖先或后代重叠都会被拒绝。无法检查的角色、malformed add-dir argv 或缺少受管空 writable-roots 覆盖的旧 process 都会 fail closed。带 owner 校验的用户本地 startup lock 会把使用同一 `CODEX_HOME` 的当前受管 `start.sh` 进程在 preflight 到 workspace 创建之间串行化。它在启动后释放，不占用项目 root、不介入文件访问，也不是 ACL 或操作系统隔离边界。不同 `CODEX_HOME` namespace、直接 Herdr/Codex 命令、旧脚本、人工操作和外部 writer 不受其约束。

不同仓库可以用独立 `--cwd` 并发运行：

```text
auth team  → /projects/backend
docs team  → /projects/documentation
```

如果在同一仓库中并发工作，请在 startup 前为每个 Team 创建独立 branch 和 Git worktree：

```bash
cd /projects/myapp
git worktree add ../myapp-auth -b task/auth
git worktree add ../myapp-ui -b task/ui

/path/to/herdr-codex-team/scripts/start.sh \
  --team auth --cwd /projects/myapp-auth
/path/to/herdr-codex-team/scripts/start.sh \
  --team ui --cwd /projects/myapp-ui
```

概念结构如下：

```text
myapp
├── worktree: myapp-auth
│   └── auth-planner / auth-coder / auth-reviewer
└── worktree: myapp-ui
    └── ui-planner / ui-coder / ui-reviewer
```

这样每个 Coder 都有独立 working tree、branch 和 diff。本项目记录这一边界，但刻意不自动创建 branch、merge 工作、移除 worktree 或解决 conflict。

Non-Git root 在 single-root 与显式 multi-root 模式中都允许。它们没有 Git baseline、完整 diff、rollback point 或完整的预存变更归属。必须在 Team 之间保持这些 root 互不重叠，并将其 Git 证据记为 `NOT AVAILABLE`；名称隔离无法弥补该证据损失。

## 常见故障

- **`agent_name_taken`：**另一个 live agent 已占用某个精确名称。请选择唯一前缀；不要覆盖或重命名现有 Team。
- **Planner 路由到错误 Coder：**检查 `SELF_AGENT`、`TEAM_PREFIX`、`CODER_AGENT` 和 `REVIEWER_AGENT`。仍 hard-code `coder` 的 stale prompt 会破坏前缀路由。
- **`shared_git_worktree`：**另一个可核实的 Herdr Codex 角色已经使用请求的物理 worktree。复用或关闭该 Team，或改用独立 Git worktree；不要绕过 guard。
- **`shared_workspace_scope`：**包含 non-Git scope 的请求 root set 与另一受管 Team 的主 root 或额外 root 重叠。复用或关闭该 Team，或选择互不重叠的目录；不要绕过 guard。
- **`*_unverified`：**startup 无法证明另一角色的受管 sandbox 或完整 root set。尝试并发前，先用当前 `start.sh` 重启该旧 Team。
- **Active 或无法核实的 startup lock：**等待所报同主机 PID 结束。同主机死亡 owner 由 helper 恢复；malformed 或 foreign-host ownership 会 fail closed。不要递归删除 state root。
- **Stale 启动记录：**用显式 `--cwd` 和有序 `--add-dir` 运行 Doctor，检查目标 live scope。记录绝不授权停止或替换其中命名的 workspace。
- **启动前检查后仍有两个 writer：**这是 filesystem/Git 竞态或外部 writer，不是路由隔离证明。停止两条工作流，并人工恢复全部可用 Git diff 与所报 non-Git touched-path inventory。
- **只有另一个 Team 的 Coder 存在：**以 `HERDR_COMMUNICATION_FAILED` 停止。另一个 Team 的可用性永远不能修复同 Team Agent 缺失。

证据收集命令和恢复边界见[启动状态](launch-state.md)和[故障排查](troubleshooting.md)。

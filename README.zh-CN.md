# Herdr Codex Team

[English](README.md)

在 [Herdr](https://herdr.dev/) 中运行相互隔离的三 Agent Codex Team：

```text
用户 -> Planner -> Coder -> Planner -> Reviewer -> Planner
```

Planner 是唯一编排者，Coder 是唯一预期修改源码的角色，Reviewer 独立且只读。
实时名称携带 Team 身份，例如 `dex-planner`、`dex-coder` 和 `dex-reviewer`；跨
Team 路由会 fail closed。

本仓库只提供 profile、角色 prompt、启动辅助脚本、诊断和测试。Herdr 始终是实时
runtime；本项目不是 scheduler、daemon、branch manager 或对话存储。

## 角色

| 角色 | 本地文件系统 | 职责 |
| --- | --- | --- |
| Planner | read-only | 定义任务，只路由给本 Team 的 Coder/Reviewer，并做最终决策 |
| Coder | workspace-write | 实现聚焦变更并运行相关验证 |
| Reviewer | read-only | 独立检查需求、变更和证据 |

三个角色都允许 command network，包括 SSH。请先阅读下方安全提示。

## 要求

- 已登录、支持角色 profile 与 permission profile 的 Codex CLI
- 支持 named session 和 Codex integration 的 Herdr
- Bash、Git、Python 3；优先使用 `jq`，未安装时由 Python 解析 JSON
- 远程模式还需要本地 OpenSSH、`tar`，以及文档列出的远端工具

已检查基线为 Herdr 0.8.2 和 Codex CLI 0.149.1。脚本会探测所需能力，并不锁死
这些版本。完整兼容性和远端要求见[安装](docs/zh-CN/installation.md)。

## 快速开始

建议 Herdr session 和受管 Team 使用同一个短名称。以下统一使用 `dex`。

### 首次安装

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static && ./scripts/install.sh
```

安装或更新 Codex hook 前先检查 `herdr integration status`。若启动报告 integration
缺失，请按提示显式使用 `--install-integration` 修复。

### 本地单项目

先在普通终端打开 named Herdr session：

```bash
herdr --session dex
```

再在该 Herdr 窗口的 shell pane 中运行：

```bash
/path/to/herdr-codex-team/scripts/open.sh --team dex --cwd /path/to/project
```

两个或更多项目 root，为每个额外 root 增加一个 `--add-dir`：

```bash
/path/to/herdr-codex-team/scripts/open.sh --team dex --cwd /path/to/app --add-dir /path/to/lib
```

`open.sh` 只在当前 Herdr session 中创建或复用三个 Agent，不会另外启动 Herdr
窗口。Planner 以只读 workspace context 看到额外 root，Coder 可写，Reviewer
仍只使用主 root。

### 远程服务器项目

在本地仓库运行 `remote.sh`。界面在本地，Herdr、Codex 和项目文件都在 SSH
主机：

```bash
./scripts/remote.sh --host user@server --team dex --cwd /remote/project
```

远端多项目：

```bash
./scripts/remote.sh --host user@server --team dex --cwd /remote/app --add-dir /remote/lib
```

远端需要安装并登录 Codex，但不需要 clone 本仓库。

### 没有自动打开窗口时手动打开

本地 session 仍存活时，在 fresh 普通本地 shell 中运行（禁止嵌套 attach）：

```bash
herdr session attach dex
```

远端 session 仍存活时，也使用同类 fresh 本地 shell：

```bash
herdr --remote user@server --session dex
```

只想关闭窗口并保留任务时，按 `Ctrl+B`，再按小写 `q` detach。

### 检查或完全结束任务

在已选中的本地 Herdr session 内运行 Doctor：

```bash
/path/to/herdr-codex-team/scripts/doctor.sh --team dex
```

要完全停止本地 named session 并删除其保存的 Herdr session 状态，先 detach，
再在普通终端运行：

```bash
herdr session stop dex && herdr session delete dex
```

远端主机使用：

```bash
ssh -T user@server 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"; herdr session stop dex && herdr session delete dex'
```

`stop` 会结束该 named session 及其 pane，`delete` 还会删除保存的 Herdr session
状态；项目文件、Codex 历史和本项目 launch record 不会被删除。若多个 Team 共用
一个 session，只关闭目标 workspace：
`herdr --session dex workspace close <workspace-id>`。

## 日常使用

以后运行同一条 `open.sh` 或 `remote.sh` 命令即可复用完整且健康的 Team。Team
完全不存在时会创建；partial 或策略不匹配的 Team 不会被静默替换。修改受管
profile、prompt 或 Planner bridge 后，应结束受影响 Team，运行
`./scripts/install.sh`，再重新创建。

并发任务必须使用不同 Team 名和互不重叠的目录。同一 Git 仓库中的并发任务应使用
独立 worktree 和 branch；详见[多 Team 隔离](docs/zh-CN/multi-team.md)。

## 测试

```bash
./scripts/test.sh static
./scripts/test.sh --team dex ping
./scripts/test.sh --team dex communication
```

`static` 不需要 live Team。Live 模式应在目标 Herdr session 中运行，并观察精确
具名 pane。`full`、`policy` 和双向 `isolation` 有更严格的 Git 与多 Team 前置
条件，见[工作流](docs/zh-CN/workflow.md)和[故障排查](docs/zh-CN/troubleshooting.md)。
静态或传输测试不能证明文件写入归属，也不能证明真机/HIL 安全。

## 安全

三个 profile 都使用 `approval_policy = "never"`。Planner 和 Reviewer 在本地保持
只读，但三个角色都有广泛的出站 command-network 权限；该权限不限于 SSH、单一
主机或 22 端口。本地只读角色仍可通过 SSH 修改远端文件或停止远端服务。

请使用专用低权限远端账号和密钥，固定 `known_hosts`，关闭 agent/port/X11
forwarding，不要把 secret 放入 prompt，并在 merge 前检查变更。对敏感代码或
运行中系统使用前，请阅读[安全](docs/zh-CN/security.md)。

## 文档

- [安装](docs/zh-CN/installation.md)和[配置](docs/zh-CN/configuration.md)
- [架构](docs/zh-CN/architecture.md)和[工作流](docs/zh-CN/workflow.md)
- [启动状态](docs/zh-CN/launch-state.md)和[多 Team 隔离](docs/zh-CN/multi-team.md)
- [安全](docs/zh-CN/security.md)和[故障排查](docs/zh-CN/troubleshooting.md)
- [与 oh-my-codex 的比较](docs/zh-CN/omx-comparison.md)
- 示例：[简单任务](examples/simple-task.md)、[完整任务](examples/full-development-task.md)、[多 Team](examples/multi-team.md)

## 卸载

```bash
./scripts/uninstall.sh
```

卸载器只会备份并移除本项目管理的 profile，不会移除 Codex、Herdr、凭据、live
session、worktree 或 Codex 基础配置。

## 许可证

[MIT](LICENSE) · [更新记录](CHANGELOG.md)

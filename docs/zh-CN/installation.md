# 安装与启动

[English](../installation.md)

本文是 README“快速开始”的详细 runbook。本机项目使用 `open.sh`，SSH 远端项目
使用 `remote.sh`。日常重复同一条命令，会复用完整且健康的 live Team。

## 要求

macOS 上已验证 Herdr 0.9.5 搭配 Codex CLI 0.171.0。升级 Herdr 后，运行 `herdr integration status` 查看各角色的集成状态。对显示 `outdated` 的集成执行相应安装命令，例如 `herdr integration install codex`。

原有启动流程的基线是 Herdr 0.8.2 和 Codex CLI 0.149.1。对话联动恢复已在 Herdr 0.8.2 搭配 Codex CLI 0.160.1 和 0.171.0 时分别验证，需要 Codex 在窗格底部和终端标题中显示对话 ID，并支持窗格内的 `/rename <名称>` 和 `/resume <UUID>`。脚本会检查自身依赖的能力，
不兼容时 fail closed。

本机需要：

- Bash、Git、Python 3、Codex 与 Herdr；
- `jq`，或用 Python 3 作为 JSON parser fallback；
- 远程模式还需要 OpenSSH 与 `tar`；
- 每台实际运行 Codex Agent 的机器都已完成 Codex 登录。

所有项目 path 必须已存在、可解析为绝对路径且不能是 `/`。主 root 与额外 root
在物理路径上不得重叠。

## 首次安装

在启动 Team 前，对一个本机 `CODEX_HOME` 运行一次：

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static && ./scripts/install.sh
```

Static 检查不会连接 live Agent；它会验证受管文件与当前 CLI surface。安装会在
`${CODEX_HOME:-$HOME/.codex}` 下写入三个可复用 role profile 和 Planner bridge，
但不会启动 Team。

若 startup 报告 `INTEGRATION_REQUIRED`，先审查提示中的 hook 与 Codex config
变更，确认所选 Herdr session 中没有 live Agent，再明确允许：

```bash
/path/to/herdr-codex-team/scripts/open.sh \
  --install-integration \
  --team dex-vut \
  --cwd /absolute/path/to/Dex_Teleop
```

## 本机项目

从 fresh、普通本机 shell 打开 named Herdr session。session 与 Team 复用同一名称，
后续 attach 和 stop 命令不会产生歧义：

```bash
herdr --session dex-vut
```

不要在已有 Herdr pane 内运行这条 attach 命令；nested Herdr 已禁用。在该 Herdr
session 管理的 shell pane 中打开一个项目：

```bash
/path/to/herdr-codex-team/scripts/open.sh \
  --team dex-vut \
  --cwd /absolute/path/to/Dex_Teleop
```

同时使用两个项目时，显式加入第二个 root：

```bash
/path/to/herdr-codex-team/scripts/open.sh \
  --team dex-vut \
  --cwd /absolute/path/to/Dex_Teleop \
  --add-dir /absolute/path/to/vut_hub-0.2.0
```

`--add-dir` 可重复。Planner 把额外 root 作为只读 workspace context，Coder
把它作为可写 context，Reviewer 仍只使用主 root。三个角色都启用受管 command
network。

`open.sh` 只有三种结果：

- 三个预期名称都不存在：创建 Team；
- 三个名称都存在且通过 Doctor：原样复用，不重启；
- 只存在一部分，或验证失败：停止，不替换任何进程。

启动后验证受管 Team：

```bash
/path/to/herdr-codex-team/scripts/doctor.sh --team dex-vut
/path/to/herdr-codex-team/scripts/test.sh --team dex-vut ping
/path/to/herdr-codex-team/scripts/test.sh --team dex-vut communication
```

进入目标会话后，用同一条 `open.sh` 创建或复用团队。要恢复三个角色的关联对话，在 Planner 窗格输入 `/resume`，选中之前的对话。

## 远端项目

远端主机需要安装选用的角色 CLI、Herdr、Bash、Git、Python 3 和 `tar`，并能访问项目目录。先在远端登录各角色选用的 CLI。远端不需要 clone 本仓库；`remote.sh` 会把校验后的 launcher
bundle 传入私有临时目录，并在结束后清理。

从 fresh、普通本机 shell 运行：

```bash
cd /path/to/herdr-codex-team
./scripts/remote.sh --host user@server --team dex-vut --cwd /home/user/workspace/Dex_Teleop

# 多项目：
./scripts/remote.sh --host user@server --team dex-vut --cwd /home/user/workspace/Dex_Teleop --add-dir /home/user/workspace/vut_hub-0.2.0
```

`--cwd` 与 `--add-dir` 后面都是远端绝对路径。本地 terminal 只显示 Herdr UI；
窗格、角色 CLI 进程和项目文件都留在 `user@server`。

若首次远端 Herdr setup 打开一个初始 UI，按 `Ctrl+B`，松开后按小写 `q`。这只
detach 当前 client；`remote.sh` 会自动继续。若远端缺少所选 CLI 的 Herdr 集成，
脚本会说明全局 hook/config 变更，并在安装前询问。

如果界面没有自动打开，请从 fresh、普通本机 shell 手工 attach；不要在另一个
Herdr pane 内执行：

```bash
herdr --remote user@server --session dex-vut
```

日常继续运行同一条 `remote.sh` 命令。只有 named remote session 与三个 Agent
process 仍存活时，原 pane 和 conversation 才可能保留。

## Detach、恢复与完全停止

Detach 不等于停止：

```text
Ctrl+B，然后按小写 q
```

这只关闭当前界面。所选 Herdr session 中的 pane 与 Agent 会继续运行。请从 fresh
本机 shell 重新 attach：

```bash
# 具名本机 session
herdr session attach dex-vut

# 具名远端 session
herdr --remote user@server --session dex-vut
```

不要从已有 Herdr pane attach；nested attach 已禁用。

只有在确认精确 scope 后，才选择停止命令：

```bash
# 只停止一个本机 Team workspace，保留其他 workspace 与该 session。
herdr --session dex-vut workspace list
herdr --session dex-vut workspace close w9

# 在拥有该 session 的主机上停止并删除一个具名 session。
herdr session stop dex-vut
herdr session delete dex-vut

# default session 也可以显式具名。
herdr session stop default
```

`herdr workspace close <workspace_id>` 适用于共享 session 中独占一个已核实
workspace 的 Team。`herdr session stop <name>` 停止所选 session；随后
`herdr session delete <name>` 删除其保存状态。示例中的 `w9` 只能替换为 startup
或 `workspace list` 打印的 workspace ID；这些命令都不会根据 Team 名猜测。

远端具名 Team 应在远端主机上使用与 `remote.sh` 相同的 PATH 完整清理：

```bash
ssh -T user@server 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"; herdr session stop dex-vut && herdr session delete dex-vut'
```

`herdr server stop` 会停止当前选定 server/session namespace 内的全部 pane；它
不是单 workspace 命令。它不会停止所有其他 named session，但仍可能终止当前
namespace 内的无关工作。不要用它退出界面或只停一个 Team。

## 修复与更新

`open.sh` 不会覆盖 partial 或 unhealthy Team。若受管 profile 或 Planner bridge
缺失或漂移，先确认所选 Herdr session 中完全没有 live Agent，再请求带备份修复：

```bash
/path/to/herdr-codex-team/scripts/open.sh \
  --repair-profiles \
  --team dex-vut \
  --cwd /absolute/path/to/Dex_Teleop \
  --add-dir /absolute/path/to/vut_hub-0.2.0
```

远程模式在原 `remote.sh` 命令上加入 `--repair-profiles`。所选 session 仍有 live
Agent 时不得使用。

修改 profile、prompt、bridge 或 startup policy source 后：

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static && ./scripts/install.sh
```

然后使用原 `--team`、`--cwd` 和有序 `--add-dir` 只重建目标 Team。正在运行的
Codex session 不会热加载受管文件或 launch policy。

## 安全边界

Planner 和 Reviewer 保持本地 `read-only` filesystem 边界；Coder 使用
`workspace-write`。三个角色都启用 command network，因此 SSH 可以工作。这是
广泛网络权限，不限于 SSH 或单个 host。本地只读不会阻止 SSH 命令改变远端主机，
`approval_policy = "never"` 也没有日常交互检查点。

请使用专用低权限远端账号和密钥、固定 `known_hosts`、`BatchMode=yes`、
`IdentitiesOnly=yes`，并禁用 agent、port 和 X11 forwarding。完整边界见
[安全](security.md)。Doctor 证明 launch policy，不证明远端主机安全，也不证明
硬件/HIL 验证通过。

## 卸载

处理完所有 live Team 后，再检查并运行可恢复卸载：

```bash
cd /path/to/herdr-codex-team
./scripts/uninstall.sh
```

它只处理受管文件，不是 Herdr Team 或 session 的停止命令。

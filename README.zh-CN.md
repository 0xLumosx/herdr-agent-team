# Herdr Agent Team

[English](README.md)

在 [Herdr](https://herdr.dev/) 里启动三个协作角色，各用一个终端窗格。每个角色都可以选用 Codex、Claude Code 或 Antigravity CLI。先和 Planner 讨论方案，再由 Coder 实现。最终审查报告只在右下角的 Reviewer 窗格展示。左侧 Planner 窗格给出验收决定。每个角色收到的任务和给出的回复都可以在对应窗格里查看。

## 本地快速开始

### 在当前目录一键启动

进入要开发的项目目录，在普通终端运行：

```bash
herdr --team
```

新团队的三个角色都用 Codex。左半边是 Planner，右上是 Coder，右下是 Reviewer。再次从同一目录运行会回到原团队。要换某个角色的 CLI，在那个窗格里退出当前 CLI，回到 shell 后输入 `claude`、`gemini` 或 `codex`。`gemini` 调用 Antigravity CLI。切回已用过的 CLI 会恢复这个角色在当前对话组里的原生会话。

搭配本地汉化版 Herdr 时，菜单和设置默认显示中文，主题名和产品名保留原文。要以英文打开新会话，可运行 `HERDR_LANG=en herdr --team`。

在其他机器上启用快捷命令时，将本仓库的 `scripts/herdr-team` 链接到 PATH 中的同名位置，并在交互式 Bash 或 Zsh 的启动文件中加载 `scripts/team-shell.sh`。下面的长命令仍可用于指定团队名、项目目录或初始 CLI。

### 首次安装

本机需要 Bash、Git 和 Python 3。先登录各角色要使用的 CLI。Codex 需要支持角色配置和权限配置，Herdr 需要支持命名会话及所选 CLI 的集成。脚本优先使用 `jq` 解析 JSON，缺少时会使用 Python。

在普通终端进入本仓库，运行静态检查并安装三个角色的配置和 Planner 通信桥。命令中的示例路径请换成本机的实际路径。

```bash
cd /path/to/herdr-agent-team
./scripts/test.sh static && ./scripts/install.sh
```

本地一键启动、三角色布局和对话联动恢复已在 macOS 上用 Herdr 0.9.5 和 Codex CLI 0.171.0 验证。原有启动流程的兼容性基线是 Herdr 0.8.2 和 Codex CLI 0.149.1。此前也用 Herdr 0.8.2 搭配 Codex CLI 0.160.1 和 0.171.0 分别验证过对话恢复。启动脚本按实际功能判断兼容性。安装或更新 Codex 钩子前，先查看 `herdr integration status`。如果启动时报集成缺失，核对提示中的变更，再按提示使用 `--install-integration`。[安装与兼容性](docs/zh-CN/installation.md)

### 打开项目

在普通终端打开 Herdr 会话。会话和团队用同一个短名称，后面重新连接时更容易找到。下面的示例都用 `dex`。

```bash
herdr --session dex
```

进入 Herdr 窗口后，在其中的 shell 窗格运行 `open.sh`。项目目录填你要处理的代码所在目录。

```bash
/path/to/herdr-agent-team/scripts/open.sh --team dex --cwd /path/to/project
```

如果同一项工作涉及多个项目，启动时改用下面的写法。每个额外目录对应一个 `--add-dir`。Planner 可以读取额外目录，Coder 可以修改，Reviewer 的工作范围仍是主目录。

```bash
/path/to/herdr-agent-team/scripts/open.sh --team dex --cwd /path/to/app --add-dir /path/to/lib
```

团队就绪后，在 `dex-planner` 窗格里输入任务。它只会派单给同队的 `dex-coder` 和 `dex-reviewer`。如果无法确认对方属于当前团队，派单会停止。[第一个任务示例](examples/simple-task.md)

### 为每个角色选择 CLI

新团队默认都用 Codex。下面的命令让 Claude 做 Planner、Codex 做 Coder、Antigravity 上的 Gemini 做 Reviewer。在 Herdr 的 shell 窗格中运行：

```bash
REVIEWER_MODEL=gemini-3.8-flash-high ./scripts/open.sh --team dex --cwd /path/to/project \
  --planner-cli claude --coder-cli codex --reviewer-cli agy
```

三项的可选值都是 `codex`、`claude` 和 `agy`。用 `agy models` 查看当前账号可用的模型。先在终端完成所选 CLI 的登录和首次启动。如果 Herdr 提示缺少集成，加上 `--install-integration` 安装所选 CLI 的钩子。

在 Planner 输入 `/resume` 并选中已绑定的旧会话，空闲的 Coder 和 Reviewer 会各自切回当时的会话。再次打开同一个运行中的团队时，可以省略 CLI 参数。恢复以前的组合时，使用原来的团队名、项目目录、额外目录以及角色 CLI。尚未绑定的旧会话可以用 `--link-current PLANNER_UUID CODER_UUID REVIEWER_UUID` 登记。

需要访问远端项目时，直接告诉 Planner SSH 别名和目录。Coder 会在同一远端目录工作，Reviewer 可以通过 SSH 读取实际文件和 Git 差异。切回旧会话时，SSH 目的地也随之恢复。[团队 SSH 配置](docs/zh-CN/configuration.md)

## 三个角色如何分工

```text
用户 ↔ Planner → Coder → Planner ↔ Reviewer
最终审查报告 → Reviewer 窗格
验收决定 → Planner 窗格
```

| 角色 | 本地文件权限 | 工作内容 |
| --- | --- | --- |
| Planner | read-only | 判断方案是否合理、正确；有分歧或关键歧义时先与你讨论，明确后派单并核对验收结果 |
| Coder | workspace-write | 执行 Planner 的任务和它转交的 Reviewer 修正指令，运行检查；遇阻向 Planner 报告 |
| Reviewer | read-only | 独立审查，疑问先与 Planner 讨论；仍需你决定时由 Planner 原文转达，最后在自己的窗格给出审查报告 |

Herdr 运行窗格和会话。本仓库提供角色配置、提示词、按需运行的启动脚本、诊断和测试。分支由 Git 管理，对话历史由各自的 CLI 保存。只有选用 Codex 的角色才强制加载 Stop That Shit。各角色的默认模型、推理强度和技能模式见[角色配置](docs/zh-CN/configuration.md)。

## 日常使用

### 离开、回来和检查状态

暂时离开时，按 `Ctrl+B`，松开后按小写 `q`。三个角色会继续运行。要回到已有会话，在 Herdr 窗口外的普通本地终端执行以下命令。默认设置禁止在 Herdr 窗格里嵌套连接。

```bash
herdr session attach dex
```

要切回另一组已保存的对话，在 `dex-planner` 窗格输入 `/resume` 并选中原来的 Planner，也可以直接输入 `/resume <Planner UUID>`。Coder 和 Reviewer 会在各自的窗格恢复与它配对的对话。三个窗格底部显示当前对话 ID，派单前会核对这三个 ID。首次关联旧对话的操作见[对话恢复](docs/zh-CN/launch-state.md#恢复对话)。

要确认当前会话里的团队是否正常，在该会话的 shell 窗格里运行 Doctor。

```bash
/path/to/herdr-agent-team/scripts/doctor.sh --team dex
```

再次运行原来的 `open.sh` 命令，会复用通过检查的三个角色。如果角色全都不存在，启动器会在当前窗口创建团队。如果只剩部分角色或配置与预期不符，启动器会报错并保留现场。[故障排查](docs/zh-CN/troubleshooting.md)

修改角色配置、提示词或 Planner 通信桥后，先结束受影响的团队，再从本仓库运行 `./scripts/install.sh`，用原来的项目目录重建团队。同时做多项任务时，各团队使用不同的名称和互不重叠的目录。同一 Git 仓库里的并发任务应各用一个工作树和分支。[多团队隔离](docs/zh-CN/multi-team.md)

### 结束任务

多个团队共用会话时，用 `herdr --session dex workspace close <workspace-id>` 只关闭目标工作区。要结束整个本地会话，先退出界面，再在普通终端运行下面的命令。

```bash
herdr session stop dex && herdr session delete dex
```

`stop` 会终止该会话的所有窗格进程，`delete` 会删除 Herdr 保存的会话状态。项目文件、各 CLI 的对话历史和启动记录仍会保留。[启动记录](docs/zh-CN/launch-state.md)

## 项目在 SSH 主机上时

在本机的普通终端进入本仓库，运行 `remote.sh`。Herdr 界面开在本机，三个角色在远端运行，直接访问远端项目目录。本机需要 OpenSSH 和 `tar`。远端需要安装三个角色选用的 CLI、完成登录，并备齐安装文档列出的工具。启动器会传送所需脚本，远端无需另行克隆本仓库。

```bash
./scripts/remote.sh --host user@server --team dex --cwd /remote/project
```

远端项目分布在多个目录时，可以在启动时一并指定。下次运行同一条 `remote.sh` 命令，会复用通过检查的团队。

```bash
./scripts/remote.sh --host user@server --team dex --cwd /remote/app --add-dir /remote/lib
```

远端会话仍在运行时，可以从 Herdr 窗口外的普通本地终端直接连回去。

```bash
herdr --remote user@server --session dex
```

要终止整个远端会话并删除保存的会话状态，在普通本地终端执行以下命令。

```bash
ssh -T user@server 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"; herdr session stop dex && herdr session delete dex'
```

## 测试

从本仓库目录运行测试。`static` 可以在启动团队之前运行。`ping` 和 `communication` 要在目标 Herdr 会话的 shell 窗格执行。前者直接联系 Coder 和 Reviewer，后者通过 Planner 派单。运行时可以在对应角色的窗格里查看回复。

```bash
./scripts/test.sh static
./scripts/test.sh --team dex ping
./scripts/test.sh --team dex communication
```

`full`、`policy` 和双向 `isolation` 各有相应的 Git 或多团队前置条件。若需要追查文件由哪个进程写入，或验证真机和硬件在环（HIL）安全，还需单独取证。[测试流程](docs/zh-CN/workflow.md) · [排查测试失败](docs/zh-CN/troubleshooting.md)

## 权限与安全

三个角色都使用 `approval_policy = "never"`，执行命令时不会逐条请求批准。它们可以连接不同主机，也可以使用 SSH 以外的协议和 22 以外的端口。Planner 和 Reviewer 的只读权限约束本地文件。通过 SSH 登录后，远端账号的权限决定它们能否修改文件或停止服务。

使用专用的低权限远端账号和密钥，固定 `known_hosts`，关闭 SSH 代理、端口和 X11 转发。提示词中不要放密钥或其他秘密，合并前检查实际变更。在敏感代码或运行中的系统上使用前，请阅读[安全说明](docs/zh-CN/security.md)。

## 文档和示例

| 我想了解 | 文档 |
| --- | --- |
| 团队怎样派单和验收 | [架构](docs/zh-CN/architecture.md) · [工作流](docs/zh-CN/workflow.md) · [与 oh-my-codex 的比较](docs/zh-CN/omx-comparison.md) |
| 怎样安排完整任务或并行开发 | [完整开发任务](examples/full-development-task.md) · [多团队隔离](docs/zh-CN/multi-team.md) · [多团队示例](examples/multi-team.md) |
| 运行环境和权限要求 | [安装](docs/zh-CN/installation.md) · [安全](docs/zh-CN/security.md) |

## 卸载

在本仓库目录运行卸载脚本。

```bash
./scripts/uninstall.sh
```

脚本会把本项目安装的角色配置和 Planner 通信桥移到带日期的备份目录。Codex、Herdr、凭据、正在运行的会话、Git 工作树和 Codex 基础配置都会保留。

[MIT](LICENSE) · [更新记录](CHANGELOG.md)

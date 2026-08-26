# 安装

[English](../installation.md)

## 安装前

请使用普通用户账号，不要以 `sudo` 运行脚本。安装器会在当前用户的 Codex home 下写入角色 profile，不应需要系统级访问权限。

兼容性约定是所需 CLI surface。开发 host 使用以下版本进行了检查：

```text
herdr 0.8.2
codex-cli 0.149.1
```

这些版本是截至 2026-08-25 已知的检查基线，不是精确锁定。`doctor.sh` 和 `start.sh` 还会验证其依赖的命令，因此不兼容的新版本会尽早失败。

## 1. 验证基础工具

```bash
codex --version
codex --help
herdr --version
herdr --help
git --version
```

Codex 必须支持 `$CODEX_HOME/<name>.config.toml` 中的 `--profile` 文件。Herdr 必须公开 `status`、`workspace`、`pane` 和 `agent` command group。即使请求的项目目录是 non-Git，仍需要 Git CLI 做保守 scope discovery。启动 Team 前，先通过 Codex 正常支持的 login 流程完成身份验证。`doctor.sh` 和 `start.sh` 执行详细 command-surface 检查；`install.sh` 首先确认 Codex 和 Herdr binary 存在并报告版本。

Startup、诊断和 live test 还需要真实 JSON 解析器：可安装 `jq`，也可保留 Python 3 作为标准库 fallback。Full workflow demo 会运行独立 assertion，因此无论是否安装 `jq` 都需要 Python 3。

Herdr 官方设置指南位于 <https://herdr.dev/agent-guide.md>。Codex 官方 profile-file 行为见[配置参考](https://developers.openai.com/codex/config-reference/)。

## 2. 检查仓库

```bash
cd /path/to/herdr-codex-team
git status --short
```

安装前请阅读 profile 模板和角色 prompt，尤其是：

```text
profiles/planner.config.toml
profiles/coder.config.toml
profiles/reviewer.config.toml
prompts/planner.md
prompts/coder.md
prompts/reviewer.md
```

不要把私有设置、API key、provider endpoint 或机器 path 复制到仓库模板中。

## 3. 安装 Profile

```bash
./scripts/install.sh
```

也可以在安装时选择角色模型，无需编辑仓库模板：

```bash
PLANNER_MODEL="<available-model>" \
CODER_MODEL="<available-model>" \
REVIEWER_MODEL="<available-model>" \
./scripts/install.sh
```

每个变量相互独立；某个变量未设置时，保留该模板的模型设置。

除非已经设置 `CODEX_HOME`，目标目录默认为 `~/.codex`。安装文件为：

```text
~/.codex/planner.config.toml
~/.codex/coder.config.toml
~/.codex/reviewer.config.toml
```

如果目标已存在，安装器会先将其复制到带时间戳的备份目录，例如：

```text
~/.codex/herdr-codex-team-backup-20260824-153000/
```

基础 `~/.codex/config.toml` 保持不变，继续提供 account、provider 和其他 user-level 设置；选择角色 profile 时，它会叠加在基础配置之上。

即使运行多个 Team，也只会安装这三个 profile。例如 `github-coder` 和 `auth-coder` 都选择通用 `coder` profile。Team 身份属于 Herdr 实时名称，不属于复制出来的 profile。

重复运行安装器时，每个冲突 profile 都会先备份，因此不会直接丢失原文件。但这不是 merge。请检查打印出的备份，但只能把顶层 `model = ...` 赋值直接恢复到已安装角色文件。Reasoning、sandbox、approval 和角色指令是受管字段；应在仓库模板中应用有意变更，运行静态检查后重新安装。Credential、provider endpoint 和私有机器 path 应留在用户本地配置中，不得放入仓库模板。

## 4. 检查 Herdr Integration 和 Hook

检查 integration 状态：

```bash
herdr integration status
```

如果脚本报告 Codex integration 缺失，请在运行其建议命令前查看 Herdr 当前 help 和官方说明。在已检查的 Herdr 0.8.2 command surface 中，相关 integration command group 是：

```bash
herdr integration install codex
```

Integration 可能添加或修改 Codex hook。此时 Codex 可能显示 `1 hook is new or changed` 等警告。不要盲目绕过警告。请检查 hook 文件，确认来源是你预期的 Herdr 安装，理解其执行内容，完成审查后再信任。安装器刻意不会强制信任 hook。

## 5. 启动前运行诊断

```bash
./scripts/doctor.sh
```

Team 尚未存在时，binary 和 profile 检查应通过，而 live-agent 检查可能正确报告请求名称不存在。Legacy 名称使用 `doctor.sh`；带前缀的 Team 使用 `doctor.sh --team <prefix>`。在启动前状态下，它会以非零值退出；根据消息区分预期的 Team 缺失和 binary、profile 或 integration 问题。

## 启动 Team

### 远程模式：本地界面，远端 Agent 和文件

不要使用 SSHFS 把项目伪装成本地目录。本模式采用 Herdr 官方的 SSH thin
client：本地只渲染 TUI，远端 Herdr server 持有 pane、三个 Codex 进程和项目
文件。因此这里的 `--cwd` 与 `--add-dir` 都必须是远端绝对路径。

本地需要本仓库、Herdr、OpenSSH 和 `tar`。远端需要 Codex、Bash、Git、`tar`、
`jq` 或 Python 3，以及 `sha256sum`、`shasum`、`openssl` 中任意一个；常见 Ubuntu
通常已具备除 `jq` 外的大部分工具。远端项目目录必须已经存在，并允许 SSH 用户
访问。

首次只需在远端完成 Codex 登录；headless SSH 主机优先使用 device auth：

```bash
# 远端：安装 Codex 并完成登录。无需 clone herdr-codex-team。
ssh my-server
codex login status || codex login --device-auth
exit
```

之后首次创建 Team 和继续仍存活的对话，都在本地运行同一条命令：

```bash
cd /path/to/local/herdr-codex-team
./scripts/remote.sh \
  --host my-server \
  --team dex \
  --cwd /home/REMOTE_USER/Dex_Teleop
```

如果远端 Herdr binary 需要首次安装/更新，或已有 named server 与当前 binary
不兼容，`remote.sh` 会自动先打开 Herdr 支持的 setup/update 流程。它准备好后按
`Ctrl+B`、再按 `Q` detach；同一个脚本会
自动继续，无需再输入第二条命令。随后它通过 SSH 选择名为 `dex` 的远端 Herdr
session，把本地当前版本的固定白名单启动文件流式传到远端私有临时目录，执行
`open.sh` 的 create-or-reuse 判定，清理临时目录，然后运行本地 thin client。
所以远端不需要第二份仓库，也没有两份脚本版本漂移的问题。远端使用明确的
`$HOME/.codex`；三个受管 profile 全部不存在时会自动完成首次安装。若 Herdr
Codex integration 缺失或过期，同一命令会显示其 hook/config
修改边界，并等待一次明确的 `y`；确认后才安装并自动继续。已有或部分存在的
profile 不会由便利路径自动覆盖。

setup/update attach 会显式请求 Herdr `--handoff`，尽量在 binary 交接时保留 live
pane 进程。它不是无条件保证：若 Herdr 提示需要 stop/restart 旧 server，而原对话
仍然重要，不要批准停止；先退出并保留当前 server，检查版本与 handoff 失败原因。

只有脚本明确报告 profile 缺失或漂移、并且该 named session 中没有 live Agent 时，
才在原命令加一个修复开关：

```bash
./scripts/remote.sh --repair-profiles \
  --host my-server \
  --team dex \
  --cwd /home/REMOTE_USER/Dex_Teleop
```

该开关调用 `install.sh`，先备份已有三个受管 profile，再以当前版本替换；只要所选
session 中还有任一 Agent，它就拒绝修改。正常创建和日常续接不需要这个开关。

日常关闭请按 `Ctrl+B`、再按 `Q` detach Herdr client，不要停止远端 server 或
退出三个 Agent。再次运行同一条 `remote.sh` 命令时，完整且通过 Doctor 的 live
Team 会输出 `TEAM_REUSED`。若存在启动记录，Doctor 还会绑定保存的
workspace/pane ID；这能排除不同 pane/workspace，但记录没有 PID 或 conversation ID，
不能独自证明仍是上次对话。如果三个名称都不存在，会创建新对话并输出
`TEAM_CREATED`；只剩 1/3 或 2/3 时输出 `TEAM_PARTIAL`，三个都在但验证失败时输出
`TEAM_UNSAFE`。后两种情况仍会打开界面供检查，但命令最终返回非零；这不是恢复
成功，也不会自动停止、覆盖或补建 Agent。

这项简化针对最常见的“关闭本地窗口后继续”。远端主机或 Herdr server 真正
重启后，Herdr 0.8.2 可能尝试原生 `codex resume`，但它不会重放本项目全部受管
启动参数；因此对话文本可能恢复，而 `doctor.sh` 仍可能正确拒绝该进程。启动记录
只校验身份，不保存或恢复对话；当前入口不会为追求表面成功而放宽
sandbox/profile/root 验证。

### 1. 通过 Herdr 进入主项目目录

```bash
cd /absolute/path/to/your-project
herdr
```

Herdr 会把 `HERDR_ENV=1` 及 pane/workspace identifier 注入受管理 pane。在 shell pane 中可以验证：

```bash
test "${HERDR_ENV:-}" = 1 && echo "inside Herdr"
```

Startup 脚本使用明确返回的 identifier 创建新 workspace，不依赖 UI 当前聚焦 pane。如果从普通外部 shell 调用，请先确认 `herdr status server` 能连接到目标本地 Herdr server。

### 2. 运行启动辅助脚本

启动带前缀的 Team：

```bash
/absolute/path/to/herdr-codex-team/scripts/start.sh \
  --team github \
  --cwd /absolute/path/to/primary-project \
  --add-dir /absolute/path/to/second-project
```

接口为：

```text
start.sh [--no-focus] [--team PREFIX] [--cwd PROJECT_DIR] [--add-dir DIR]... [PROJECT_DIR]
```

`PROJECT_DIR` 默认为当前目录，并成为 Herdr workspace 和 pane 的主 cwd。位置参数形式为向后兼容而保留；不要与 `--cwd` 同时提供。`--add-dir` 可重复，并为 Planner 和 Coder 提供请求的额外可写 root。Reviewer 保持 `read-only`，启动时不传 `--add-dir`。每个目录都必须存在、能安全解析、不是 `/`，且与其他请求 root 物理上互不重叠。`--no-focus` 要求 startup 保留当前 focus。`--team github` 生成 `github-planner`、`github-coder` 和 `github-reviewer`；省略后保留 legacy 名称 `planner`、`coder` 和 `reviewer`。

Herdr 返回 workspace ID 后，startup 会在 `$CODEX_HOME/herdr-codex-team/state/v1/teams/{legacy|prefixed-<team-prefix>}/current.json` 写入一份私有、原子替换的启动记录。它保存每次 helper 调用的 `run_id`、有序 root、精确实时名称、workspace/pane ID 和最近启动 observation（`starting`、`partial` 或 `ready`）。`partial` 表示可能留下了 workspace 供诊断；应先检查，不能盲目重跑 startup。记录不包含 task 或 conversation state。详见[启动状态](launch-state.md)。

位于 Git worktree 中不再是 startup 前置条件。Single-root 与 multi-root 模式都允许使用现有 non-Git 目录；Git CLI 仍用于保守识别 worktree scope。对每个 non-Git root，`git status`、完整 diff、untracked-file enumeration、rollback 和预存变更归属都不可用。Agent 必须把该 Git 证据标为 `NOT AVAILABLE`，不得从直接文件检查中推断。

`TEAM_PREFIX=github` 是环境变量替代方式。如果环境变量和 `--team` 均指定值，则必须一致。Startup 会验证三个生成名称，并在创建 workspace 前检查所有名称是否冲突。如果出现 `agent_name_taken` 等冲突，它会停止，不会重命名、删除或替换现有 Team。

使用另一个唯一前缀即可创建并发 Team：

```bash
/absolute/path/to/herdr-codex-team/scripts/start.sh \
  --team auth \
  --cwd /absolute/path/to/another-project
```

不同仓库可以安全使用不同 root set。并发 Team 的每个主 root 和额外 root 在物理路径与 Git-worktree 解析后都必须互不重叠。同一仓库中的两个任务应在 startup 前使用独立 branch 和 Git worktree；脚本不会创建、merge 或移除 worktree。详见[多 Team 隔离](multi-team.md)。

对单次运行，可以用模型环境变量为相应角色添加 Codex `--model` 覆盖，而不重写已安装文件：

```bash
PLANNER_MODEL="<available-model>" \
CODER_MODEL="<available-model>" \
REVIEWER_MODEL="<available-model>" \
/absolute/path/to/herdr-codex-team/scripts/start.sh \
  --no-focus --team github --cwd "$PWD"
```

只有在以下命令显示精确请求的三个 Herdr 实时名称时，才算启动成功：

```bash
herdr agent list
```

对于 `--team github`，这三个名称是 `github-planner`、`github-coder` 和 `github-reviewer`；legacy 模式中是 `planner`、`coder` 和 `reviewer`。三个 pane 仅仅包含 kind 为 `codex` 的 process，不能满足名称要求。

这只确认进程已启动，并不确认完整安全姿态。发出工作前运行 Team-aware Doctor。存在记录时，`doctor.sh --team github` 会读取保存的启动预期值；显式复用同一 `--cwd` 和有序 `--add-dir` 则直接检查 scope，并绕过所记录的 workspace/pane binding。Doctor 会验证已安装 sandbox/approval 设置、profile load、integration、精确身份、readiness、lifecycle state、workspace/pane/cwd 关联、前台 `--profile <role>` 绑定、受管的空 `sandbox_workspace_write.writable_roots` 覆盖、显式 sandbox 和角色专属额外 root argv。Working agent 会报告为 warning；communication 测试要求所有相关目标都 settled 为 `idle` 或 `done`，并绑定匹配的通用角色 profile。

### 已验证的手动原语

如果自动化停止，请先查看当前 binary 的 `--help`，再执行手动恢复。Herdr 0.8.2 提供以下原语：

对于带前缀的团队，workspace 标签刻意保持为较短的 `codex-team:<team>`；
live Agent 名称和 `--cwd` 仍分别保留角色与项目身份。Legacy 模式继续使用
`codex-team:<project>`。

```bash
# Planner 和 Coder 使用这个可写 root；Reviewer 有意不使用。
EXTRA_ROOT=/absolute/path/to/second-project

# 创建隔离 workspace，并从 JSON 响应读取 root pane ID。
herdr workspace create --cwd "$PWD" --label "codex-team:github" \
  --env "CODEX_HOME=${CODEX_HOME:-$HOME/.codex}" --no-focus

# 只 split 前序命令返回的 pane。
herdr pane split <root-pane-id> --direction right --ratio 0.5 --cwd "$PWD" \
  --env "CODEX_HOME=${CODEX_HOME:-$HOME/.codex}" --no-focus
herdr pane split <right-pane-id> --direction down --ratio 0.5 --cwd "$PWD" \
  --env "CODEX_HOME=${CODEX_HOME:-$HOME/.codex}" --no-focus

# 使用精确受管 root set 启动 Codex process。
herdr agent start github-planner --kind codex --pane <planner-pane-id> -- \
  --profile planner -c 'sandbox_workspace_write.writable_roots=[]' \
  --sandbox workspace-write --add-dir "$EXTRA_ROOT"
herdr agent start github-coder --kind codex --pane <coder-pane-id> -- \
  --profile coder -c 'sandbox_workspace_write.writable_roots=[]' \
  --sandbox workspace-write --add-dir "$EXTRA_ROOT"
herdr agent start github-reviewer --kind codex --pane <reviewer-pane-id> -- \
  --profile reviewer -c 'sandbox_workspace_write.writable_roots=[]' \
  --sandbox read-only
```

`agent start` 要求目标 pane 正处在 interactive shell prompt；它不会创建 pane。Agent 原生参数应放在 `--` 之后。

如果你正在修复自己拥有、且 pane 已经明确确认的 Agent，Herdr 0.8.2 支持：

```bash
herdr agent rename <agent-name-or-pane-id> github-planner
```

其他角色使用精确的同 Team Coder 或 Reviewer 名称。名称必须唯一。绝不能为了处理冲突而重命名另一个 Team 的 Agent。不要根据 sidebar 顺序推导 pane ID；应从 Herdr JSON 响应或 `herdr pane list` 复制。

### 3. 重新运行诊断

接口为：

```text
doctor.sh [--team PREFIX] [--cwd PROJECT_DIR] [--add-dir DIR]...
```

```bash
/absolute/path/to/herdr-codex-team/scripts/doctor.sh --team github

# 用显式 scope 诊断 stale/已替换 runtime：
/absolute/path/to/herdr-codex-team/scripts/doctor.sh \
  --team github \
  --cwd /absolute/path/to/primary-project \
  --add-dir /absolute/path/to/second-project
```

未提供任何 root option 时，Doctor 会读取请求 Team 最近的安全启动记录，把其中的 root、workspace ID 和 pane ID 作为待向 Herdr 重新核实的预期值。显式提供时，必须按 `start.sh` 的相同顺序传入全部额外 root；`--add-dir` 要求同时传入 `--cwd`。显式形式绕过记录的 workspace/pane binding，但不修改记录。Doctor 会验证角色专属 argv：Planner/Coder 必须携带精确的有序列表，Reviewer 必须不携带 `--add-dir`。此时 binary、on-disk profile、前台 profile/sandbox/root 绑定、runtime、name 和 state 检查应该都有足够 live data 可供评估。这只证明 launch argv，不证明实际读写成功或 Git 历史。如果平台无法公开前台 process arguments，诊断会 fail closed，而不是把 renamed stale session 当作有效角色。

### 4. 建立通信证据

接口为：

```text
test.sh [--team PREFIX] [--against-team PREFIX] static|ping|communication|full|policy|isolation
```

```bash
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github ping
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github communication
```

`ping` 和 `communication` 不要求 Git root；它们只提供有界的传输证据。测试期间观察 live pane。即使 Planner 声称 Coder 已回复，只要 Herdr Coder pane 从未收到输入或 lifecycle state 未发生变化，就不足以作为证据。

对于 `full` 和 `policy` 测试，当前目录也是各自 nested disposable fixture 的默认 host：

```bash
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github full
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github policy
```

如果 shell 必须位于别处，设置 `HERDR_TEST_PROJECT_DIR=/absolute/path/to/the-project-used-by-start.sh`。脚本在创建 nested fixture 前，会验证整个 host Git worktree 有 committed `HEAD` 且 clean；请使用 disposable worktree，不要仅为满足测试而隐藏或 stash 变更。

当主 `--cwd` 为 non-Git 时，它不能成为该 host；必须把这个 Team 的 `full` 和 `policy` 记为 `NOT RUN`。如果 Git-backed 主 root 与 non-Git 额外 root 组合使用，主 root 下 fixture 的通过不能建立 non-Git root 的 baseline、完整变更 scope、rollback 或 writer attribution。

当两个带前缀 Team 都处于 live 且 settled 状态时，从两个方向测试跨 Team 隔离：

```bash
/absolute/path/to/herdr-codex-team/scripts/test.sh \
  --team github --against-team auth isolation
/absolute/path/to/herdr-codex-team/scripts/test.sh \
  --team auth --against-team github isolation
```

`--against-team` 只在 `isolation` 中必需。若两个真实 Team 不可用，应把此检查报告为 `NOT RUN`；静态名称解析不是 live 路由证据。本次更新所在环境没有运行 live isolation。单次命令只验证一个方向；要验证反方向，必须交换 `--team` 和 `--against-team` 后再次运行。Isolation 只检查具名 Agent 的 transcript 与 lifecycle sequence，不建立各 root 间的文件系统非干扰证据。

## 更新 Profile

仅修改模型时，优先使用文档中的 `PLANNER_MODEL`、`CODER_MODEL` 或 `REVIEWER_MODEL` 覆盖。若直接编辑已安装文件，只支持顶层 `model = ...` 赋值；它不纳入受管 policy digest。

修改 reasoning、sandbox、approval 或角色指令时，必须编辑 `profiles/` 或 `prompts/` 下的对应 source，运行 `test.sh static`，再运行 `install.sh`。`doctor.sh` 和 `start.sh` 会拒绝这些受管字段在已安装文件中的直接漂移。两类持久变更后，都要先保留任务 context 和项目变更，只关闭请求 Team 的三个旧 session，再使用当前 `start.sh` 和原来的 root 参数重建该 Team：

```bash
/path/to/herdr-codex-team/scripts/start.sh \
  --team github \
  --cwd /absolute/path/to/primary-project \
  --add-dir /absolute/path/to/second-project
/path/to/herdr-codex-team/scripts/doctor.sh \
  --team github \
  --cwd /absolute/path/to/primary-project \
  --add-dir /absolute/path/to/second-project
```

Legacy 模式下，两条命令都省略 `--team`。普通 `codex --profile <role>` 不会复现受管 sandbox/root argv，因此无法通过受管 process 检查。已经运行的 session 不会自动重新加载 profile 变化。重新运行 `install.sh` 会在备份后替换三个已安装角色文件。

## 静态验证与卸载

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static
```

Static 模式检查必需文件、shell 语法、角色 guardrail、安装渲染和备份行为、可恢复卸载行为，以及当前 Codex 是否能在不访问 live agent 的情况下加载每个渲染 profile。在 Codex CLI 0.149.1 上，load smoke test 使用 `codex --profile <role> debug prompt-input`；它是 configuration-load check，不是 live agent/model 测试，也不严格保证所有 unknown field 都会被拒绝。

卸载 profile：

```bash
./scripts/uninstall.sh
```

卸载范围刻意保持最小：本项目安装的角色 profile 会被移到新的时间戳备份中。它不会卸载 Codex 或 Herdr、删除 credential、删除基础 Codex 配置、移除无关 hook、删除备份目录或移除用户本地启动记录。

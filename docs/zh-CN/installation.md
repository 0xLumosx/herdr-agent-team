# 安装

[English](../installation.md)

## 安装前

请使用普通用户账号，不要以 `sudo` 运行脚本。安装器会在当前用户的 Codex home 下写入角色 profile，不应需要系统级访问权限。

兼容性约定是所需 CLI surface。开发 host 使用以下版本进行了检查：

```text
herdr 0.8.2
codex-cli 0.147.0
```

这些版本是截至 2026-08-24 已知的检查基线，不是精确锁定。`doctor.sh` 和 `start.sh` 还会验证其依赖的命令，因此不兼容的新版本会尽早失败。

## 1. 验证基础工具

```bash
codex --version
codex --help
herdr --version
herdr --help
```

Codex 必须支持 `$CODEX_HOME/<name>.config.toml` 中的 `--profile` 文件。Herdr 必须公开 `status`、`workspace`、`pane` 和 `agent` command group。启动 Team 前，先通过 Codex 正常支持的 login 流程完成身份验证。`doctor.sh` 和 `start.sh` 执行详细 command-surface 检查；`install.sh` 首先确认两个 binary 存在并报告版本。

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

### 1. 通过 Herdr 进入目标仓库

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
  --cwd "$PWD"
```

接口为：

```text
start.sh [--no-focus] [--team PREFIX] [--cwd PROJECT_DIR] [PROJECT_DIR]
```

`PROJECT_DIR` 默认为当前目录，并且必须位于 Git worktree 中。位置参数形式为向后兼容而保留；不要与 `--cwd` 同时提供。`--no-focus` 要求 startup 保留当前 focus。`--team github` 生成 `github-planner`、`github-coder` 和 `github-reviewer`；省略后保留 legacy 名称 `planner`、`coder` 和 `reviewer`。

`TEAM_PREFIX=github` 是环境变量替代方式。如果环境变量和 `--team` 均指定值，则必须一致。Startup 会验证三个生成名称，并在创建 workspace 前检查所有名称是否冲突。如果出现 `agent_name_taken` 等冲突，它会停止，不会重命名、删除或替换现有 Team。

使用另一个唯一前缀即可创建并发 Team：

```bash
/absolute/path/to/herdr-codex-team/scripts/start.sh \
  --team auth \
  --cwd /absolute/path/to/another-project
```

不同仓库可以安全使用不同 `--cwd`。同一仓库中的两个任务应在 startup 前使用独立 branch 和 Git worktree；脚本不会创建、merge 或移除 worktree。详见[多 Team 隔离](multi-team.md)。

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

这只确认进程已启动，并不确认完整安全姿态。发出工作前，运行 Team-aware doctor，以验证已安装 sandbox/approval 设置、profile load、integration、精确身份、readiness、lifecycle state、workspace/pane/cwd 关联和前台 `--profile <role>` 参数。Working agent 会报告为 warning；communication 测试要求所有相关目标都 settled 为 `idle` 或 `done`，并绑定匹配的通用角色 profile。

### 已验证的手动原语

如果自动化停止，请先查看当前 binary 的 `--help`，再执行手动恢复。Herdr 0.8.2 提供以下原语：

对于带前缀的团队，workspace 标签刻意保持为较短的 `codex-team:<team>`；
live Agent 名称和 `--cwd` 仍分别保留角色与项目身份。Legacy 模式继续使用
`codex-team:<project>`。

```bash
# 创建隔离 workspace，并从 JSON 响应读取 root pane ID。
herdr workspace create --cwd "$PWD" --label "codex-team:github" \
  --env "CODEX_HOME=${CODEX_HOME:-$HOME/.codex}" --no-focus

# 只 split 前序命令返回的 pane。
herdr pane split <root-pane-id> --direction right --ratio 0.5 --cwd "$PWD" \
  --env "CODEX_HOME=${CODEX_HOME:-$HOME/.codex}" --no-focus
herdr pane split <right-pane-id> --direction down --ratio 0.5 --cwd "$PWD" \
  --env "CODEX_HOME=${CODEX_HOME:-$HOME/.codex}" --no-focus

# 在现有 shell pane 中启动受支持 Codex process。
herdr agent start github-planner --kind codex --pane <planner-pane-id> -- --profile planner
herdr agent start github-coder --kind codex --pane <coder-pane-id> -- --profile coder
herdr agent start github-reviewer --kind codex --pane <reviewer-pane-id> -- --profile reviewer
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
doctor.sh [--team PREFIX] [--cwd PROJECT_DIR]
```

```bash
/absolute/path/to/herdr-codex-team/scripts/doctor.sh \
  --team github \
  --cwd "$PWD"
```

此时，binary、on-disk profile、前台 profile 绑定、runtime、name 和 state 检查应该都有足够 live data 可供评估。如果平台无法公开前台 process arguments，诊断会 fail closed，而不是把 renamed stale session 当作有效角色。

### 4. 建立通信证据

接口为：

```text
test.sh [--team PREFIX] [--against-team PREFIX] static|ping|communication|full|policy|isolation
```

```bash
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github ping
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github communication
```

请在传给 `start.sh` 的同一 Git project 中调用这些命令。测试期间观察 live pane。即使 Planner 声称 Coder 已回复，只要 Herdr Coder pane 从未收到输入或 lifecycle state 未发生变化，就不足以作为证据。

对于 `full` 和 `policy` 测试，当前目录也是各自 nested disposable fixture 的默认 host：

```bash
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github full
/absolute/path/to/herdr-codex-team/scripts/test.sh --team github policy
```

如果 shell 必须位于别处，设置 `HERDR_TEST_PROJECT_DIR=/absolute/path/to/the-project-used-by-start.sh`。脚本在创建 nested fixture 前，会验证整个 host Git worktree 有 committed `HEAD` 且 clean；请使用 disposable worktree，不要仅为满足测试而隐藏或 stash 变更。

当两个带前缀 Team 都处于 live 且 settled 状态时，从两个方向测试跨 Team 隔离：

```bash
/absolute/path/to/herdr-codex-team/scripts/test.sh \
  --team github --against-team auth isolation
/absolute/path/to/herdr-codex-team/scripts/test.sh \
  --team auth --against-team github isolation
```

`--against-team` 只在 `isolation` 中必需。若两个真实 Team 不可用，应把此检查报告为 `NOT RUN`；静态名称解析不是 live 路由证据。本次更新所在环境没有运行 live isolation。单次命令只验证一个方向；要验证反方向，必须交换 `--team` 和 `--against-team` 后再次运行。

## 更新 Profile

仅修改模型时，优先使用文档中的 `PLANNER_MODEL`、`CODER_MODEL` 或 `REVIEWER_MODEL` 覆盖。若直接编辑已安装文件，只支持顶层 `model = ...` 赋值；它不纳入受管 policy digest。

修改 reasoning、sandbox、approval 或角色指令时，必须编辑 `profiles/` 或 `prompts/` 下的对应 source，运行 `test.sh static`，再运行 `install.sh`。`doctor.sh` 和 `start.sh` 会拒绝这些受管字段在已安装文件中的直接漂移。两类持久变更后都只退出并重启受影响的 Codex session：

```bash
codex --profile planner
```

已经运行的 session 不会自动重新加载 profile 变化。重新运行 `install.sh` 会在备份后替换三个已安装角色文件。

## 静态验证与卸载

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static
```

Static 模式检查必需文件、shell 语法、角色 guardrail、安装渲染和备份行为、可恢复卸载行为，以及当前 Codex 是否能在不访问 live agent 的情况下加载每个渲染 profile。在 Codex CLI 0.147.0 上，load smoke test 使用 `codex --profile <role> debug prompt-input`；它是 configuration-load check，不是 live agent/model 测试，也不严格保证所有 unknown field 都会被拒绝。

卸载 profile：

```bash
./scripts/uninstall.sh
```

卸载范围刻意保持最小：本项目安装的角色 profile 会被移到新的时间戳备份中。它不会卸载 Codex 或 Herdr、删除 credential、删除基础 Codex 配置、移除无关 hook 或删除备份目录。

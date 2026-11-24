# 故障排查

[English](../troubleshooting.md)

## 先保留证据

在明确目标 Team 与 scope 前，不要重启、修复、重命名或停止任何对象。先保存：

```bash
/path/to/herdr-agent-team/scripts/doctor.sh --team dex-vut
herdr agent list
herdr agent get dex-vut-planner
herdr agent read dex-vut-planner --source recent-unwrapped --lines 120
```

若保存的 launch record 缺失或 stale，请用启动时的精确 root 和原顺序绕过其
workspace/pane ID：

```bash
/path/to/herdr-agent-team/scripts/doctor.sh \
  --team dex-vut \
  --cwd /absolute/path/to/Dex_Teleop \
  --add-dir /absolute/path/to/vut_hub-0.2.0
```

这只是诊断 override。不要编辑 `current.json` 隐藏 mismatch。

## 界面未打开或 nested Herdr 被禁用

手工 attach 命令必须在 fresh、普通本机 shell 中运行，不能在已有 Herdr pane 内：

```bash
# 具名本机 session
herdr session attach dex-vut

# 具名远端 session
herdr --remote user@server --session dex-vut
```

Nested attach 已禁用。若只想离开界面，按 `Ctrl+B`，松开后按小写 `q`。这只
detach client；pane 与 Agent 会继续运行。

## `TEAM_UNSAFE` 报告受管文件缺失或漂移

Helper 有意没有覆盖任何内容。先检查 `${CODEX_HOME:-$HOME/.codex}` 下所报 path。
确认所选 Herdr session 中完全没有 live Agent 后，在原命令加入
`--repair-profiles`：

```bash
/path/to/herdr-agent-team/scripts/open.sh \
  --repair-profiles \
  --team dex-vut \
  --cwd /absolute/path/to/Dex_Teleop \
  --add-dir /absolute/path/to/vut_hub-0.2.0
```

远程模式在同一条 `remote.sh` 命令加入 `--repair-profiles`。Installer 会备份被
替换的受管 path。不要绕过 live Agent 做 repair。

## `INTEGRATION_REQUIRED` 或 hook 变化

Herdr Codex integration 可能改变 executable hook、`hooks.json` 与 Codex config。
先审查所报变更。在所选 session 没有 live Agent 时，为原 `open.sh` 或
`remote.sh` 命令加入 `--install-integration`。不要把新 hook 当作普通 profile
repair。

## `agent_name_taken`、`TEAM_PARTIAL` 或 `START_PARTIAL`

这些都是 fail-closed 结果。Helper 不会替换现有名称，也不会自动清理 partial
workspace。

```bash
herdr agent list
herdr agent get <exact_live_name>
herdr agent read <exact_live_name> --source recent-unwrapped --lines 120
```

保留打印的 workspace 与 pane ID，只处理已核实的目标 Team。不要重命名另一个
Team 的 Agent、根据 pane 位置猜身份或执行广泛的 server stop。

## SSH 报告 `port 22: Operation not permitted`

正在运行的 Codex process 没有使用当前受管 command-network policy 启动。Live
process 不会热加载 launch argument。

1. 保留 task context 和项目变更；
2. 按下文精确 stop 命令，只完全停止旧 Team 的 scope；
3. 用原 root 重新运行当前 `open.sh` 或 `remote.sh`；
4. Doctor 通过后再重试 SSH。

不要加入旧 `--sandbox`、`sandbox_workspace_write` 或 `danger-full-access`
override。当前 startup 保持 Planner/Reviewer 本地只读、Coder workspace-write，
并为三个角色启用 command network。Doctor 会验证模型实际可见的 filesystem
sandbox 与 network 状态。

Doctor 通过不证明远端可达或安全。Command network 是广泛权限，本地只读不限制
SSH 远端副作用，`approval_policy = "never"` 也没有日常确认步骤。请使用专用
低权限远端账号、固定 `known_hosts`、`BatchMode=yes`，并禁用 agent、port 与
X11 forwarding。

## Planner 的 Herdr 通信报告 `Operation not permitted`

这与 TCP/SSH 拒绝不同。部分 Linux sandbox 会拒绝直接访问 Herdr AF_UNIX。
Planner 必须使用受管 `herdr_codex_team` stdio bridge 及其有界
`inspect_team`/`prompt_agent` 工具。

运行 Doctor 检查已安装 Planner profile 与 bridge digest。不要让 Planner 可写，
也不要暴露任意 shell/Herdr MCP server。

## `start.sh` 无法连接 Herdr server

具名本机 session 请从 fresh shell 打开或 attach：

```bash
herdr --session dex-vut
```

具名远端 session：

```bash
herdr --remote user@server --session dex-vut
```

不要在 Herdr pane 内执行 attach。远程失败时，检查普通 SSH 和 launcher 使用的
远端 PATH：

```bash
ssh user@server 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"; command -v herdr; herdr --version'
```

修复 setup 后重跑同一条 `remote.sh`。不要用 SSHFS 或复制第二份 repository
checkout 作为恢复路径。

## Doctor 拒绝 launch record 或额外 root

使用 startup 的精确 `--team`、主 `--cwd` 和有序 `--add-dir` 列表。Planner 与
Coder 必须携带该精确有序额外 root 列表；Reviewer 不能携带 `--add-dir`。缺失、
多余、重排、malformed、重叠或 stale root 都会失败。

两个并发 Team 若需要同一 Git repository，必须使用独立 worktree。同一物理
worktree 中切换 branch 不构成隔离。Non-Git root 的 attribution 证据较弱，必须
明确报告。

## Profile 或 policy 变更没有生效

正在运行的 Codex session 不会重新加载受管文件或 launch argument。保留工作后：

```bash
cd /path/to/herdr-agent-team
./scripts/test.sh static && ./scripts/install.sh
```

然后只停止目标 Team，并用相同 `--team`、`--cwd` 和有序 `--add-dir` 重建。
普通 `codex --profile ...` 后再 Herdr rename，不是受管重启。

## Agent 是 `blocked`、`unknown` 或意外 idle

发送输入前先检查：

```bash
herdr agent get <exact_live_name>
herdr agent read <exact_live_name> --source recent-unwrapped --lines 120
```

- `blocked` 表示检测到 approval 或 question UI；不要替用户回答；
- `unknown` 表示分类不确定，不代表完成；
- prompt 后的 `idle`/`done` 只有在 lifecycle 已变化，且预期输出或 repository
  证据存在时才有意义。

## Reviewer 无法创建临时文件

Reviewer 有意保持 `read-only`。受管 profile 会禁用常见 pytest cache 和 bytecode
写入，但需要 `tmp_path`、compiler output、coverage data 或 application scratch
file 的测试仍可能无法在该边界内运行。请报告限制，不要给 Reviewer 写权限。

## Ping 或 live test 失败

只在前置条件具备时逐步增强检查：

```bash
./scripts/test.sh --team dex-vut ping
./scripts/test.sh --team dex-vut communication
./scripts/test.sh --team dex-vut full
./scripts/test.sh --team dex-vut policy
```

`ping` 检查直接可达；`communication` 要求相关目标已 settled，并证明经过 Planner
的往返。`full` 与 `policy` 需要其文档规定的 Git-clean fixture 条件；不要为了
绿色结果而对 dirty 或 hardware-facing worktree 运行。Isolation test 需要两个
真实且互不重叠的 Team。前置条件缺失时报告 `NOT RUN`。

## 停止精确 scope

先区分 detach、一个 workspace、一个 named session，以及当前 server/session
namespace。

```bash
# 窄范围：关闭共享 session 中一个已核实 Team workspace。
herdr --session dex-vut workspace list
herdr --session dex-vut workspace close w9

# 在拥有该 session 的主机上停止并删除一个 named session。
herdr session stop dex-vut
herdr session delete dex-vut

# default session 可显式具名。
herdr session stop default
```

远端 named Team 的完整清理：

```bash
ssh -T user@server 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"; herdr session stop dex-vut && herdr session delete dex-vut'
```

`herdr server stop` 会停止当前选定 server/session namespace 内的全部 pane。它不
会停止其他全部 named session，但对单个 Team workspace 仍然过宽。示例 `w9`
只能替换为已核实的 workspace ID；绝不能用广泛的 server stop 仅仅 detach。

## Doctor 在新版本上报告命令缺失

较新的 version number 不证明兼容。读取当前 binary 对应的 `--help`，保留精确
failure，只有确认 command contract 变化后才更新 helper。安全结果应是 startup
失败，而不是猜测 fallback。

# 配置

## 每个角色的 CLI

`--planner-cli`、`--coder-cli`、`--reviewer-cli` 分别选择 `codex`、`claude` 或 `agy`。也可以设置 `PLANNER_CLI`、`CODER_CLI`、`REVIEWER_CLI`。默认值都是 `codex`。本地通过相应的 `*_MODEL` 设置指定该 CLI 支持的模型。

三种 CLI 都加载对应的角色指令。只有 Codex 强制加载 Stop That Shit。使用 Codex 时，Reviewer 用 review 模式，Coder 在实现任务中用 change 模式，Planner 按用户请求选择模式。Claude 和 Antigravity 的只读角色通过文件工具检查本地项目。三种 CLI 都通过团队 SSH 工具检查远端。Claude Coder 开启原生 shell 沙箱，Antigravity Coder 使用终端沙箱和工作区编辑模式。Antigravity 的命名角色定义保存在 `~/.gemini/config/agents/`。首次选用 Antigravity 时，启动器还会把 `herdr_codex_team` 和 `herdr_team_ssh` 登记到它的 MCP 配置。两项只向对应的 Herdr 角色提供工具，启动时会检查连接。卸载器移除指向本次安装的登记。


[English](../configuration.md)


## 本地团队共用 SSH

在 Planner 里告诉它 SSH 主机和远端目录，例如“用 SSH 到 `lab-dev` 的 `/srv/project` 检查这个问题”。Planner 调用 `select_remote`，用本机 OpenSSH 验证主机并取得实际目录。之后派单会带上该目的地，Coder 和 Reviewer 从自己的窗格访问同一份远端文件。

| 角色 | 远端能力 |
| --- | --- |
| Planner | 选择或清除目的地，查看目录、文件、状态及差异 |
| Coder | 读取远端证据，在选定目录执行获准的编辑、构建和测试命令 |
| Reviewer | 列目录、读文件、搜索文本、检查 Git 状态和暂存或未暂存的差异 |

目的地属于当前三会话组合。切回旧 Planner 后会恢复该组合的主机和目录。要回到本地任务，告诉 Planner 切回本地，它会调用 `use_local`。临时在 shell 中运行的 `ssh` 命令不会登记团队目的地。

使用已验证主机密钥、可非交互登录的 SSH 别名。OpenSSH 读取本机配置和密钥，可使用已有的 SSH agent。如需独立配置文件，在启动时设置 `HERDR_SSH_CONFIG=/absolute/path/to/config`。这里的三个 CLI 都在本地运行；`remote.sh` 用于在远端启动整个团队。


## Profile 位置和优先级

仓库在 `profiles/` 下包含可复用的角色模板。安装器会把生成的角色文件放在基础 Codex 配置旁：

```text
$CODEX_HOME/config.toml
$CODEX_HOME/planner.config.toml
$CODEX_HOME/coder.config.toml
$CODEX_HOME/reviewer.config.toml
```

未设置 `CODEX_HOME` 时，默认使用 `~/.codex`。

当前 Codex CLI 使用以下命令启动时，会把 `$CODEX_HOME/<name>.config.toml` 叠加到基础用户配置之上：

```bash
codex --profile <name>
```

这是独立文件 profile 行为，而不是本项目向用户基础文件追加 `[profiles.<name>]` table。角色文件彼此分开，使安装、备份、检查和移除都能保持最小范围。参见[官方 Codex 配置参考](https://developers.openai.com/codex/config-reference/)。

Profile 不编码 Team 前缀。实时 Agent `github-coder` 仍以 `--profile coder` 启动；`auth-coder` 独立复用同一个 profile。Herdr 实时名称携带 runtime Team 身份，Codex profile 名称携带可复用角色配置。因此无论 Team 数量是多少，`install.sh` 始终只管理这三个角色文件。

## 用户本地启动状态

受管 startup 会在同一个 `CODEX_HOME` namespace 下保存每个 Team 最近的启动记录：

```text
$CODEX_HOME/herdr-codex-team/state/v1/teams/{legacy|prefixed-<team-prefix>}/current.json
```

State 目录使用 `0700`，JSON 文件使用 `0600`。其中包含主/额外项目绝对路径和 Herdr workspace/pane ID，因此必须把它视为私有本地 metadata；不要在未脱敏时复制进本仓库或公开报告。它不包含 prompt、conversation、源码、diff、credential 或 task/review result。

因此 `CODEX_HOME` 同时选择 role-profile namespace 和启动记录/startup-lock namespace。`start.sh` 与不带 root 的 `doctor.sh --team <prefix>` 必须使用相同 `CODEX_HOME`；否则 Doctor 会正确地找不到匹配的保存预期值。显式提供 `--cwd` 和有序 `--add-dir` 会绕过启动记录的 workspace/pane binding，仍是直接诊断形式。

这份状态不会改变 model、sandbox、role prompt 或 Herdr lifecycle 配置。详见[启动状态](launch-state.md)。

## 角色默认值

| 设置 | Planner | Coder | Reviewer |
| --- | --- | --- | --- |
| 实际本地 filesystem policy | `read-only` | `workspace-write` | `read-only` |
| `approval_policy` | `never` | `never` | `never` |
| 受管 `default_permissions` | `herdr_read_only_network` | `herdr_workspace_network` | `herdr_read_only_network` |
| permission parent | `:read-only` | `:workspace` | `:read-only` |
| command network | 启用 | 启用 | 启用 |
| 模型默认值 | 继承运行主机的 Codex 默认模型 | `gpt-6.2-sol` | 继承运行主机的 Codex 默认模型 |
| reasoning 默认值 | `xhigh` | `xhigh` | `xhigh` |
| 应用源码编辑 | sandbox 和 prompt 均阻止 | 允许且预期 | sandbox 和 prompt 均阻止 |

Coder 模板还提供以下默认建议：

```toml
model = "gpt-6.2-sol"
model_reasoning_effort = "xhigh"
```

工作流不会根据这个模型名称选择不同分支。用户可以使用当前 Codex account 和 CLI 支持的任何模型覆盖它。

Planner 必需的 `herdr_codex_team` stdio MCP server 只暴露 `inspect_team` 与 `prompt_agent`。这是 Linux shell sandbox 拒绝 Herdr Unix socket 时的受支持解决方案；不要改用 `danger-full-access` 或暴露任意 shell/Herdr 命令的 MCP server。也不要为了绕过验证失败而把 Planner 或 Reviewer 改为可写 sandbox。

## 模型

工作流不要求固定模型标识符。仓库给 Coder 提供默认值，但路由、角色检查和测试都不依赖该值。请使用下文的环境变量覆盖选择当前 Codex account 和已安装 CLI 支持的模型，或者只编辑已安装角色文件中的这一顶层赋值：

```toml
model = "<available-model>"
```

`model_reasoning_effort` 属于受管策略，不是可直接修改的本地覆盖。如需更改，请编辑 `profiles/` 下的对应仓库模板，运行静态检查后重新安装。Sandbox、approval、角色指令、Planner bridge 和未来受管策略字段同样必须按 source 修改并重新安装。

建议的选择标准：

- Planner 需要可靠的长程推理、需求分析和架构判断。
- Coder 适合使用 coding-focused model，并在速度和质量之间取合适平衡。
- Reviewer 需要独立推理和足够上下文来检查周边代码，而非只读 patch summary。

模型可用性和支持的 reasoning 值会随时间变化。请查询最新官方 Codex 文档和自己的 account，不要从旧 README 复制 identifier。如果某模型拒绝 `xhigh`，请把对应仓库 profile 更新为它支持的最强值并运行 `install.sh`。保留项目变更，通过当前 `start.sh` 使用原 root 参数只重建受影响 Team，再使用相同参数运行 `doctor.sh` 和 communication 测试。

项目还支持三个范围明确的环境变量覆盖：

```bash
PLANNER_MODEL="<available-model>" \
CODER_MODEL="<available-model>" \
REVIEWER_MODEL="<available-model>" \
./scripts/install.sh
```

安装时，每个已设置变量都会渲染进对应的已安装 profile；现有目标仍会先备份。也可以把相同变量传给 `start.sh`，为单次运行添加 `--model` 覆盖而不重写已安装文件。未设置变量时，保留相应角色 profile 或基础配置中的模型选择。当模型选择影响安全或成本时，请同时检查环境和最终已安装文件。

## Developer instructions 和可读 Prompt

规范角色文本保存在 `prompts/`，维护者无需解码长 TOML string 即可审查。安装路径通过简单 shell 过程把角色专属配置和这些指令组合起来，不需要外部 template engine。

角色选用 Codex 时，安装器会将 Stop That Shit 0.2.5 写入其开发者指令，每次任务都会加载。在远端主机启动 Codex 时也一样。Claude Code 和 Antigravity 加载各自的角色指令。即使本机已经安装该 Claude 插件，受管 Claude 会话也会禁用这个技能。Antigravity 会随对话保存角色指令。如果早期测试会话保存了强制使用技能的旧指令，Herdr 会停止派单。在 Gemini 的 `/agents` 中选用当前角色可以保留历史并生成新会话，再用新的 Planner ID 和 `--link-current` 登记新组。用当前提示词创建的对话组可以按原 ID 恢复。用户照常输入任务即可。技能在各角色原有权限内指导模型，可选的 Guard 钩子有独立的启用流程。[技能正文](../../prompts/stop-that-shit/SKILL.md)

修改角色时：

1. 编辑仓库中的可读 prompt；
2. 检查对应 profile 模板；
3. 运行仓库静态检查；
4. 运行 `install.sh` 并记录备份目录；
5. 通过当前 `start.sh` 使用原 root 参数重建受影响 Team；
6. 运行 `test.sh static`，然后至少针对目标 live Herdr session 运行 Team-aware `ping` 和 `communication` 模式。

不要只修改正在运行的 session 中的 chat instruction，就假设已安装 Team 也已改变。新 session 必须能从已安装 profile 重建完整角色。

## 重新加载行为

Codex 在 session 启动时读取所选 profile，不会自动把文件变化重新加载到现有 session。例如修改仓库 `profiles/planner.config.toml` 并运行 `install.sh` 后：

1. 保留任务 context、startup root 参数和全部项目变更；
2. 只退出请求 Team 的三个旧 session，或只关闭它自己的 Herdr workspace；
3. 通过当前 `start.sh` 重建该 Team，并复用原来的 `--team`、`--cwd` 和有序 `--add-dir` 参数；
4. 使用同一组 root 参数运行 `doctor.sh`，确认三个精确实时名称；
5. 从可用 Git diff 或所报 non-Git touched path 恢复任务，保留每项证据限制，并使用自包含 handoff。

不要只运行普通 `codex --profile <role>` 重启。它会缺少受管 permission
profile、显式 network grant、角色专属额外 root，以及 `doctor.sh` 要求的受管
launch 证据。重启 Team 可能清除 Herdr 实时名称，因为名称属于 pane occupant。
不要停止或重命名无关 Team。

绝不能通过分配另一个 Team 的名称来修复重启。Profile 匹配不代表 Team membership。

## 审批和 sandbox 设置

`approval_policy = "never"` 表示 Codex 在普通审批点不会暂停。它不会授予 sandbox 禁止的文件系统访问权限。反过来，即使 prompt 要求不要使用，`workspace-write` 仍然提供实质性的写入能力。

受管 startup 会在命令行组合 Codex 的 beta permission profile。Planner 和
Reviewer 选择继承 `:read-only` 的 `herdr_read_only_network`；Coder 选择继承
`:workspace` 的 `herdr_workspace_network`。每次 launch 都重复精确的
`default_permissions`、`extends` 和 `network.enabled=true` 设置。它不会传入旧的
`--sandbox` 或 `sandbox_workspace_write.writable_roots` override，因为在受支持的
Codex 版本中，这些参数可能与实际 network policy 冲突或抑制它。Planner 与
Coder 都获得主 cwd 和每个可重复 `--add-dir`；Planner 保持本地只读，Coder
可写，Reviewer 保持本地只读且只使用主 root。

三个角色都启用 command network，因此标准 SSH 可以直接连接。这是广泛的出站
网络权限，不是仅限 SSH 或特定 host 的规则。本地 `read-only` 不会约束通过 SSH
在远端执行的操作，`approval_policy = "never"` 也不提供交互检查点。因此
`start.sh` 与 `doctor.sh` 会同时检查精确受管 argv，以及模型实际可见的
filesystem sandbox 和 network 状态；CLI 行为不兼容或出现冲突的旧参数时会
fail closed。

每个受管角色 profile 还会设置 `agents.enabled = false`，startup 再用
`-c 'agents.enabled=false'` 重复覆盖。该 CLI 覆盖可防止基础配置重新启用 Codex
原生协作工具，精确 argv 验收会让缺少此项的旧 live process fail closed。
Planner 必需的 Herdr bridge 是独立的有界 MCP 工具面，因此仍可使用。修改或
重装 profile 后必须重建受影响 Team；运行中的 Codex session 不会热加载。

Reviewer profile 还会设置 `PYTHONDONTWRITEBYTECODE=1` 和
`PYTEST_ADDOPTS="--capture=sys -p no:cacheprovider"`。这样，普通 `pytest`
收集和输出捕获不再创建默认捕获文件、`.pytest_cache` 或 `.pyc` 文件。
它不会创建可写临时目录：需要 `tmp_path`、`capfd`、coverage 数据、编译器
输出或应用 scratch file 的测试与 plugin，仍必须明确报告为无法在独立只读
审查边界内运行。

必须从概念上区分这三种机制：

```text
approval policy  Codex 何时在操作前询问
sandbox mode     操作可以访问什么
command network  shell command 是否可以建立出站连接
agent topology   Codex 原生协作工具是否存在
role prompt      Agent 被要求采取什么行为
```

不要把 `danger-full-access` 当作兼容性变通方案。应诊断缺失 path、Herdr integration、hook trust 或 command surface。

## 本地变更和更新

已安装文件属于用户本地状态，不应 commit。仓库 profile 不得包含 credential 或私有机器 path。

从新仓库版本更新前，检查当前使用的本地角色设置和受管策略：

```bash
grep -E '^(model|model_reasoning_effort|sandbox_mode|approval_policy|agents[.]enabled)[[:space:]]*=' \
  "$HOME/.codex/planner.config.toml"
```

需要时对 Coder 和 Reviewer 重复操作。直接与 `profiles/*.config.toml` 比较时出现大量差异是预期现象，因为已安装文件还包含 ownership header 和渲染后的 Markdown prompt。运行 `install.sh`；它会在写入新文件前备份完整已安装版本。比较输出的备份和新文件。只能直接恢复顶层 `model = ...` 赋值；有意的受管策略变更必须转移到仓库 source 并重新安装。绝不得把 credential、provider endpoint 或私有机器 path 复制到仓库模板。然后重新运行测试。

## 替代 Codex home

高级用户可以设置 `CODEX_HOME`，让安装和启动使用独立的 Codex home；install、doctor、start 和 Codex 本身必须一致使用该变量。该目录可能包含 credential、trusted-hook state 和私有配置，应视为敏感内容。

不要只在安装时设置 `CODEX_HOME`，启动 Agent 时却省略；否则 Codex 会读取另一组 profile。

## Team 和工作目录输入

Team 身份是 runtime input，不是已安装配置：

```bash
./scripts/start.sh --team github \
  --cwd /path/to/primary-project \
  --add-dir /path/to/second-project
./scripts/doctor.sh --team github \
  --cwd /path/to/primary-project \
  --add-dir /path/to/second-project
./scripts/test.sh --team github communication
```

`TEAM_PREFIX=github` 是 `--team` 的环境变量替代方式。如果两者同时提供，则必须一致。两者均省略时选择 legacy 名称 `planner`、`coder` 和 `reviewer`。

Prefix 必须能为三个角色生成合法且唯一的 Herdr 名称。Startup 会在 workspace 创建前检查精确生成名，并在冲突时停止；它不会重命名、替换或删除现有 live agent。

`--cwd` 选择 Herdr workspace/pane 的主目录。`--add-dir` 可重复，为 Planner 提供额外只读 workspace context，为 Coder 提供额外可写 context；Reviewer 不接收该参数。只要提供了 `--add-dir`，诊断就同时要求 `--cwd`，并验证角色专属 argv：Planner 与 Coder 必须携带精确的有序列表，Reviewer 必须不携带 `--add-dir`。所有请求目录都必须已存在、不是文件系统 root，并在物理路径与 Git-worktree 解析后互不重叠。

位于 Git worktree 中是证据能力，不是启动条件：single-root 与 multi-root startup 都允许现有 non-Git 目录；Git CLI 仍用于保守识别 worktree scope。Non-Git root 的 baseline、完整 diff、untracked-file scope、rollback point 与预存变更归属均为 `NOT AVAILABLE`。不同 Team 要使用互不重叠的完整 root set；两个 Team 在同一仓库中并发工作时要使用不同 Git worktree。参见[多 Team 隔离](multi-team.md)。

## Runtime timeout 和测试保留

脚本接受以下可选环境设置：

| 变量 | 默认值 | 用途 |
| --- | ---: | --- |
| `HERDR_START_TIMEOUT_MS` | `120000` | 每次 `herdr agent start` 的 readiness timeout |
| `HERDR_TEST_TIMEOUT_MS` | `120000` | direct ping、Planner-routing 和单个 policy phase 的 prompt wait |
| `HERDR_FULL_TEST_TIMEOUT_MS` | `1200000` | 完整 Planner/Coder/Reviewer loop wait |
| `HERDR_TEST_READ_LINES` | `2000` | 为本次运行特定 response evidence 检查的 terminal 行数 |
| `HERDR_TEST_PROJECT_DIR` | 当前目录 | live Team 使用的 Git project，也是 nested `full`/`policy` fixture 的 host |
| `KEEP_TEST_WORKSPACE` | `0` | 设为 `1` 以保留成功的 disposable full-test repository |

Timeout 是以毫秒为单位的正整数。在检查过的 Herdr 0.8.2 command surface 上，单次 `agent start` timeout 必须大于 3000 ms 且不超过 300000 ms，因此 `HERDR_START_TIMEOUT_MS` 要保持在该范围。`full` 或 `policy` 测试失败时会自动保留当前 fixture，以供诊断。

启动较慢时示例：

```bash
HERDR_START_TIMEOUT_MS=180000 ./scripts/start.sh /path/to/project
```

只有日志显示真实的缓慢 readiness 或工作时才应增加 timeout。Timeout 无法修复 missing agent、duplicate name、blocked UI、unavailable server 或 native-subagent fallback。

运行 `full` 或 `policy` 测试时，应位于传给 `start.sh` 的同一 project；也可以显式提供 host：

```bash
HERDR_TEST_PROJECT_DIR=/path/to/project \
  /path/to/herdr-codex-team/scripts/test.sh --team github full
```

Host 必须位于 Git-clean worktree 中且有已提交的 `HEAD`。这一布局使 nested fixture 保持在 live Coder 的 `workspace-write` root 内，同时 baseline check 会拒绝 Git-visible 外部变更、commit 和 branch switch。Git status 不会审计 ignored file，因此应使用不含敏感 ignored content 的 disposable worktree；选择无关、unborn 或 dirty 目录会安全失败。主 cwd 为 non-Git 的 Team 必须把 `full` 和 `policy` 记为 `NOT RUN`；Git-backed 主 root 下的 fixture 结果不覆盖任何 non-Git 额外 root。

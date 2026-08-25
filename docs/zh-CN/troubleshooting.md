# 故障排查

[English](../troubleshooting.md)

## 从证据开始

使用 startup 时的同一组 root 运行诊断：

```bash
./scripts/doctor.sh --team <prefix> \
  --cwd /path/to/primary-project \
  --add-dir /path/to/second-project
```

对于 legacy `planner`/`coder`/`reviewer` Team，省略 `--team`。只有不需要诊断验证 Team 工作目录时，才省略 `--cwd`。每个诊断 `--add-dir` 都要求 `--cwd`；必须重复 `start.sh` 使用的精确有序列表。

在 Herdr 管理的 pane 内，还要检查：

```bash
herdr status --json
herdr agent list
```

不要仅凭三个 terminal pane 推断 Team 健康。记录实际存在的 binary、profile file、live name、pane 和 lifecycle state。

## `agent_name_taken`

`agent name planner is already used` 等消息或 `agent_name_taken` error 表示另一个 live agent 已经占用 startup 请求的精确名称。Herdr 实时名称必须唯一。

不要强制 startup、重命名现有 Agent，或继续启动另外两个角色，否则会留下有歧义或不完整 Team。请改用唯一且合法的 Team 前缀：

```bash
./scripts/start.sh --team github --cwd /path/to/project
```

这会请求 `github-planner`、`github-coder` 和 `github-reviewer`。如果其中某个名称也已存在，请选择其他前缀，或先有意结束现有 Team 再重试。Startup 绝不能删除、覆盖或接管它。

## Planner 把工作发给错误的 Coder

常见原因包括旧 Planner prompt 仍 hard-code `coder`、无法识别自身名称，或 Team 前缀推导错误。

检查 Planner 必须建立的四个路由值：

```text
SELF_AGENT
TEAM_PREFIX
CODER_AGENT
REVIEWER_AGENT
```

对于 `SELF_AGENT=github-planner`，唯一有效路由是 `CODER_AGENT=github-coder`、`REVIEWER_AGENT=github-reviewer`。使用当前 Herdr 检查命令验证精确实时名称：

```bash
herdr agent list
herdr agent get github-planner
herdr agent get github-coder
herdr agent get github-reviewer
```

不要从 pane position、tab、workspace、process kind 或 hard-coded pane ID 推断 Team membership。如果推导或精确目标验证失败，正确响应是 `HERDR_COMMUNICATION_FAILED`，即使另一个 Team 的 Coder 处于 idle 且可用。

重新安装当前角色 prompt，通过当前 `start.sh` 只重建请求的 Team，再使用 startup 的精确有序 root 运行 `doctor.sh --team github --cwd <primary> --add-dir <extra> ...`，然后运行 Team-aware communication test。不要在未独立检查和协调全部可用 Git diff 与所报 non-Git touched path 的情况下，接受或 merge 错误 Team 生成的工作。

## 两个 Coder 修改了同一个工作树或 root

这是 filesystem/Git workspace-scope collision，不是 Herdr routing failure。精确名称路由和 prompt contract 可降低误发跨 Team 消息的风险，但不是 ACL；只要任一 Team 的主 root 或额外 root 与另一 Team 的 scope 重叠，它就不能阻止 `auth-coder` 和 `ui-coder` 写入同一文件。

停止发出新工作，并保留两个 Agent 的 report、全部可用 Git diff 和所报 non-Git touched-path inventory。对于不同仓库，使用互不重叠的完整 root set 重启 Team。对于同一仓库中的并发任务，为每个 Team 准备独立 branch 和 Git worktree：

```bash
cd /projects/myapp
git worktree add ../myapp-auth -b task/auth
git worktree add ../myapp-ui -b task/ui
```

然后把每个 Team 绑定到自己的 path。本项目不会自动 merge、remove 或 repair worktree。详见[多 Team 隔离](multi-team.md)。

## Planner 声称 Coder 正在工作，但 Coder pane 处于 idle

这是最高优先级故障，因为它可能造成虚假进展。

可能原因：Planner 无法使用 Herdr，却悄悄创建或访问了 Codex-native/internal subagent；或者它推导了另一个 Team 的目标，而不是预期 live Herdr Coder。

检查：

```bash
herdr agent list
herdr agent get <expected-team-coder>
herdr agent read <expected-team-coder> --source recent-unwrapped --lines 120
```

然后检查 Planner profile，确认其中包含 mandatory Herdr identity/routing 和 strict Team-isolation 规则，并明确禁止 cross-team routing、native subagent、hidden worker、`/root/coder`、`/root/reviewer` 和 fallback agent system。

路由失败时的预期响应：

```text
HERDR_COMMUNICATION_FAILED
```

除非具名 live pane 确实收到 prompt，且生成的 repository state 与 report 匹配，否则不要接受生成的 Coder report。

## Planner 报告 `Operation not permitted`

Planner 可能使用无法访问本地 Herdr communication mechanism 的 `read-only` sandbox。

检查已安装文件：

```text
~/.codex/planner.config.toml
```

仓库 `profiles/planner.config.toml` 中的默认值为：

```toml
sandbox_mode = "workspace-write"
```

同时保留禁止 Planner 编辑应用源码的 developer instruction。恢复或有意更新仓库模板，运行 `scripts/install.sh`，重启 Planner，再运行 `test.sh --team <prefix> communication`（legacy 使用不带前缀形式）。直接修改已安装文件中的这一受管字段会被 profile-policy digest 拒绝。

如果错误仍然存在，不要扩大到 `danger-full-access`。请检查精确被拒 path、确认 Herdr integration 和 hook 是 current，并运行 `herdr agent explain <expected-team-agent>` 或当前 Herdr 版本打印出的诊断命令。

如果任务需要第二个项目，请通过带显式 `--add-dir` 的 `start.sh` 重启 Team；不要使用私有的全局可写 root 作为变通。受管 startup 会清空继承的 `sandbox_workspace_write.writable_roots`，应用显式角色 sandbox，把额外可写 root 列表传给 Planner/Coder，并有意不传给只读 Reviewer。

## 所有 Agent 都显示为 `codex`

Agent kind 和实时名称不同。`codex` 可能正确描述 executable，但所需唯一名称仍然缺失。

运行：

```bash
herdr agent list
```

在 Herdr 0.8.2 上，可用以下命令重命名你拥有且已明确识别的 existing live target：

```bash
herdr agent rename <agent-name-or-pane-id> <team-prefix>-planner
herdr agent rename <agent-name-or-pane-id> <team-prefix>-coder
herdr agent rename <agent-name-or-pane-id> <team-prefix>-reviewer
```

请使用 Herdr 返回的实际 target，而不是 sidebar position 或 guessed ID。名称必须唯一。绝不能为解决冲突而重命名另一个 Team 的现有 Agent。只有有意选择 legacy 模式时才使用不带前缀的角色名称。

## Agent 名称在重启后消失

在已检查的 Herdr 0.8.2 行为中，实时名称跟随当前 pane occupant；Agent 退出、被 release 或被替换时会清除。Codex profile 不会永久分配 Herdr 名称。

保留 context 和项目变更后，通过当前 `start.sh` 使用原来的 `--team`、`--cwd` 和有序 `--add-dir` 参数，只重建请求的 Team。然后使用同一组参数运行 `doctor.sh` 再恢复任务。普通 profile launch 后再执行 `herdr agent rename` 不会复现受管 sandbox/root argv。这是预期 runtime lifecycle，并不说明 profile 已丢失。

## Profile 变更没有生效

当前 Codex profile 文件位于基础配置旁：

```text
~/.codex/planner.config.toml
~/.codex/coder.config.toml
~/.codex/reviewer.config.toml
```

它们通过 `codex --profile <name>` 选择。受管理文件分别包含已嵌入角色 prompt 与规范化 profile policy 的 digest。为保留文档约定的模型选择自由，`model = ...` 行被刻意排除；reasoning、sandbox、approval 和其他 policy/template 字段仍受管理。应修改 `prompts/` 或 `profiles/` 下的 source 并重新运行 `scripts/install.sh`；直接修改已安装策略会被 `doctor.sh` 与 `start.sh` 拒绝。现有 Codex session 不会自动重新加载新安装的 profile。保留 context 和项目变更，只关闭请求 Team 的旧 session，再通过当前 `start.sh` 使用原 root 参数重建该 Team，并用相同参数运行 `doctor.sh` 验证；不要把普通 profile launch 加 rename 当作受管重启。

还要检查安装和启动时是否设置了不同 `CODEX_HOME`。不匹配会使 Codex 读取另一个目录。

## `1 hook is new or changed`

Herdr Codex integration 可以添加或更新用于 Agent 状态报告的 hook。发生变化的 hook 是可执行配置，必须审查。

1. 运行 `herdr integration status`；
2. 找到 Codex 指出的 hook；
3. 确认它属于预期 Herdr 安装；
4. 检查 command、argument 和引用 script；
5. 仅在 source 和 behavior 可接受后信任。

不要仅为消除警告就使用 bypass flag。如果文件意外变化，请停止，并与已安装 integration 或官方 Herdr 指南比较。

## `start.sh` 无法连接 Herdr server

启动辅助脚本需要可连接的本地 Herdr server。进入目标仓库并启动或 attach Herdr：

```bash
cd /path/to/project
herdr
```

从该 session 中的 shell pane 运行 `start.sh`；也可以从外部 shell 运行，但要先确认 `herdr status server` 能访问预期 server。脚本会创建新 workspace，并定位 Herdr 返回的 ID；它不依赖 UI 当前聚焦 pane。

## Agent 状态是 `blocked` 或 `unknown`

`blocked` 表示 Herdr 识别出 approval 或 question UI。`unknown` 表示 Agent 存在，但 Herdr 无法可靠分类；它不证明工作已经结束。

行动前先检查：

```bash
herdr agent get <name>
herdr agent read <name> --source recent-unwrapped --lines 120
```

不要自动回答 approval 或用户问题。需要授权或重大选择时，把可见 prompt 交给用户。

## `agent start` 失败

Herdr 的 `agent start` 需要 existing pane，且该 pane 的 foreground process 正停留在 interactive shell prompt。它不会 split pane，也不会替换正在运行的 editor、server 或 Agent。

检查目标 pane：

```bash
herdr pane process-info --pane <pane-id>
herdr pane read <pane-id> --source recent-unwrapped --lines 80
```

创建或选择 clean shell pane，然后重试；Agent 原生参数放在 `--` 后：

```bash
herdr agent start <team-prefix>-coder --kind codex --pane <pane-id> -- --profile coder
```

## Ping 通过但 communication 失败

Direct ping 证明外部 shell 可以访问 Coder 和 Reviewer，不代表 Planner 有 Herdr access 或遵守 no-fallback 策略。

检查 Planner sandbox、已安装 prompt、实时名称和 pane state。运行：

```bash
/path/to/herdr-codex-team/scripts/test.sh --team <prefix> communication
```

同时观察两个下游 pane。如果 Planner 只是自己 echo 预期 sentinel，应视为测试失败。

## Full 测试无法运行

Full 测试需要 live 三 Agent Herdr Team、Git 和 Python 3，因为它会验证真实 working-tree change、运行 demo test 并检查 review loop。请只在 ping 和 communication 通过后运行：

```bash
/path/to/herdr-codex-team/scripts/test.sh --team <prefix> full
```

脚本会把 bundled fixture 复制到 `${HERDR_TEST_PROJECT_DIR:-$PWD}` 下的 `.herdr-codex-test.*`，在其中初始化 isolated Git repository，并在成功后删除。请在与 `start.sh` 所用相同 Git project 中使用 `test.sh` 的绝对路径调用，或显式将 `HERDR_TEST_PROJECT_DIR` 设为该 project。脚本会拒绝不在 Git worktree 内、没有 committed `HEAD` 或整个 worktree 不 clean 的 host。

如果 Team 的主 cwd 为 non-Git，就无法满足该前置条件：把 `full` 记为 `NOT RUN`。独立 fixture 不会为 Team 的 non-Git root 创建 baseline 或完整 diff。如果只有额外 root 为 non-Git，Git-backed 主 root 下 full-test 通过也不能说明该额外 root 的完整变更 scope。

Host 位置很重要：disposable path 必须留在 live Team 的 workspace-write root 内。失败后脚本会保留目录以供诊断；设 `KEEP_TEST_WORKSPACE=1` 可保留成功运行。请使用 clean disposable worktree。如果 harness 报告 dirty host，请自行检查并保留变更，不要要求测试忽略它。

Pass 能验证 challenge-derived Coder completion 和 Reviewer pass response、fixture history 未变、精确 changed-file scope、host Git-visible status/branch/`HEAD` 未变、脚本自身 assertion、fixture test 和 Planner 本次运行特定 approval。它不会检查 ignored host file，也无法证明 filesystem writer identity，因为 Planner 同样有 `workspace-write`。请使用不含敏感 ignored file 的 disposable host。如果 hard attribution 属于验收标准，当前测试不够充分。

Full 测试还会在 live Coder/Reviewer transcript 中验证普通交接关联。它为第 1–4 轮预先分配互不相同的 Coder/Reviewer `HANDOFF_ID`，始终保持同一 `TASK_ID`，允许连续的 `CHANGES_REQUIRED` 轮次最终以同轮 `PASS` 结束，并拒绝复用或未使用的后续轮 response token。每个已使用关联值都必须同时出现在收到的 prompt 与角色精确回显中。

测试默认读取最新 2000 行 unwrapped terminal。如果一次合法但输出很长的运行让最终本次运行特定 token 滚出窗口，请保留 fixture，并以更大的正 `HERDR_TEST_READ_LINES` 重试；扩大窗口不能替代观察具名 pane。

如果 audit session 无法安全访问目标 live Herdr server——本仓库组装时正是这种情况——只能声称完成静态 shell/configuration 检查。当 `herdr status server` 能解析预期 server 时，可从外部人工操作 shell 调用 live script；在这些脚本实际对具名 Agent 运行前，live communication 仍未验证。

在 Team 仓库 checkout 中运行非 live 检查：

```bash
cd /path/to/herdr-codex-team
./scripts/test.sh static
```

## Policy 测试无法运行

在 `ping`、`communication` 与 `full` 之后，从相同 clean disposable host worktree 运行：

```bash
./scripts/test.sh --team <prefix> policy
```

它依次对 Reviewer、Coder、Planner 注入对抗性角色越界请求，同时检查带基线校验的嵌套 Git fixture、peer transcript/lifecycle sequence 与可见 Herdr agent 名称不变。成功 cleanup 之前的 phase 失败会保留 fixture。通过只代表有边界的行为证据，不是 ACL、filesystem audit，也不能证明隐藏 native worker 从未存在。若无法安全访问预期 live Team，请把该模式记录为 `NOT RUN`。

这里同样要求 Git host。主 cwd 为 non-Git 的 Team 必须把 `policy` 记为 `NOT RUN`；不得把另一 Git-backed fixture 的 policy 结果外推到 non-Git 项目 root。

## Isolation 测试无法运行

Isolation 模式需要两个不同、均处于 live/settled 状态且绑定预期 generic profile 的带前缀 Team：

```bash
./scripts/test.sh --team github --against-team auth isolation
```

`--against-team` 只在该模式中必需，并且必须与 `--team` 不同。一次调用只验证从 `--team` 指定 Planner 出发的有方向路由，以及 peer Team 保留 transcript 和 lifecycle sequence 不变。要验证反方向，必须交换参数后再次运行：

```bash
./scripts/test.sh --team auth --against-team github isolation
```

如果当前 shell 无法安全访问两个真实 Team，请记录 live isolation 为 `NOT RUN` 并说明原因。通过静态名称构造、doctor 或单 Team communication test，不能证明一个 Planner 无法控制另一个 Team 的 Coder。本次更新所在环境没有运行 live isolation，不能把它报告为 `PASS`。
它也不是任一 Team root set 的文件系统隔离证据。

## `start.sh` 拒绝项目目录

启动接口是 `start.sh [--no-focus] [--team PREFIX] [--cwd PROJECT_DIR] [--add-dir DIR]... [PROJECT_DIR]`。`PROJECT_DIR` 默认为当前目录。不要把 `--cwd` 与 legacy 位置 path 一起使用。

Single-root 与 multi-root 模式都不要求目录位于 Git worktree；Git CLI 仍用于保守识别 scope。每个请求目录都必须存在、能安全解析、不是 `/`，且与其他目录互不重叠。相同、祖先/后代、symlink 等价或属于同一 effective worktree 的 root 都会被拒绝；malformed 或有歧义的 Git metadata 也会 fail closed，而不会被当成普通 non-Git 证据。

检查：

```bash
git -C /path/to/project rev-parse --show-toplevel
```

上面的命令只用于诊断证据能力，不是启动前置条件。Non-Git 项目直接接受打印的证据 warning 即可；如果本来就需要多个已存项目目录，用可重复 `--add-dir` 传入每个额外目录。不要仅为消除 warning 而初始化无关目录。

## Doctor 报告额外 root 不匹配

使用启动 Team 时的同一主路径和额外 root，并保持相同顺序：

```bash
./scripts/doctor.sh --team <prefix> \
  --cwd /path/to/primary-project \
  --add-dir /path/to/second-project
```

Doctor 会比较每个角色的结构化 process argv，包括 generic profile、显式 sandbox、空继承-writable-roots 覆盖和角色专属额外 root 策略。Planner/Coder 必须携带精确的有序列表，Reviewer 必须不携带 `--add-dir`。缺失、多余、重排、malformed 或 stale writable root 都是失败。使用当前 `start.sh` 重启三个角色；不要通过编辑私有全局配置来隐藏 mismatch。Doctor 通过只证明 launch argument，不证明实际文件访问或变更归属。

## Doctor 在较新版本上报告命令缺失

仅凭 version number 不能证明兼容。较新 release 可能重命名或移除脚本所用命令。

运行相关的当前 help：

```bash
herdr --help
herdr agent --help
herdr pane --help
herdr workspace --help
codex --help
```

只能根据观察到的 syntax 更新脚本，然后更新文档中的兼容性基线。不要仅因为旧示例使用某命令就加入 guessed command。

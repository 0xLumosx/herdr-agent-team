# 安全

[English](../security.md)

## 安全姿态

Herdr Codex Team 协调能够执行命令的 Agent。本地只有 Coder 可以在请求的项目
root 内写入；三个角色都能建立出站 command-network 连接，因此可能通过 SSH
或其他 client 在远端产生副作用。它通过可见路由、最小角色 filesystem 权限、
有界审查和可用时的 Git 证据减少歧义，但不会把语言模型 prompt 变成 hardened
security boundary。

使用本项目前，应理解每一层的实际权限：

```text
Herdr identity   哪个可见 live agent 收到消息
Team prefix      Planner 可以访问哪些精确同 Team 名称
Codex sandbox    tool operation 可以访问什么
Command network  shell command 是否可以连接外部主机
Approval policy  Codex 是否在普通审批点暂停
Role prompt      模型被要求采取什么行为
变更证据         Git diff，或 non-Git touched path 加明确证据缺口
```

## `approval_policy = "never"`

三个默认 profile 都设置：

```toml
approval_policy = "never"
```

在当前 Codex CLI 中，`never` 表示普通操作前 Codex 不会停下来请求批准；active policy 下无法运行的操作会失败并返回 Agent。它不代表“没有 sandbox”，也不会授予 sandbox 拒绝的访问权限。

必须理解这一取舍：自动 handoff 不会停在日常 prompt，但用户会失去在已经获准的潜在重大命令执行前进行交互检查的机会。启动前请检查 role prompt、仓库 instruction、hook 和 sandbox。

参见[官方 Codex 配置参考](https://developers.openai.com/codex/config-reference/)、[权限指南](https://learn.chatgpt.com/docs/permissions)和[sandbox 与 approval 指南](https://developers.openai.com/codex/agent-approvals-security/)。

## Sandbox 矩阵

| 角色 | 本地 filesystem | Command network | 残余风险 |
| --- | --- | --- | --- |
| Planner | `read-only` | 启用 | 可向同 Team peer 发消息，也可通过允许的 network client 修改远端主机 |
| Coder | `workspace-write` | 启用 | 可在允许 root 内做破坏性或无关本地变更，也可通过 network client 修改远端 |
| Reviewer | `read-only` | 启用 | 可暴露敏感内容，也可通过允许的 network client 修改远端主机 |

受管启动下，“只有 Coder 写源码”同时由 Planner 与 Reviewer 的 sandbox 强制。Planner bridge 不包含文件系统工具，只接受同 Team 身份检查，以及按角色向 Coder 或 Reviewer 发消息。这不能证明未受管的同用户进程、不安全 hook 或被篡改的已安装 bridge 无法写入；non-Git 证据也仍不完整。

Reviewer 的受管 Python 环境会避开 pytest 自身的默认捕获、cache 和 bytecode
写入，但不会给 sandbox 增加可写例外。需要临时文件、构建输出、coverage 数据
或依赖写入 plugin 的测试套件，仍超出 Reviewer 可验证的范围；Reviewer 应报告
这一限制，而不是静默获得 scratch 或 workspace 写权限。

每个可重复 `--add-dir` 只扩大 Coder 的受管可写 path set。Planner 接收相同 path
作为只读 workspace context，Reviewer 不接收；两者的受管 permission profile
继承 `:read-only`，Coder 的 profile 继承 `:workspace`。三个具名 beta permission
profile 都启用 command
network。Startup 会重复精确的 `default_permissions`、`extends` 和
`network.enabled=true` 设置，不传入旧的 `--sandbox` 或
`sandbox_workspace_write.writable_roots` override；在受支持 CLI 上，这些旧参数
可能与预期的实际策略冲突或抑制它。所有角色 profile 还设置
`agents.enabled = false`，startup 会用精确 CLI 覆盖重复该设置，从工具面移除
可能创建隐藏 `/root/*` worker 的 Codex 原生协作能力；Planner 的有界 Herdr MCP
工具仍保留。Doctor 会验证 live argv，因此旧策略下启动的角色进程在 Team 重建
前会被拒绝。Startup 与 Doctor 还会检查模型实际可见的 filesystem sandbox 和
network 状态；permission profile 实现不兼容或出现冲突的旧参数时会 fail
closed。受管 startup 后，`doctor.sh --team <prefix>` 可以读取安全的最新启动
记录，并核实角色专属 launch argv、bridge 完整性以及所记录的 workspace/pane
identity。显式提供 `--cwd`（及有序 `--add-dir`）会绕过所记录的 workspace/pane
binding，直接核实请求的 live scope。这些检查是 launch 证据，不能证明某次
具体读写已发生。

`danger-full-access` 不是项目默认值。不要用它绕过 `Operation not permitted`、missing hook、错误 `CODEX_HOME` 或不兼容 CLI。应诊断具体边界。

## SSH 权限与更安全的默认值

Command-network grant 会宽到足以让普通 SSH client 工作；它不限于 SSH、22
端口或某个配置的 hostname。本地 `read-only` sandbox 只控制本地 filesystem
操作。SSH session 建立后，远端账号、server ACL 和 remote command 决定可以
改变什么。由于 `approval_policy = "never"` 没有日常交互检查点，已经获准的
SSH command 可以立即生效。

每个可能使用 SSH 的角色都应：

- 使用专用低权限远端账号和任务专用密钥；不得把 private key 或主机细节写入
  本仓库；
- 在受控 `known_hosts` 文件中固定 host key，并保持
  `StrictHostKeyChecking=yes`；绝不能用 `StrictHostKeyChecking=no` 绕过验证；
- 使用 `BatchMode=yes` 与 `IdentitiesOnly=yes`，使非交互失败保持确定性；
- 通过 `ForwardAgent=no`、`ClearAllForwardings=yes` 与 `ForwardX11=no` 等设置
  禁用 agent、port 和 X11 forwarding；
- 任务不需要一般 shell 时，通过 server-side ACL、forced command 或专用环境
  限制远端账号。

这些控制会缩小远端权限，但不会把广泛的本地 network grant 变成 host
allowlist。受管启动验收证明的是 launch policy，不证明具体远端主机安全，也不
证明某次 SSH 操作只读。

## 本项目未消除的威胁

- **来自仓库的 prompt injection：**源码、issue、generated log 或 test 可能包含旨在重定向 Agent 的指令。
- **允许 root 内的不安全命令：**即使没有完整 host 权限，Coder 仍可删除或破坏可写文件；Planner 也可能向同 Team Coder 发送不安全实现请求。
- **Non-Git 证据降级：**non-Git root 没有权威 baseline、完整 diff、untracked-file inventory、rollback point，也无法可靠区分预存变更与任务变更。最大努力的 touched-path 列表不是替代品。
- **不可信 hook 或 integration：**hook 在语义角色契约之外执行，并可能随软件更新而变化。
- **Secret disclosure：**Agent 可以读取可访问 credential、`.env` 文件、proprietary source 或 log，并在 terminal/report 中复述。
- **虚假 report：**Agent 可以声称测试通过或另一个 Agent 已回复；必须根据 process state、command output、可用 Git 证据，以及对所报 non-Git touched path 的直接检查进行验证。
- **Profile source 真实性：**SHA-256 marker 只能检测已安装 prompt 或 policy 是否与当前 checkout 发生漂移，它不是签名。能同时修改 checkout 和已安装文件的 writer 也能同时改变两者，因此 marker 不能建立可信 provenance，也无法抵抗恶意本地 writer。
- **共享 scope 竞态：**startup 会比较每个 Team 的完整受管 root set。Git-backed 路径使用物理 worktree root，non-Git 路径使用物理目录 root；相同、祖先或后代 scope 重叠都会 fail closed。使用同一 `CODEX_HOME` 的当前 `start.sh` 进程还会在受管 preflight 和 Herdr workspace/Agent 创建期间共享一把短期锁，从而只关闭这些 helper 之间的 check/create 竞态。这把锁不是 filesystem ACL、per-root reservation、Team 全生命周期 lease 或 Herdr-wide transaction。不同 `CODEX_HOME` namespace、human、外部 tool、旧 helper、手工 Herdr 操作或不符合受识别命名规则的 Agent 仍会使 attribution 和 review 不可靠。
- **Bridge/配置被篡改：**bridge 会拒绝任意名称，只推导精确同 Team peer；但能同时替换 source、已安装 bridge、profile 和匹配 digest 的 writer 可以改变这项策略。
- **依赖和测试副作用：**仓库命令可能访问网络、修改外部 service，或在其可用权限内运行不可信 build step。
- **远端主机副作用：**每个受管角色都能使用 command network；本地 filesystem
  只读不会阻止远端 SSH 账号获准执行的写入、service 修改或 process control。

独立 Reviewer 能提高缺陷检测能力，但它不是 security scanner、formal verifier 或 isolation boundary。

完整 integration test 同样不是 writer-attribution 或 filesystem audit。它要求 challenge-derived Coder/Reviewer success response、fixture history 不变、恰好一个预期 fixture diff、其他方面 Git-clean 且 committed 的 host 之 Git-visible status/branch/`HEAD` 保持不变，并要求脚本自有 assertion、fixture test 和 Planner 本次运行特定 approval 通过。Harness 还会为自己的 baseline commit 禁用用户级 Git signing 和 hook。它不会发现对 ignored host file 的修改，因此 host 必须可丢弃，且不包含敏感 ignored state。受管 Planner 和 Reviewer 均为只读，但这些观察仍无法以 cryptographic 方式证明不存在未受管进程写入。需要 hard attribution 的仓库必须使用外部 process/filesystem audit。

## 推荐操作流程

受管 startup 前：

1. 尽可能使用 clean branch 或 disposable worktree；为每个并发 Team 提供互不重叠的完整 root set，并为同一仓库中的并发任务使用独立 worktree 和 `--cwd`；
2. commit 或安全保留 baseline；
3. 移除任务不需要的 secret；
4. 检查仓库级 Agent instruction 和脚本；
5. 检查 Codex profile override 和 Herdr hook。

受管 startup 后立即执行：

1. 使用 Team-aware `doctor.sh --team <prefix>` 核实安全的最新启动记录；也可以提供同一 `--cwd` 和全部有序 `--add-dir` 直接核实 scope，然后运行匹配的 communication test；
2. 确认 Planner 与 Reviewer 均为 `read-only`，并且 Planner bridge 与当前 checkout 一致。

工作期间：

- 观察 Herdr 是否路由到预期实时名称；
- 对路由有疑问时，验证 Planner 的 `SELF_AGENT`、`TEAM_PREFIX`、`CODER_AGENT` 和 `REVIEWER_AGENT`；
- 不要替处于 blocked approval/question state 的 Agent 自动回答；
- 立即拒绝意外变更并保留证据；
- 防止 Coder 和 Reviewer 绕过 Planner；
- 按实际风险处理 test output 和 external-service change。

Merge Git-backed 变更前：

```bash
git status --short
git diff
git diff --staged
```

检查每个 changed file，在可信 shell 中重新运行 critical validation，并检查 credential 或 generated artifact。`APPROVED` 是 Agent 决策，不能替代仓库 ownership control 或组织要求的 human review。

对每个 non-Git root，记录 `Git evidence: NOT AVAILABLE`，直接检查所报 touched path，并保留“变更集完整性和预存归属未被证明”这一限制。如果主 cwd 为 non-Git，把依赖 Git host 的 `full` 和 `policy` 记为 `NOT RUN`。`ping`、`communication` 和 `isolation` 仍只是有界的路由证据，无法补回缺失的文件系统历史。

## Hook 与信任

安装或更新 Herdr integration 后，Codex 可能报告 hook 新增或发生变化。应把它视为需要检查的安全事件，而不是 onboarding 障碍。

请确认：

- file path 位于预期用户配置下；
- source 是预期 Herdr 安装；
- command 和引用脚本可以理解；
- 不含意外 network、credential 或 destructive operation；
- 变更与你发起的更新一致。

不要为正常交互式设置使用危险 hook-trust bypass。

## 备份和本地配置

`install.sh` 会在替换前备份现有目标 profile 和受管 Planner bridge。备份可能含有私有 model provider、endpoint、path 或 instruction。它们保留在 `$CODEX_HOME` 下，不应 commit、upload，或未经脱敏就放入 bug report。

仓库模板绝不能包含从真实机器复制的 API key、access token、private SSH target 或 user-specific configuration。

`uninstall.sh` 会把受管理角色 profile 和 Planner bridge 移到新的时间戳备份，并保留早期备份、基础配置、credential 和无关 hook。删除这些内容属于另一项由用户负责的安全决策。

受管 startup 还会在 `$CODEX_HOME/herdr-codex-team/state/v1` 下为每个 Team 保存一份 latest-run 记录。其目录权限为 `0700`，`current.json` 与短期 startup-lock owner 文件权限为 `0600`。这些 mode 会限制普通本地访问，但不是 encryption、sandbox，也不能作为抵抗同一用户进程的 ACL。记录包含项目绝对路径和 Herdr workspace/pane ID，应视为私有信息，分享前必须脱敏。它不包含 task prompt、transcript、源码、Reviewer decision 或 conversation state，也不参与 Agent 通讯：Herdr 仍是唯一的实时 identity 和 prompt-transport 权威。`uninstall.sh` 刻意保留这些记录；只有在确实要丢弃诊断历史时，才另行检查并删除。详见[启动状态](launch-state.md)。

## 敏感仓库

对于 regulated、safety-critical、credential-bearing 或其他敏感项目，请先在 disposable non-sensitive repository 中验证此工作流。组织级 access control、network isolation、required human approval 和 audit policy 应独立于本项目实施。

受管启动为 Planner 提供直接 `read-only` 文件系统边界，bridge 也不暴露文件操作。这比仅靠 prompt 的规则明显更强，但仍不是不可篡改的同用户安全边界：能替换 checkout、已安装 bridge、profile 和 digest 的 writer 可以改变策略。要求 audited writer attribution 的仓库仍需要外部 process/filesystem control。

Team 前缀不会改变这一边界，也不会隔离文件系统。两个名称隔离的 Team 只要主 root 或额外 root 重叠就仍会竞态。要在同一仓库并发执行任务，请在启动 Team 前创建独立 branch 和 Git worktree，并保持每个额外 root 也互不重叠。本项目刻意不自动创建、merge、移除 worktree 或解决 conflict。

## 报告漏洞

不要在公开 issue 中发布 secret 或可利用的 report。仓库有公开托管位置后，应优先使用其 private security-advisory channel。此前请私下联系维护者，并提供 affected version、minimal reproduction、impact 和 suggested mitigation。

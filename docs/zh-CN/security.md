# 安全

[English](../security.md)

## 安全姿态

Herdr Codex Team 协调能够执行命令的 Agent，其中两个角色可以在仓库内写入。它通过可见路由、最小角色权限、有界审查和 Git 证据减少歧义，但不会把语言模型 prompt 变成 hardened security boundary。

使用本项目前，应理解每一层的实际权限：

```text
Herdr identity   哪个可见 live agent 收到消息
Team prefix      Planner 可以访问哪些精确同 Team 名称
Codex sandbox    tool operation 可以访问什么
Approval policy  Codex 是否在普通审批点暂停
Role prompt      模型被要求采取什么行为
Git review       实际发生了哪些变更
```

## `approval_policy = "never"`

三个默认 profile 都设置：

```toml
approval_policy = "never"
```

在当前 Codex CLI 中，`never` 表示普通操作前 Codex 不会停下来请求批准；active policy 下无法运行的操作会失败并返回 Agent。它不代表“没有 sandbox”，也不会授予 sandbox 拒绝的访问权限。

必须理解这一取舍：自动 handoff 不会停在日常 prompt，但用户会失去在已经获准的潜在重大命令执行前进行交互检查的机会。启动前请检查 role prompt、仓库 instruction、hook 和 sandbox。

参见[官方 Codex 配置参考](https://developers.openai.com/codex/config-reference/)和[sandbox 与 approval 指南](https://developers.openai.com/codex/agent-approvals-security/)。

## Sandbox 矩阵

| 角色 | 默认值 | 原因 | 残余风险 |
| --- | --- | --- | --- |
| Planner | `workspace-write` | Herdr communication 在 `read-only` 下可能失败 | prompt 禁止源码编辑，但文件系统能力仍存在 |
| Coder | `workspace-write` | 实现需要仓库写入 | 可在允许 root 内做破坏性或无关变更 |
| Reviewer | `read-only` | 独立检查不需要写入 | 仍可能在输出中暴露敏感内容，或调用允许的只读 service |

“只有 Coder 写源码”对 Reviewer 完全由 sandbox 强制，但对 Planner 只由策略强制。模型可能违反 prompt。Planner 的最终 diff 检查有助于事后发现违规，却不能阻止违规。

`danger-full-access` 不是项目默认值。不要用它绕过 `Operation not permitted`、missing hook、错误 `CODEX_HOME` 或不兼容 CLI。应诊断具体边界。

## 本项目未消除的威胁

- **来自仓库的 prompt injection：**源码、issue、generated log 或 test 可能包含旨在重定向 Agent 的指令。
- **允许 root 内的不安全命令：**即使没有完整 host 权限，Coder 和 Planner 仍可删除或破坏可写文件。
- **不可信 hook 或 integration：**hook 在语义角色契约之外执行，并可能随软件更新而变化。
- **Secret disclosure：**Agent 可以读取可访问 credential、`.env` 文件、proprietary source 或 log，并在 terminal/report 中复述。
- **虚假 report：**Agent 可以声称测试通过或另一个 Agent 已回复；必须根据 process state、command output 和 Git 验证。
- **Profile source 真实性：**SHA-256 marker 只能检测已安装 prompt 或 policy 是否与当前 checkout 发生漂移，它不是签名。能同时修改 checkout 和已安装文件的 writer 也能同时改变两者，因此 marker 不能建立可信 provenance，也无法抵抗恶意本地 writer。
- **共享工作树竞态：**启动会拒绝同一物理 worktree 中已可见、可核实的 Herdr Codex 角色，但该 preflight 不是原子锁。Human、外部 tool、检查后竞态或不符合受识别命名规则的 Agent 仍会使 attribution 和 review 不可靠。
- **跨 Team prompt failure：**前缀会创建明确路由，但 compromised 或错误配置的 Planner 仍可尝试访问另一个 live Team；fail-closed prompt 和 isolation test 只能降低风险，不能以 cryptographic 方式消除风险。
- **依赖和测试副作用：**仓库命令可能访问网络、修改外部 service，或在其可用权限内运行不可信 build step。

独立 Reviewer 能提高缺陷检测能力，但它不是 security scanner、formal verifier 或 isolation boundary。

完整 integration test 同样不是 writer-attribution 或 filesystem audit。它要求 challenge-derived Coder/Reviewer success response、fixture history 不变、恰好一个预期 fixture diff、其他方面 Git-clean 且 committed 的 host 之 Git-visible status/branch/`HEAD` 保持不变，并要求脚本自有 assertion、fixture test 和 Planner 本次运行特定 approval 通过。Harness 还会为自己的 baseline commit 禁用用户级 Git signing 和 hook。它不会发现对 ignored host file 的修改，因此 host 必须可丢弃，且不包含敏感 ignored state。由于 Planner 有 `workspace-write`，这些观察无法在操作系统或 cryptographic 层面证明每个 byte 只由 Coder 写入。需要 hard attribution 的仓库必须使用外部 process/filesystem audit，以及超出当前项目范围的隔离设计。

## 推荐操作流程

启动前：

1. 使用 clean branch 或 disposable worktree；为每个并发 Team 提供独立 worktree 和 `--cwd`；
2. commit 或安全保留 baseline；
3. 移除任务不需要的 secret；
4. 检查仓库级 Agent instruction 和脚本；
5. 检查 Codex profile override 和 Herdr hook；
6. 运行 Team-aware `doctor.sh`，再运行匹配的 communication test；
7. 确认 Reviewer 仍为 `read-only`。

工作期间：

- 观察 Herdr 是否路由到预期实时名称；
- 对路由有疑问时，验证 Planner 的 `SELF_AGENT`、`TEAM_PREFIX`、`CODER_AGENT` 和 `REVIEWER_AGENT`；
- 不要替处于 blocked approval/question state 的 Agent 自动回答；
- 立即拒绝意外变更并保留证据；
- 防止 Coder 和 Reviewer 绕过 Planner；
- 按实际风险处理 test output 和 external-service change。

Merge 前：

```bash
git status --short
git diff
git diff --staged
```

检查每个 changed file，在可信 shell 中重新运行 critical validation，并检查 credential 或 generated artifact。`APPROVED` 是 Agent 决策，不能替代仓库 ownership control 或组织要求的 human review。

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

`install.sh` 会在替换前备份现有目标 profile。备份可能含有私有 model provider、endpoint、path 或 instruction。它们保留在 `$CODEX_HOME` 下，不应 commit、upload，或未经脱敏就放入 bug report。

仓库模板绝不能包含从真实机器复制的 API key、access token、private SSH target 或 user-specific configuration。

`uninstall.sh` 会把受管理角色 profile 移到新的时间戳备份，并保留早期备份、基础配置、credential 和无关 hook。删除这些内容属于另一项由用户负责的安全决策。

## 敏感仓库

对于 regulated、safety-critical、credential-bearing 或其他敏感项目，请先在 disposable non-sensitive repository 中验证此工作流。组织级 access control、network isolation、required human approval 和 audit policy 应独立于本项目实施。

如果策略要求硬保证 Planner 无法写源码，当前 Planner 设计不满足要求：其 `workspace-write` sandbox 是刻意接受的 Herdr compatibility compromise。请使用只暴露 Herdr communication endpoint 和只读仓库 view 的外部隔离设计，否则不要在该仓库使用此工作流。

Team 前缀不会改变这一边界，也不会隔离文件系统。两个名称隔离的 Team 共享同一 checkout 时仍会竞态。要在同一仓库并发执行任务，请在启动 Team 前创建独立 branch 和 Git worktree。本项目刻意不自动创建、merge、移除 worktree 或解决 conflict。

## 报告漏洞

不要在公开 issue 中发布 secret 或可利用的 report。仓库有公开托管位置后，应优先使用其 private security-advisory channel。此前请私下联系维护者，并提供 affected version、minimal reproduction、impact 和 suggested mitigation。

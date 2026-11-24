# Herdr Agent Team 开发指南

本文件供修改本仓库的编码 agent 使用。Herdr 管理窗格和消息投递，各 CLI 保存自己的对话历史，本仓库负责启动三个角色、关联会话和共享 SSH 目的地。若你正在受管 Herdr 窗格中工作，按该窗格的角色指令执行任务。Planner 与用户核对方案后派单并验收。Coder 执行实现任务与转交的审查修正，遇阻找 Planner。Reviewer 只读审查，先与 Planner 澄清，必要时向用户提问，最终审查报告只在 Reviewer 窗格展示。Planner 在自己的窗格给出验收决定。

## 从哪里改

| 改动 | 入口和需要一起检查的地方 |
| --- | --- |
| 启动、重开或诊断团队 | 从 [open.sh](scripts/open.sh) 看新建和复用分支，再查 [start.sh](scripts/start.sh) 和 [doctor.sh](scripts/doctor.sh)。调整启动参数时，让 Doctor 能从实际进程和启动记录验证同一配置。 |
| 角色、模型或技能 | 公共角色指令在 [prompts/](prompts/)，Codex 模板在 [profiles/](profiles/)，Claude Code 和 Antigravity 的启动参数在 [providers.py](scripts/providers.py)。Codex 配置只嵌入角色提示词。用户可以在单次请求中点名额外的技能。修改源模板后通过安装器生成配置。 |
| 会话恢复、派单或团队 SSH | 从 [herdr_mcp.py](scripts/herdr_mcp.py) 查绑定和身份校验。恢复时核对团队、项目目录、角色 CLI 和原生会话 ID，保留旧 Codex 记录的兼容性。SSH 目的地属于当前会话组，远端写权限只给 Coder。 |
| 在远端启动整个团队 | 检查 [remote.sh](scripts/remote.sh) 的传输清单和 [remote-bootstrap.sh](scripts/lib/remote-bootstrap.sh) 的远端入口。新增启动依赖时，确认远端没有本仓库检出也能运行。 |

## 方案决策

制定或调整算法、架构、优化方案前，先读 [方案历史](docs/approach-history.md)，按原理和适用条件查找已有结论。优先复用已验证的实现。重试未达标或已弃用的方案前，说明条件变化、验证目标，并确认用户授权覆盖这次重试。

方案结束时追加结果，保留原记录。写清原理、适用条件、状态、验收标准、实际结果、证据位置和重试条件。尚未验证的项目标为待验证。

## 按改动验证

- 改通信桥或会话绑定时，从仓库根目录运行 `python3 -B tests/test_herdr_mcp.py`。改启动脚本、角色配置、安装器或远端传输清单时，运行 `./scripts/test.sh static`。
- 改实际派单时，在目标 Herdr 测试会话的 shell 窗格运行 `./scripts/test.sh --team <团队名> communication`。改会话恢复时，切换两个已绑定的 Planner 对话，核对两次切换后三个窗格的实际会话 ID。改 SSH 共享时，由各角色读取登记的远端目录并核对结果。
- 纯文档修改检查相对链接、命令及所述行为。交付时列出实际执行的检查和仍未验证的部分。标记开发中留下的可删除测试文件，待用户明确同意后再删除已标记的文件。

## Git 提交

提交或推送前取得用户批准。提交使用 `0xLumosx <c1trusovo@163.com>`，标题写明具体改动，需要区分模块时加 scope，例如 `fix(ssh): restore the linked remote directory`。

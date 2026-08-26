# 启动状态

[English](../launch-state.md)

Herdr Codex Team 会为每个 Team identity 保存一份小型、用户本地的最新 workspace 创建记录。它用于改善诊断和重启重建，但不会成为 task database 或第二套 runtime。

## 位置和权限

默认 `CODEX_HOME=~/.codex` 时，带前缀 Team 使用：

```text
~/.codex/herdr-codex-team/state/v1/
├── startup.lock/                 # 通常是短期目录；不安全 stale owner 会保留
└── teams/
    ├── legacy/current.json
    └── prefixed-<team-prefix>/current.json
```

State 目录权限为 `0700`；`current.json` 和 lock owner 文件为 `0600`。本项目在 `$CODEX_HOME` 下管理的每个 path component 都必须是真实目录，不能是 symlink。状态中包含项目绝对路径，因此不要在未脱敏时把它发布到 issue 或 commit。

主项目、`--add-dir` 项目、`.git` 和 `.omx` 中都不会写入该状态。`install.sh` 和 `uninstall.sh` 不会复制、上传或删除它。

## 记录内容

`current.json` 使用 `schema_version: 1`，记录：

- 每次 helper 调用的 `run_id`、`started_at`、`updated_at`，以及最后启动 observation：`starting`、`partial` 或 `ready`；
- legacy/prefixed Team identity 和精确 Planner/Coder/Reviewer 实时名称；
- 物理主 cwd 和有序额外 root；
- root set 是否包含证据降级的 non-Git 目录；
- Herdr workspace ID，以及每个 pane 被观察到后的精确 pane ID；
- 每个角色的预期 sandbox。

文件刻意不包含 task prompt、response、terminal transcript、diff、源码、token、approval、任务完成状态或 Reviewer 决策。每个 Team 只保留最近一次已创建 run。`run_id` 只用于关联同一次 helper 调用写入的字段；它不会注入 Herdr，也不能证明之后的 live process 属于所记录的 run。

文件先在 Team state 目录生成，设置为 `0600`，再 rename 覆盖 `current.json`。因此 reader 会看到旧的完整文件或新的完整文件，而不是正常情况下的半写入内容。Doctor 会在使用前验证完整文件。

## 权威所有者

| 事实 | 权威所有者 |
| --- | --- |
| 实时 workspace、pane、Agent identity、lifecycle、prompt transport | Herdr |
| 角色 profile、sandbox 和 writable-root argv | 实时 Codex process |
| 当前代码与变更证据 | Git 或 filesystem |
| 本 startup helper 之前写入的值 | 启动记录 |

记录只是待核实的预期值。它不能让缺失 Agent 变为 live、授予 filesystem access、在 startup 后继续保留 root、证明 delivery 或恢复 Codex 对话。

## Doctor 行为

一次受管 startup 成功后，可以使用短命令：

```bash
./scripts/doctor.sh --team github
```

只有在既未提供 `--cwd` 也未提供 `--add-dir` 时，Doctor 才读取最近记录。它会重新解析所记录的 root，并要求实时名称、workspace ID、每个非空的已记录 pane ID、cwd、profile、sandbox 和有序额外 root argv 全部匹配。Herdr 仍是权威：不匹配时报告 stale 或不同 runtime identity，不会反向改写任何一侧。

显式形式会绕过所记录的 workspace/pane binding，直接核实请求的 live scope：

```bash
./scripts/doctor.sh \
  --team github \
  --cwd /absolute/path/to/primary-project \
  --add-dir /absolute/path/to/second-project
```

需要诊断有意替换的 session 或 stale record 时使用显式形式。它不会修改或删除保存的记录。

Malformed、过大、不支持 schema、symlink 或错误 Team 的状态会在 Doctor 联系 Herdr 前失败。没有状态时保留旧行为：Doctor 检查 live Team identity；除非显式提供 root，否则没有保存的 multi-root 预期值。

## Startup lock

使用同一 `CODEX_HOME` 的当前 `start.sh` 进程共享该 state root 下的一把短期锁。锁在实时名称和完整 root preflight 前开始，并在 helper 尝试记录结果后退出时释放；它只关闭该 namespace 内当前 helper 并发调用之间的 check/create 竞态。

Owner record 包含本地主机、PID、run ID、Team display name 和 owner token。同主机且 PID 仍存活时会立即失败。同主机死亡 owner 会先被原子 rename 到唯一 quarantine，再删除已知 owner 文件；意外内容会保留供检查。Malformed owner 或不同/未知主机会 fail closed。

这把锁不是：

- 在 Team 全生命周期持有的 per-root lease；
- 操作系统 ACL 或 process sandbox；
- 对旧 helper、手工 Herdr 操作或外部 writer 的保护；
- 与使用不同 `CODEX_HOME`、但连接同一 Herdr server 的当前 helper 串行；
- “只有 Coder 修改文件”的证据。

Startup 结束后，精确实时名称和完整 root inspection 仍是受管 collision guard。同一仓库内并发工作仍需用户为每个 Team 创建独立 worktree。

## 恢复边界

如果原来的三个 Codex process 仍然 live，请通过 Herdr 返回那些精确 pane；只有原 session 保留对话。如果它们已被替换，启动记录可以帮助核实 root 并区分旧 workspace/pane，但新 session 不会恢复旧对话。应从 Git evidence 或所报 non-Git touched path 重建任务，再发送新的自包含 handoff。

`partial` 只表示 startup 创建了 workspace，但没有完成并持久化 `ready` 结论；实时角色仍可能已经 ready。请检查记录的 ID 和实时 Herdr state。不要盲目重跑 startup、自动停止 workspace，也不要把 `partial` 解释为任务进度。

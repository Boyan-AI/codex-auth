# Task: 修复 CPA 孤儿凭据导致的 502
Created: 2026-08-03
Status: completed
Execution Mode: solo

## 目标
清理当前 CPA 专用认证目录中的两份孤儿凭据，并让 Codex Auth 后续自动把 CPA 账号池收敛到注册表智能池成员，避免旧凭据再次被路由并产生 401/502。

## 计划

### Step 1: 可恢复隔离孤儿凭据并验证现场 [🔴 必须确认档] [✅ 完成]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 外部：本机 CPA 专用认证目录
  - 外部：本机 CPA 权限受控备份目录
  - /tmp/codex-auth-cpa-502/
- 关键决策: 用户已明确允许；只移动经稳定 `account_key` 比对确认不在注册表智能池中的两份孤儿 JSON，备份目录权限设为 0700，不读取或输出认证内容。隔离后执行一次最小真实 CPA Responses 请求。
- 验收:
  - CPA 认证目录从 4 份收敛到 2 份，两个预期成员均保留
  - `/v1/models` 继续返回 200
  - 最小 `/v1/responses` 请求返回 200；若失败，记录状态与脱敏错误并保留可恢复现场
- 验证结果: 两份孤儿凭据已移入 0700 备份目录，CPA auth 从 4 份收敛到 2 份；models 与最小 Responses 请求均返回 200，响应包含预期文本。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 2: 固化 CPA 目录对账规则与回归测试 [🔵 自动档] [✅ 完成]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - src/registry/export.zig
  - src/registry/root.zig
  - src/cli/types.zig
  - src/cli/commands/gui.zig
  - src/cli/commands/root.zig
  - src/workflows/gui.zig
  - tests/registry_test.zig
  - tests/cli_behavior_test.zig
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/AppStateTests.swift
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/CLIClientTests.swift
- 关键决策: CPA 运行时使用 App 专属认证目录，因此账号文件应与注册表中 `smart_pool_enabled` 的 ChatGPT 成员精确一致；API Key 仍由 CPA 管理接口维护，不进入该目录对账。
- 验收:
  - 测试覆盖保留预期账号、删除孤儿账号、不触碰非 JSON 文件和 API Key 管理路径
  - App 启动对账失败时只展示可恢复错误，不阻止直连功能
- 验证结果: 已新增 Zig 目录/解析测试与 Swift CLI/AppState 测试；失败基线分别确认缺少目录对账 API、命令联合类型和 Swift 启动对账接口，符合测试先行预期。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 3: 实现启动时 CPA 账号池自动对账 [🟡 推荐默认档] [✅ 完成]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - src/registry/export.zig
  - src/registry/root.zig
  - src/cli/types.zig
  - src/cli/commands/gui.zig
  - src/cli/commands/root.zig
  - src/cli/help.zig
  - src/workflows/gui.zig
  - macos/CodexAuthApp/Sources/CodexAuthApp/CodexAuthCLIClient.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/AppState.swift
  - docs/cpa-smart-routing.md
- 关键决策: 新增受约束的 GUI 机器命令完成目录级对账，由 App 启动刷新后调用；对账只基于注册表账号快照和专用 CPA auth 目录，不向 Swift 暴露认证内容。
- 验收:
  - 孤儿凭据被删除后 CPA 文件监听器实时更新池成员
  - 合法成员、排除成员和 API Key 路径行为不变
  - 公开 CLI 输出、帮助和错误保持英文
- 验证结果: 新增 `gui cpa-sync reconcile <auth-dir>`，先删除非成员 JSON 再重写启用的 ChatGPT 成员；App 启动先对账、再刷新终止性认证状态。API Key 仍只走管理接口，未配置 CPA 时静默跳过。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 4: 隔离验证、桌面交付与提交 [🔵 自动档] [✅ 完成]
- 依赖: Step 3
- 可并行: 否
- 执行者: lead
- 写入范围:
  - .agent/plans/active/2026-0803-cpa-orphan-auth-reconciliation.md
  - .agent/plans/done/2026-0803-cpa-orphan-auth-reconciliation.md
  - .agent/desktop-delivery-ready.json
- 关键决策: 先按本机 Zig 版本和标准库源码验证 API，再在 `/tmp/codex-auth-cpa-orphan-reconcile` 隔离 HOME 运行 Zig 与 Swift 测试；正常验证通过后使用桌面交付 Hook 安装、提交并推送精确清单。
- 验收:
  - 修改 Zig 后运行 `zig build run -- list`
  - Zig 测试与 Swift 测试通过
  - 桌面 App 安装成功且仅一个进程
  - 精确任务文件提交并推送，工作区干净
- 验证结果: `zig build run -- list` 通过；Zig 全套测试退出码 0；Swift 79 项测试全过；桌面 App 已由唯一安装脚本覆盖并启动，单进程 PID 52460，启动后 CPA auth JSON 保持为 2 份预期成员。提交与推送由精确清单桌面交付 Hook 完成。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

## 关键上下文
- 现场事实：注册表 4 个账号，2 个启用智能池；CPA auth 目录 4 份 JSON，其中 2 份映射到启用成员、2 份已不在注册表，预期成员无缺失。
- CPA 进程正常，`/v1/models` 返回 200 且包含 `gpt-5.6-sol`；历史日志存在认证失效与 `/v1/responses` 401/502。
- 当前实现仅按已知账号逐个 include/exclude，无法发现注册表之外的历史孤儿文件。
- 认证内容、客户端 Key、管理 Key 和完整模型响应不得写入项目或命令输出。

## 已改动文件汇总
- .agent/plans/active/2026-0803-cpa-orphan-auth-reconciliation.md (计划初始化)
- .agent/plans/active/2026-0803-cpa-orphan-auth-reconciliation.md (补充实际回归测试文件范围)
- tests/registry_test.zig (新增 CPA 目录精确收敛回归测试)
- tests/cli_behavior_test.zig (新增 reconcile 机器命令解析测试)
- macos/CodexAuthApp/Tests/CodexAuthAppTests/CLIClientTests.swift (新增客户端对账命令测试)
- macos/CodexAuthApp/Tests/CodexAuthAppTests/AppStateTests.swift (新增启动对账与失败降级测试)
- src/registry/export.zig (实现 CPA 目录精确对账)
- src/registry/root.zig (导出对账接口)
- src/cli/types.zig (扩展 CPA 同步联合类型)
- src/cli/commands/gui.zig (解析 reconcile 子动作)
- src/cli/commands/root.zig (释放 reconcile 参数)
- src/cli/help.zig (补充英文用法与示例)
- src/workflows/gui.zig (实现机器命令处理与计数输出)
- macos/CodexAuthApp/Sources/CodexAuthApp/CodexAuthCLIClient.swift (桥接启动对账命令)
- macos/CodexAuthApp/Sources/CodexAuthApp/AppState.swift (启动时执行可恢复对账)
- docs/cpa-smart-routing.md (记录启动目录收敛契约)
- .agent/plans/done/2026-0803-cpa-orphan-auth-reconciliation.md (归档完成计划与验证结果)

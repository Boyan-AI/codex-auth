# Task: CPA 失效账号路由防护
Created: 2026-08-03
Status: completed
Execution Mode: solo

## 目标
让明确出现 `token_invalidated` 或 `token_revoked` 的 ChatGPT 账号自动暂停 CPA 路由，并在桌面端清晰提示池健康状态；账号重新认证且额度刷新成功后自动恢复，不改变用户设置的智能池成员意愿。

## 计划

### Step 1: 固化失效判定与恢复语义 🟡 推荐默认档 ✅ 完成
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - macos/CodexAuthApp/Sources/CodexAuthApp/Models.swift
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/ModelsTests.swift
- 关键决策: 仅把明确的终止性认证状态 `token_invalidated`、`token_revoked` 判为不可路由；网络错误、未知状态和普通额度不足不自动改变路由资格，避免临时故障导致账号被错误下线。保留 `smart_pool_enabled` 作为用户意愿，另行计算运行时资格。
- 验收:
  - 模型测试覆盖两个失效状态、正常状态和非终止性错误。
  - 验证结果: `HOME=/tmp/cpa-invalid-account-routing-guard swift test --filter ModelsTests` 通过，共 21 项测试。

### Step 2: 在状态刷新后协调 CPA 凭据副本 🟡 推荐默认档 ✅ 完成
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - macos/CodexAuthApp/Sources/CodexAuthApp/AppState.swift
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/AppStateTests.swift
- 关键决策: AppState 接收最新账号状态后，仅对路由资格发生变化的成员调用现有 `syncCPAAccount`；失效时删除 CPA 副本，重新认证且刷新成功后恢复副本，不修改注册表中的智能池开关。
- 验收:
  - 测试覆盖首次发现失效、重复刷新不重复同步、恢复后重新加入、用户明确排除时不恢复。
  - 验证结果: `HOME=/tmp/cpa-invalid-account-routing-guard swift test --filter AppStateTests` 通过，共 22 项测试。

### Step 3: 展示可操作的池健康告警 🟡 推荐默认档 ✅ 完成
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - macos/CodexAuthApp/Sources/CodexAuthApp/MenuBarView.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/ManagementWindowController.swift
  - docs/cpa-smart-routing.md
- 关键决策: 菜单栏和路由页明确显示“登录失效，已暂停路由”，同时保留原有 CPA 服务连接状态，避免把服务健康与池成员健康混为一谈。
- 验收:
  - 失效成员不计入可路由账号；路由页能定位具体失效成员及其状态；文档同步运行时资格与自动恢复语义。
  - 验证结果: 菜单栏与路由页均使用运行时资格计数；`git diff --check` 通过。

### Step 4: 隔离验证桌面端行为 🔵 自动档 ✅ 完成
- 依赖: Step 2, Step 3
- 可并行: 否
- 执行者: lead
- 写入范围:
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/ModelsTests.swift
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/AppStateTests.swift
- 关键决策: 所有构建和测试使用 `/tmp/cpa-invalid-account-routing-guard` 作为 HOME，避免读取或改写真实账号状态。
- 验收:
  - `HOME=/tmp/cpa-invalid-account-routing-guard swift test` 通过。
  - `HOME=/tmp/cpa-invalid-account-routing-guard swift build` 通过。
  - 验证结果: 完整 Swift 测试 76 项通过；隔离构建成功。

### Step 5: 自动桌面交付、归档与提交 🔴 必须确认档 ✅ 完成
- 依赖: Step 4
- 可并行: 否
- 执行者: lead
- 写入范围:
  - .agent/plans/active/2026-0803-cpa-invalid-account-routing-guard.md
  - .agent/plans/done/2026-0803-cpa-invalid-account-routing-guard.md
  - .agent/desktop-delivery-ready.json
- 关键决策: 按项目自动桌面交付协议创建精确 marker；该流程会退出并覆盖桌面的 `Codex Auth.app`、重新启动、验证单进程、只提交任务文件并 push。若 Hook 尚未信任，则调用项目规定的 `desktop_delivery.py --manual`。
- 验收:
  - marker 的 `base_commit`、分支、中文提交说明和 `paths` 精确匹配本任务。
  - 桌面 App 安装与单进程验证成功。
  - 相关文件按 `fix: 暂停失效账号的 CPA 智能路由` 提交并 push；任何失败均保留可恢复状态且不扩大文件范围。
  - 交付准备: 用户已批准覆盖桌面 App、提交与 push，并授权临时本地 Git 排除规则；任务文件清单已与 `git diff --name-only` 核对，交由项目自动交付 Hook 执行安装、提交和 push。

## 关键上下文
- 现场 CPA 版本为 `7.2.109`，进程和 `/v1/models` 健康；故障来自智能池中的 `401 token_invalidated` 与 `401 token_revoked` 成员。
- 当前 `CodexAccount.isAvailable` 已能把这些账号显示为不可用，但 `participatesInSmartPool` 只反映用户开关，CPA 认证副本仍存在，所以轮询仍会选中失效成员。
- CPA 的 `max-retry-credentials` 不能可靠修复终止性 OAuth 失效；本任务不通过扩大重试掩盖坏凭据。
- 工作树已有用户未跟踪的历史计划和 `.codegraph/`，本任务不得暂存或改动它们。

## 已改动文件汇总
- .agent/plans/active/2026-0803-cpa-invalid-account-routing-guard.md (计划创建)
- macos/CodexAuthApp/Sources/CodexAuthApp/Models.swift (Step 1)
- macos/CodexAuthApp/Tests/CodexAuthAppTests/ModelsTests.swift (Step 1)
- macos/CodexAuthApp/Sources/CodexAuthApp/AppState.swift (Step 2)
- macos/CodexAuthApp/Tests/CodexAuthAppTests/AppStateTests.swift (Step 2)
- macos/CodexAuthApp/Sources/CodexAuthApp/MenuBarView.swift (Step 3)
- macos/CodexAuthApp/Sources/CodexAuthApp/ManagementWindowController.swift (Step 3)
- docs/cpa-smart-routing.md (Step 3)
- .agent/plans/done/2026-0803-cpa-invalid-account-routing-guard.md (Step 5)

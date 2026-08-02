# Task: 统一账号与 API Key 模式并接入 CPA
Created: 2026-07-31
Status: complete
Execution Mode: solo

## 目标
在现有 Codex Auth CLI、CPA 智能路由和 macOS 菜单栏 App 基础上，统一管理 ChatGPT 账号与 API Key/中转站连接，按认证类型展示正确的额度信息，并先提供网页 UI 预览供确认。

## 计划

### Step 1: 现状核对与方案定稿 [🔵] [✅]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 无
- 关键决策: 复用现有 `AccountRecord.auth_mode`、认证快照和 CPA 智能路由边界；统一展示列表，按 `chatgpt` 与 `apikey` 渲染不同信息。
- 验收:
  - 已确认 API Key 当前固定请求官方 `/v1/me`。
  - 已确认 CPA 启动配置当前只允许本机地址。
  - 已确认已有额度结构包含 `credits.balance`，但 GUI 尚未输出。

### Step 2: 生成统一模式的网页 UI 预览 [🟡] [✅]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - docs/codex-auth-key-mode-ui-preview.html
- 关键决策: 严格沿用当前菜单栏弹窗和管理窗口的导航、分栏、工具栏、列表及详情结构，只增量加入账号/Key 筛选和按连接配置选择直连/CPA；不引入新的连接管理器页面。
- 验收:
  - HTML 可直接在浏览器打开。
  - OAuth、官方 API Key和中转站 API Key 三种示例配置可切换查看。
  - 每个配置可独立选择直连或 CPA 路由。
  - 余额查询成功时显示余额；接口不支持、查询失败或没有数据时直接隐藏余额区域。
  - 已验证本地 HTTP 服务返回 `200 OK`。
  - 已使用 Chrome 真实渲染菜单栏和管理窗口，动态列表、详情区和响应式尺寸均正常。

### Step 3: 扩展 CLI/数据模型与额度接口 [🟡] [✅]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - src/auth/
  - src/api/
  - src/registry/
  - src/workflows/
  - tests/
- 关键决策: 保持现有账号快照兼容；为 API Key 连接增加可选 provider/base URL/余额查询配置，原始密钥只留在受保护认证文件，不进入 registry 或 GUI JSON；余额接口按 provider 配置解析，查询失败、不支持或无数据时不输出余额字段，由 UI 直接隐藏余额区域。
- 验收:
  - 可导入并识别官方 API Key 和中转站 API Key。
  - API Key 不参与 ChatGPT 时间窗口刷新。
  - 余额字段能从后端稳定输出，旧 registry 可迁移读取。
  - 相关 Zig 测试通过，并执行 `zig build run -- list`。
  - 已完成 provider/base URL/balance 字段、统一 GUI JSON、API Key 安全添加、地址校验，以及中转站不依赖 `/me` 的本地稳定身份。
  - 已补充 `gui add-key` 真实集成测试，确认密钥仅进入受保护认证快照，不进入 registry、标准输出或错误输出；空 registry 下新增 Key 不会成为当前连接。
  - provider 余额查询适配器未硬编码：中转站接口不统一，官方接口也不作为添加 Key 的前置条件；当前仅在已有成功快照时显示，查询失败/不支持/缺失时隐藏。

### Step 4: 接入 macOS App 的统一切换与 CPA Key 模式 [🔴] [✅]
- 依赖: Step 3
- 可并行: 否
- 执行者: lead
- 写入范围:
  - macos/CodexAuthApp/Sources/CodexAuthApp/
  - macos/CodexAuthApp/Tests/
  - docs/
- 关键决策: OAuth 直连继续替换活动 `auth.json`；API Key/中转站通过单次 Codex provider 覆盖和进程环境变量启动；CPA Key Pool 使用独立 CPA 认证目录，不能覆盖官方账号文件。远程中转站仅在明确配置且通过 HTTPS 时允许直接作为 provider，CPA 管理端仍保持本机限制。
- 验收:
  - App 可在统一列表中切换 OAuth、官方 API Key、中转站 Key 和 CPA Key Pool。
  - 切换只影响新启动的 Codex 会话。
  - API Key 详情显示余额而不是 5 小时/7 天窗口。
  - Swift 测试通过，且没有把密钥写入命令行参数或日志。
  - 已完成统一添加表单、Key 环境变量传递、默认不切换/不加入 CPA、已有当前连接登录后恢复、Key 列表和详情展示。
  - 已完成官方账号/官方 Key 直连与中转站单次 provider 覆盖启动链路；直连不注入 CPA 密钥，也不修改全局 Codex 配置。
  - 已在菜单中同时提供“智能启动 Codex”和“直连启动 Codex”，网页预览同步展示两个入口。
  - 已完成 CPA `codex-api-key` 管理 API 读改写：仅允许本机管理地址，管理密钥和上游 Key 均通过进程环境/stdin 配置传递，不进入参数、registry 或日志。
  - 已覆盖 CPA Key JSON 合并、已有高级字段保留、`auth-index` 清理、加入/移除和密钥不泄漏端到端测试。

### Step 5: 集成验证与交付准备 [🔵] [✅]
- 依赖: Step 4
- 可并行: 否
- 执行者: lead
- 写入范围:
  - docs/
  - .agent/desktop-delivery-ready.json
- 关键决策: 只同步本次任务的文档和代码变更；不纳入现有未跟踪 `.codegraph/`。
- 验收:
  - Zig、Swift、HTML 预览均完成验证。
  - `git diff --check` 通过。
  - 生成准确的桌面交付 marker，等待项目 Hook 处理，不 push。
  - 2026-08-02 已验证：`zig build test` 通过；`zig build run -- list` 通过；Swift 72 项测试全部通过；`git diff --check` 通过。
  - CPA Key Pool 已完成，最终验证通过。
  - 2026-08-03 用户已授权安装、提交和推送；桌面 App 已通过唯一安装脚本覆盖并启动，主进程 PID 85877。
  - 因既有未跟踪 `.codegraph/` 会触发 marker 精确工作区校验失败，交付按同一安全顺序手动执行，不纳入 `.codegraph/`。

## 关键上下文
- 当前工作树存在未跟踪 `.codegraph/`，属于既有用户/工具产物，不得修改或纳入本任务路径。
- 当前 schema 5 已有 `auth_mode`、`smart_pool_enabled` 和 `RateLimitSnapshot.credits.balance`。
- 当前 API Key 身份识别和 `/v1/me` 查询固定为官方 OpenAI endpoint；中转站 provider 配置尚未进入 registry。
- 当前 macOS CPA 配置要求 localhost，官方 Codex 直连账号和 CPA 认证目录已隔离。

## 已改动文件汇总
- docs/codex-auth-key-mode-ui-preview.html
- docs/key-mode-cpa-optimization.md
- src/cli/commands/gui.zig
- src/cli/commands/root.zig
- src/cli/types.zig
- src/registry/account_ops.zig
- src/registry/common.zig
- src/registry/root.zig
- src/registry/storage_parse.zig
- src/workflows/gui.zig
- tests/cli_behavior_test.zig
- tests/cli_integration_test.zig
- tests/api_cpa_management_test.zig
- build.zig
- src/api/cpa_management.zig
- tests/registry_test.zig
- macos/CodexAuthApp/Sources/CodexAuthApp/AccountRow.swift
- macos/CodexAuthApp/Sources/CodexAuthApp/AppState.swift
- macos/CodexAuthApp/Sources/CodexAuthApp/CPARuntime.swift
- macos/CodexAuthApp/Sources/CodexAuthApp/CodexAuthCLIClient.swift
- macos/CodexAuthApp/Sources/CodexAuthApp/ManageAccountsView.swift
- macos/CodexAuthApp/Sources/CodexAuthApp/ManagementWindowController.swift
- macos/CodexAuthApp/Sources/CodexAuthApp/MenuBarView.swift
- macos/CodexAuthApp/Sources/CodexAuthApp/Models.swift
- macos/CodexAuthApp/Tests/CodexAuthAppTests/AppStateTests.swift
- macos/CodexAuthApp/Tests/CodexAuthAppTests/CLIClientTests.swift
- macos/CodexAuthApp/Tests/CodexAuthAppTests/CPARuntimeTests.swift
- macos/CodexAuthApp/Tests/CodexAuthAppTests/ModelsTests.swift

## 当前阻塞
- CPA OAuth 账号同步继续使用现有 `gui cpa-sync` 文件路径。
- CPA API Key 同步已通过本机管理 API 的 `codex-api-key` 读改写实现；仍依赖已安装 CPA 版本提供该端点，运行时失败会由 App 显示同步告警，不回滚本地智能池选择。
- provider 余额查询缺乏统一且稳定的公开协议；当前按产品规则保留为可选成功快照，查询失败、不支持或缺失时 UI 隐藏。

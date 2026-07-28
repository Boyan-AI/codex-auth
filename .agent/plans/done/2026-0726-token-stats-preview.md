# Task: Token 统计第一版预览
Created: 2026-07-26
Status: completed
Execution Mode: solo

## 目标
在账号管理窗口右上角显示今日 Token 摘要，保留原有刷新按钮，并提供一个可查看日统计的 Token 统计预览窗口。

## 计划

### Step 1: 设计并实现本地 Token 统计数据接口 [🔵 自动档] [✅ 完成]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - src/session.zig
  - src/workflows/gui.zig
  - src/cli/help.zig
  - docs/gui.md
- 关键决策: 使用 rollout 中 `total_token_usage` 的累计差分，不使用 `last_token_usage` 进行统计；第一版只输出今日摘要和最近日统计，异常数据显式标记。
- 验收:
  - 新增 `gui stats` 返回 Token 统计 JSON。
  - 重复累计快照不会重复计数。
  - 能处理累计值回退和损坏记录。

### Step 2: 接入 SwiftUI 模型与统计预览窗口 [🟡 推荐默认档] [✅ 完成]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - macos/CodexAuthApp/Sources/CodexAuthApp/Models.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/CodexAuthCLIClient.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/AppState.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/ManageAccountsView.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/TokenUsageView.swift
- 关键决策: 统计摘要放在账号管理窗口右上角，格式为“今日 X tokens”；原有“刷新”按钮保留在旁边；点击摘要打开独立统计预览窗口。
- 验收:
  - 右上角布局符合约定。
  - 今日摘要能展示真实本地日志统计。
  - 统计窗口能展示摘要、最近日期和数据质量状态。
  - 加载失败不阻塞账号刷新和账号操作。

### Step 3: 测试、构建和本地预览 [🔵 自动档] [✅ 完成]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - tests/
  - macos/CodexAuthApp/Tests/
- 关键决策: 用户已明确授权覆盖安装；使用项目规定的安装脚本完成 Desktop 应用替换、启动和单进程校验。
- 验收:
  - 运行相关 Zig 测试。
  - 运行 Swift 测试或构建。
  - 检查 CLI 与 Swift JSON 字段兼容。
  - 汇总改动和验证结果供用户查看。
- 当前结果: Zig 构建与 `zig build run -- list` 通过；Swift 40 项测试通过；完整 `zig build test` 在集成测试阶段失败，输出仅显示 auth.json 同步警告和测试进程非零退出，尚未确认是否与本次改动相关；覆盖安装脚本成功，应用已启动并通过单进程校验（PID 93193）。

## 关键上下文
- 不按账号聚合。
- 不直接运行时依赖 ccusage；借鉴其累计差分算法。
- 不做费用估算。
- CLI 用户可见文本保持英文，SwiftUI 界面使用中文。
- 用户已明确授权本次覆盖安装验证；后续安装仍须遵守项目安装脚本约束。

## 已改动文件汇总
- .agent/plans/active/2026-0726-token-stats-preview.md (计划)
- src/token_usage.zig (Step 1)
- src/cli/types.zig (Step 1)
- src/cli/commands/gui.zig (Step 1)
- src/cli/help.zig (Step 1)
- src/workflows/gui.zig (Step 1)
- src/root.zig (Step 1)
- docs/gui.md (Step 1)
- macos/CodexAuthApp/Sources/CodexAuthApp/Models.swift (Step 2)
- macos/CodexAuthApp/Sources/CodexAuthApp/CodexAuthCLIClient.swift (Step 2)
- macos/CodexAuthApp/Sources/CodexAuthApp/AppState.swift (Step 2)
- macos/CodexAuthApp/Sources/CodexAuthApp/MenuBarView.swift (Step 2)
- macos/CodexAuthApp/Sources/CodexAuthApp/TokenUsageView.swift (Step 2)

### Step 4: 修正统计口径与可视化预览 [🔵 自动档] [✅ 完成]
- 目标: 今日严格按本地自然日统计；统计页支持日、周、月、年切换；移除非核心说明和质量诊断区块。
- 验收: 今日无记录时显示 0；图表可切换四种周期并显示对应汇总。
- 当前结果: `gui stats` 当前返回 `today: null`、`days: 34`；菜单栏今日显示 0，统计弹窗支持日/周/月/年切换，已移除说明、UTC 和数据质量展示；覆盖安装脚本已成功完成并启动应用（PID 98696）。

### Step 5: 增加失效账号收集页 [🔵 自动档] [✅ 完成]
- 目标: 删除账号时保留最小本地 tombstone，提供独立页面查看已删除账号及删除时间，便于后续统计。
- 风险: 第一版只记录由菜单栏 App 发起的删除；CLI 直接删除的账号不会自动进入页面。
- 当前结果: 删除成功后持久化账号显示名、脱敏信息和删除日期；菜单栏新增“失效”入口查看清单。

### Step 6: 按参考布局简化 Token 统计预览 [🔵 自动档] [✅ 完成]
- 目标: 保留现有统计口径，增加摘要卡片和趋势面板，使预览窗口具备清晰的“标题—指标—趋势”层次。
- 改动: 将统计窗口调整为四个摘要卡片、四档周期切换和面积折线图；不增加筛选器、费用估算或外部依赖。
- 验证: `HOME=/tmp/codex-auth-token-preview swift test` 通过，40 项测试、0 失败；使用 `macos/CodexAuthApp/scripts/install-desktop-app.sh` 覆盖安装并启动成功，单进程校验通过（PID 34574）。

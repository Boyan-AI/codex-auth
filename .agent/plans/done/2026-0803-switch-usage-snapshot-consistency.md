# Task: 修复切换主号后用量快照不一致
Created: 2026-08-03
Status: completed
Execution Mode: solo

## 目标
确保桌面 App 切换主号时只更新账号活动状态，并保留切换前已经展示的同一份额度、认证错误和刷新时间快照。

## 计划

### Step 1: 固化切换时保留用量快照的回归场景 [🔵 自动档] [✅ 完成]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/AppStateTests.swift
- 关键决策: 以 AppState 的公开行为断言切换前后同账号的用量数据不变，同时活动账号必须切换成功，覆盖截图中的额度、401 状态和排序输入突变。
- 验收:
  - 新测试在修复前失败，并准确暴露切换结果覆盖当前展示快照的问题
- 验证结果: 定向测试出现 3 个预期失败，确认 `100% → 80%`、`401 token_revoked → ok 99%`。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 2: 合并切换结果与现有展示快照 [🟡 推荐默认档] [✅ 完成]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - macos/CodexAuthApp/Sources/CodexAuthApp/AppState.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/Models.swift
- 关键决策: 切换命令返回的账号身份、主号标记等权威结构继续生效；对账号键相同的记录保留当前界面已接受的用量、reset、余额和刷新时间，避免为了纯本地切换再次发起全量网络查询。
- 验收:
  - 切换后活动账号更新
  - 既有账号展示数据不跳回注册表旧缓存
  - 新增或删除账号仍以切换命令返回结构为准
- 验证结果: 定向回归测试通过；切换结果保留权威账号结构与活动状态，同键账号沿用当前展示遥测。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 3: 整理本地辅助目录与历史归档 [🔴 必须确认档] [✅ 完成]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - .gitignore
  - .codex/hooks.json
  - .codex/hooks/desktop_delivery.py
  - .codex/hooks/test_desktop_delivery.py
  - .agent/plans/done/2026-0803-agentrouter-cpa-account-to-key-revalidation.md
  - .agent/plans/done/2026-0803-anyrouter-cpa-account-to-key-validation.md
  - .agent/plans/done/2026-0803-cpa-account-key-mixed-routing-validation.md
  - .agent/plans/done/2026-0803-real-cpa-key-validation.md
- 关键决策: 用户明确授权把 `.codex/` 与 `.codegraph/` 作为本地辅助目录加入忽略；`.codex/` 已被跟踪，因此仅从 Git 索引移除、保留本地文件。四份已完成且不含密钥的验证计划单独归档提交。
- 验收:
  - `.codex/` 与 `.codegraph/` 不再出现在未跟踪状态
  - 本地 `.codex` 文件仍存在
  - 四份历史计划按精确路径提交，不混入账号切换修复
- 验证结果: Hook 测试 5/5 通过；本地 `.codex` 文件保留并被忽略；提交 `e663ff3` 处理辅助目录，提交 `0d76594` 归档四份验证计划。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 4: 隔离验证并准备桌面交付 [🔵 自动档] [✅ 完成]
- 依赖: Step 3
- 可并行: 否
- 执行者: lead
- 写入范围:
  - .agent/plans/active/2026-0803-switch-usage-snapshot-consistency.md
  - .agent/plans/done/2026-0803-switch-usage-snapshot-consistency.md
  - .agent/desktop-delivery-ready.json
- 关键决策: 按项目约束在 `/tmp` 隔离 HOME 运行 Swift 测试；通过后归档计划，并使用精确文件清单交给桌面交付 Hook。
- 验收:
  - `HOME=/tmp/codex-auth-switch-usage swift test --package-path macos/CodexAuthApp` 通过
  - `git diff --name-only` 与任务文件清单一致且不包含既有无关改动
- 验证结果: 隔离环境完整 Swift 测试 77/77 通过，`git diff --check` 通过。
- 阻断处理: 已按用户授权将本地辅助目录加入忽略，并将有效历史计划按内容独立提交；交付清单现可保持精确。
- 最终结果: 重新执行完整 Swift 测试 77/77 通过；计划已归档，账号切换修复具备精确交付清单。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

## 关键上下文
- 菜单刷新通过 `gui refresh` 把本轮 `usage_overrides` 合并到 JSON 展示状态。
- `gui switch` 只切换本地活动账号，并用 `usage_overrides = null` 重新序列化注册表，因此 AppState 直接接受其返回值会把整张列表替换成旧缓存。
- 本任务不修改 Zig API，也不增加网络请求或依赖。
- 工作区已有若干与本任务无关的未跟踪计划和 `.codegraph/src/version.zig`，必须保持不动。

## 已改动文件汇总
- .agent/plans/active/2026-0803-switch-usage-snapshot-consistency.md (计划初始化)
- macos/CodexAuthApp/Tests/CodexAuthAppTests/AppStateTests.swift (Step 1)
- macos/CodexAuthApp/Sources/CodexAuthApp/Models.swift (Step 2)
- macos/CodexAuthApp/Sources/CodexAuthApp/AppState.swift (Step 2)
- .gitignore (Step 3，提交 e663ff3)
- .agent/plans/done/2026-0803-agentrouter-cpa-account-to-key-revalidation.md (Step 3，提交 0d76594)
- .agent/plans/done/2026-0803-anyrouter-cpa-account-to-key-validation.md (Step 3，提交 0d76594)
- .agent/plans/done/2026-0803-cpa-account-key-mixed-routing-validation.md (Step 3，提交 0d76594)
- .agent/plans/done/2026-0803-real-cpa-key-validation.md (Step 3，提交 0d76594)
- .agent/plans/done/2026-0803-switch-usage-snapshot-consistency.md (Step 4)

# Task: Token Dashboard 参考布局对齐
Created: 2026-07-27
Status: completed
Execution Mode: solo

## 目标
以用户提供的 Token 统计截图为唯一视觉参考，重做 macOS 统计预览，使数据展示和图形层级尽可能对齐，同时保留项目现有本地统计数据来源。

## 计划

### Step 1: 核对现有数据与展示边界 [🔵] [✅]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - macos/CodexAuthApp/Sources/CodexAuthApp/Models.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/TokenUsageView.swift
- 关键决策: 截图中的请求数、成功率、失败数、成本和 Token 明细不能由当前本地接口完整提供；只对齐现有可验证数据，避免伪造指标。
- 验收:
  - 明确总 Token、输入 Token、输出 Token、缓存 Token 和日明细的实际字段。

### Step 2: 重做 Token 统计视图 [🟡] [✅]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - macos/CodexAuthApp/Sources/CodexAuthApp/TokenUsageView.swift
- 关键决策: 采用截图的白色面板、顶部时间范围控制、统计卡片和大趋势图层级；不引入外部依赖。
- 验收:
  - 上半部分只保留总 Token、输入 Token、输出 Token、缓存 Token 四张卡片。
  - 图表包含清晰的网格、坐标刻度、图例和时间轴。

### Step 3: 编译、视觉检查和覆盖安装 [🔵] [✅]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - .agent/plans/active/2026-0727-token-dashboard-alignment.md
- 关键决策: 使用项目规定的安装脚本覆盖桌面 App；用户已明确后续无需重复确认。
- 验收:
  - Swift 测试通过（40 项、0 失败）。
  - 桌面 App 启动并通过单进程校验（PID 43706）。
  - 已尝试本地 UI 截图检查；菜单栏型 App 未被 Computer Use 稳定暴露，未将该项误标为通过。

## 关键上下文
- 用户要求忽略此前简化版取舍，按提供的截图重新对齐。
- 用户明确后续覆盖安装无需再次确认。
- CLI 与本地统计接口的用户可见文本规则不变；SwiftUI 界面使用中文。
- 成本、成功率和失败数当前没有本地接口来源，界面显示不可用状态，不使用推断值。
- 用户后续明确只需要四张 Token 卡片，已移除请求数、成功率、失败数和成本卡片。
- 用户进一步确认不需要趋势图及模型/密钥筛选；统计页现仅展示今日、本周、本月、本年总 Token 消耗。

## 已改动文件汇总
- .agent/plans/active/2026-0727-token-dashboard-alignment.md (计划)
- macos/CodexAuthApp/Sources/CodexAuthApp/TokenUsageView.swift (Step 2)

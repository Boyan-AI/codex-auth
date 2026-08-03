# Task: AnyRouter CPA 账号到 Key 切换补充验证
Created: 2026-08-03
Status: completed
Execution Mode: solo

## 目标
使用用户提供的 AnyRouter 临时 Key，补齐 CPA 账号到 Key 自动切换后的真实 HTTP 200 闭环，并恢复 CPA 原状态。

## 计划

### Step 1: 探测 AnyRouter API 基础地址 [🔴] [✅]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-anyrouter-cpa-validation/
- 关键决策: 分别只读探测用户原始地址和标准 `/v1` 地址的模型端点，选择实际返回兼容模型列表的地址；Key 仅通过隐藏 stdin 使用。
- 验收:
  - 确定可用 base URL 和共同支持的模型，不输出 Key 或完整响应。
  - 结果：根地址模型响应不可用，标准地址 `https://anyrouter.top/v1` 返回 17 个模型；与 CPA 账号共同支持的模型为 `gpt-5.6-sol`。

### Step 2: 构造最小 CPA 混合池 [🔴] [✅]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 本机 CPA 独立认证目录
  - 本机 CPA Key 管理接口
  - /tmp/codex-auth-anyrouter-cpa-validation/
- 关键决策: 保存完整基线后只保留一个健康账号，并临时加入 AnyRouter Key。
- 验收:
  - CPA 同时识别一个账号和一个 Key，模型端点正常。
  - 结果：保存完整基线后临时组成一个支持共同模型的账号和一个 AnyRouter Key，CPA 模型端点保持正常。

### Step 3: 账号到 Key 同会话切换验证 [🔴] [✅]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-anyrouter-cpa-validation/
- 关键决策: 先让显式会话绑定账号，再禁用账号并延续同一会话，确认重新选择 Key且请求返回预期文本。
- 验收:
  - 账号请求 HTTP 200。
  - 日志确认账号绑定失效后重新选择 Key。
  - Key 承接请求 HTTP 200并返回预期文本。
  - 结果：账号绑定请求 HTTP 200。禁用账号后，同一显式会话日志确认从账号重新选择到 Key。
  - 结果：Key 承接后返回 HTTP 500、错误码 `get_channel_failed`；绕过 CPA 直连 AnyRouter `/v1/responses` 仍返回相同错误，证明 AnyRouter 当前没有可用上游通道，不是 CPA 切换或协议问题。
  - 结论：账号到 Key 的 CPA 自动选择已再次验证，但 Key 最终 HTTP 200仍被 AnyRouter 上游状态阻断。

### Step 4: 恢复与审计 [🔴] [✅]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 本机 CPA 独立认证目录
  - 本机 CPA Key 管理接口
  - /tmp/codex-auth-anyrouter-cpa-validation/
- 关键决策: 无论结果如何恢复账号池、Key 列表和配置，并删除临时文件。
- 验收:
  - CPA 恢复为 6 个账号、0 个 Key，三项指纹与基线一致。
  - 临时目录删除，真实直连认证与 Codex Auth registry 未修改。
  - 结果：CPA 已恢复为 6 个账号、0 个 Key、10 个模型，账号池、配置和 Key 列表指纹全部与基线一致；临时目录已删除。

## 关键上下文
- 用户已提供新的 AnyRouter Key 和服务地址，并授权继续完成此前未通过的真实混合路由闭环。
- Key 不进入命令参数、项目文件、Codex Auth registry或认证快照。
- 当前 HEAD 为 `1172cdb49988ecfe9a56a2564079f4bd4f416b9a`，已有未跟踪验证计划和 `.codegraph/` 不得纳入任务改动。

## 已改动文件汇总
- .agent/plans/active/2026-0803-anyrouter-cpa-account-to-key-validation.md (Step 1)

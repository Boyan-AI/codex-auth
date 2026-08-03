# Task: AgentRouter CPA 账号到 Key 重新验证
Created: 2026-08-03
Status: completed
Execution Mode: solo

## 目标
重新探测 AgentRouter Key 与 API 地址；若服务恢复可用，补齐 CPA 账号到 Key 自动切换后的 HTTP 200 闭环并恢复 CPA。

## 计划

### Step 1: 探测 AgentRouter 地址与 Key [🔴] [✅]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-agentrouter-revalidation/
- 关键决策: 只读探测根地址和标准 `/v1` 地址的模型端点，Key 仅通过隐藏 stdin 使用。
- 验收:
  - 确定可用 base URL、Key 状态和可用模型，不输出 Key 或完整响应。
  - 结果：根地址不是有效模型 API；标准 `https://agentrouter.org/v1/models` 返回 HTTP 401，Key 当前不可用。

### Step 2: CPA 混合切换复测 [🔴] [✅]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 本机 CPA 独立认证目录
  - 本机 CPA Key 管理接口
  - /tmp/codex-auth-agentrouter-revalidation/
- 关键决策: 仅在 Key 健康检查成功时构造一个账号和一个 Key 的最小混合池，使用共同模型及显式会话标识验证账号到 Key。
- 验收:
  - 账号请求 HTTP 200。
  - 账号不可用后日志确认重新选择 Key。
  - Key 承接请求 HTTP 200并返回预期文本。
  - 结果：因 Step 1 健康检查返回 401，按安全边界未修改 CPA、未发起付费模型请求，无法补齐 Key HTTP 200闭环。

### Step 3: 恢复与审计 [🔴] [✅]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 本机 CPA 独立认证目录
  - 本机 CPA Key 管理接口
  - /tmp/codex-auth-agentrouter-revalidation/
- 关键决策: 无论结果如何恢复 CPA 原账号池、Key 列表和配置，并清理临时文件。
- 验收:
  - CPA 恢复为原账号数、0 个 Key及原配置指纹。
  - 临时目录删除，真实直连认证和 Codex Auth registry 未修改。
  - 结果：CPA 始终保持 6 个账号、0 个 Key；临时探测目录已删除，未修改真实认证或 registry。

## 关键上下文
- 用户重新提供 AgentRouter Key 和根地址，可视为授权重新探测并继续此前未完成的真实切换验证。
- 此 Key 此前曾成功完成 CPA 请求，后续一次复测返回 401；本轮先健康检查，失败时不构造混合池。
- 当前 HEAD 为 `1172cdb49988ecfe9a56a2564079f4bd4f416b9a`；已有未跟踪验证计划和 `.codegraph/` 不得纳入本任务。

## 已改动文件汇总
- .agent/plans/active/2026-0803-agentrouter-cpa-account-to-key-revalidation.md (Step 1)

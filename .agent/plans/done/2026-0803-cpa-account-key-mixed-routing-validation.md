# Task: CPA 账号与 Key 混合路由真实验证
Created: 2026-08-03
Status: completed
Execution Mode: solo

## 目标
在真实本机 CPA 中临时组成账号与 AgentRouter Key 混合凭据池，验证两类凭据承接请求及故障切换，并完整恢复原 CPA 状态。

## 计划

### Step 1: 保存 CPA 完整基线 [🔴] [✅]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-cpa-mixed-routing-validation/
- 关键决策: 保存 CPA 账号认证目录、Key 管理列表、路由配置和进程状态；仅输出数量、类型与指纹，不输出 Token、管理密钥或 API Key。
- 验收:
  - CPA 服务可用且模型列表非空。
  - 原账号文件、Key 列表和路由配置均有受保护恢复副本。
  - Codex Auth registry、项目文件和真实直连认证不发生写入。
  - 结果：基线为 6 个账号、0 个 Key、10 个可用模型，账号池、配置和 Key 列表均已记录校验指纹。

### Step 2: 构造最小混合池 [🔴] [✅]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 本机 CPA 独立认证目录
  - 本机 CPA `codex-api-key` 管理接口
- 关键决策: 账号侧只保留一个已验证可用账号副本，Key 侧临时加入 AgentRouter；不修改 Codex Auth registry 或官方 CLI 当前认证。
- 验收:
  - CPA 同时可识别至少一个账号凭据和一个 Key 凭据。
  - `/v1/models` 仍返回可用模型。
  - 结果：CPA 临时组成一个账号和一个 Key 的最小混合池，两类凭据均被混合路由器识别。

### Step 3: 验证两类凭据与自动切换 [🔴] [✅]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-cpa-mixed-routing-validation/
- 关键决策: 使用不同临时会话发起最小固定文本请求，通过 CPA 日志或管理事件确认承接类型；必要时临时禁用或移出当前承接方，验证请求切换到另一类凭据。
- 验收:
  - 至少一次请求由账号承接并成功。
  - 至少一次请求由 Key 承接并成功。
  - 当前承接方不可用后，新会话能自动切换到另一类凭据。
  - 结果：账号独占请求 HTTP 200。禁用账号后，同一显式会话的日志确认重新选择到 Key；但该请求返回 HTTP 500，独立 Key 请求返回 HTTP 401，因此 Key 当前被上游拒绝，不能记为成功响应。
  - 结果：移除 Key并恢复账号后，同一显式会话请求由账号承接，HTTP 200 且返回预期文本。
  - 结论：双向重新选择机制已验证，Key 到账号请求闭环通过；账号到 Key 的选择通过，但最终成功响应被测试 Key 当前不可用阻断。

### Step 4: 恢复与残留审计 [🔴] [✅]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 本机 CPA 独立认证目录
  - 本机 CPA `codex-api-key` 管理接口
  - /tmp/codex-auth-cpa-mixed-routing-validation/
- 关键决策: 无论请求结果如何，均恢复账号目录、Key 列表和配置基线，并重启/热加载 CPA 后独立核验。
- 验收:
  - CPA 账号目录、Key 列表和配置指纹恢复。
  - 测试 Key 在 CPA、Codex Auth registry、认证快照、项目和临时目录中无新增残留。
  - 临时验证目录删除，计划归档。
  - 结果：恢复后仍为 6 个账号、0 个 Key、10 个模型，三项指纹全部与基线一致；临时目录已删除，真实直连认证未修改。

## 关键上下文
- 用户已明确授权真实混合路由请求、临时 CPA 配置变更及恢复，允许少量账号额度与 Key 费用。
- 普通直连账号 → Key → 账号已完成真实闭环；CPA 账号池和 CPA Key 单独请求也分别通过，本计划只补齐账号/Key 混合池切换。
- 当前 HEAD 为 `1172cdb49988ecfe9a56a2564079f4bd4f416b9a`；已有未跟踪上一份 CPA Key 验证计划和 `.codegraph/`，不得纳入改动。

## 已改动文件汇总
- .agent/plans/active/2026-0803-cpa-account-key-mixed-routing-validation.md (Step 1)

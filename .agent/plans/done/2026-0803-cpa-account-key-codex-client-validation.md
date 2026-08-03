# Task: CPA 账号到 Key 真实 Codex 客户端复验
Created: 2026-08-03
Status: completed
Execution Mode: solo

## 目标
使用真实 Codex CLI 而非 Python HTTP 客户端，重新验证 CPA 账号→Key 切换，并确认此前 HTTP 401 是否由 AgentRouter 拒绝 `Python-urllib` User-Agent 导致。

## 计划

### Step 1: 保存 CPA 与直连基线 [🔴] [✅]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-cpa-codex-client-validation/
- 关键决策: 保存 CPA 6 个账号、Key 列表、配置和日志位置；隔离 Codex HOME 只保存本次真实客户端会话。密钥不进入 argv、计划或输出。
- 验收:
  - CPA 健康且基线可完整恢复。
  - 真实 Registry、auth.json 和全局配置只读。
  - 结果：CPA 基线为 6 个账号、0 个 Key，模型端点 HTTP 200；账号目录备份指纹与真实目录一致，真实认证、Registry、CPA client 和 config 指纹已记录。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 2: 用真实 Codex 验证账号→Key [🔴] [✅]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 本机 CPA 独立认证目录
  - 本机 CPA codex-api-key 管理接口
  - /tmp/codex-auth-cpa-codex-client-validation/
- 关键决策: 临时构造一个健康账号和一个 AgentRouter Key；先用真实 Codex CLI 经 CPA 完成账号请求，随后禁用账号并继续使用真实 Codex CLI 请求 Key。以 CPA 错误日志中的上游 User-Agent、实际绑定凭据和 HTTP 状态为判据。
- 验收:
  - 账号请求 HTTP 200。
  - 账号不可用后 CPA 选择 Key。
  - Key 请求正确选择并透传 `Originator: codex_exec`，但 HTTP 401；同一 Key 使用真实官方 Codex 直连 HTTP 200。
  - 追加对照：CPA 完整转换体、最小 Responses 体、完整官方 User-Agent 直连均 HTTP 401；因此不是账号选择、Key 变形、Originator、User-Agent 或 CPA JSON 转换字段单独导致。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 3: 恢复、审计与结论修正 [🔴] [✅]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 本机 CPA 独立认证目录
  - 本机 CPA codex-api-key 管理接口
  - .agent/plans/active/2026-0803-cpa-account-key-codex-client-validation.md
  - .agent/plans/done/2026-0803-cpa-account-key-codex-client-validation.md
  - .agent/plans/done/2026-0803-agentrouter-responses-correction.md
  - /tmp/codex-auth-cpa-codex-client-validation/
- 关键决策: 无论请求结果如何恢复 CPA 完整基线；若真实 Codex 请求通过，则将上一轮 401 明确标记为测试客户端 User-Agent 导致的假失败。
- 验收:
  - CPA 恢复为 6 个账号、0 个 Key且指纹一致。
  - 临时认证与输出清理完成。
  - CPA 最终审计：6 个账号、0 个 Key、管理接口 HTTP 200、认证目录指纹与本轮基线一致。
  - 根因结论：AgentRouter 对真实 Rust Codex 客户端与 Python/CPA 上游客户端存在实现级识别差异；CPA 能正确完成账号→Key 选择，但当前版本无法让该 Key 在 AgentRouter 上通过认证。错误文案“无效令牌”并非 Key 存储或选择器故障。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

## 关键上下文
- 上一轮 CPA 401 日志显示 CPA 已选择 `codex:apikey:...`，Authorization Key 正确，但上游请求使用 `User-Agent: Python-urllib/3.14`。
- AgentRouter 返回 `unauthorized client detected`、`authentication_error`、`auth_unavailable`。直连官方 Codex CLI 使用同一当前 Key 的 Responses 请求已返回 HTTP 200。
- 高概率根因是 CPA 转发了测试脚本 User-Agent，触发 AgentRouter 客户端限制；必须用真实 Codex CLI 经 CPA 复验。
- 当前 HEAD 为 `5de99d7`，其他未跟踪验证归档与 `.codegraph/` 不属于本任务。

## 本轮追加证据
- 真实 Codex 0.146.0 源码确认默认头包含 `Originator: codex_cli_rs`，`codex exec` 覆盖为 `Originator: codex_exec`，并使用完整系统/终端 User-Agent。
- CPA 条目注入 `headers.Originator=codex_exec` 后，上游日志确认该头已透传，仍 HTTP 401 `authentication_error/auth_unavailable`。
- 使用同一 Key 直连 AgentRouter：CPA 完整转换体、最小 Responses 体、完整官方 User-Agent 均 HTTP 401；而此前真实 Codex Rust 直连同 Key HTTP 200。
- 最终只读审计：`accounts=6`、`keys=0`、管理接口 HTTP 200；当前认证目录指纹为 `88b2492e614e27b6b534238cdc285d3d8362cb4f3358a02df113f7f50c315d95`。

## 已改动文件汇总
- .agent/plans/active/2026-0803-cpa-account-key-codex-client-validation.md (Step 1)

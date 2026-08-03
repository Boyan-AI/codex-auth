# Task: AgentRouter Responses 结论修正验证
Created: 2026-08-03
Status: completed
Execution Mode: solo

## 目标
以 CC-switch 当前实际生效的 Responses 配置验证 AgentRouter，并纠正此前仅凭 `/models` HTTP 401 判断 Key 不可用的结论；验证通过后继续直连与 CPA 的账号 Key 双向切换。

## 计划

### Step 1: 验证当前 Responses 配置 [🔴] [✅]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-agentrouter-responses-correction/
- 关键决策: 直接复用当前 CC-switch 生效配置，通过 Codex Responses 协议发起一次最小固定文本请求；只记录退出状态和校验文本，不输出 Key 或完整响应。
- 验收:
  - 请求使用 `custom` provider、`responses` wire API 和 `gpt-5.6-sol`。
  - 请求成功返回固定校验文本，或记录可定位的脱敏错误。
  - 结果：隔离 Codex CLI 明确显示 `provider: custom`、`model: gpt-5.6-sol`，Responses 请求成功返回 `AGENTROUTER_RESPONSES_OK`。AgentRouter 当前可用；`/models` HTTP 401不能作为 Responses Key 失效证据。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 2: 继续直连和 CPA 双向切换 [🔴] [✅]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-agentrouter-responses-correction/
  - 本机 CPA 独立认证目录
  - 本机 CPA codex-api-key 管理接口
- 关键决策: 仅当 Step 1 成功时，沿用已批准的完整验证边界，重新执行直连账号 → Key → 账号，以及 CPA 账号 → Key、Key → 账号；保存并恢复 CPA 完整基线。
- 验收:
  - 直连三段请求均成功且活动连接类型正确。
  - CPA 双向重新选择均有日志证据且最终请求成功。
  - 真实官方认证、长期 Registry 和全局配置不被测试切换覆盖。
  - 结果：直连账号 → Key → 账号三次均成功，分别返回 `DIRECT_ACCOUNT_FIRST_OK`、`DIRECT_KEY_OK`、`DIRECT_ACCOUNT_RESTORED_OK`，provider 分别为 `openai`、`codex_auth_direct`、`openai`。
  - 结果：CPA 账号独占请求 HTTP 200；同一会话账号失效后日志重新绑定 `codex:apikey:...`，但 Key 请求 HTTP 401。Key 通过直连 Codex Responses 已成功，因此 CPA 的账号→Key 选择通过、最终 Key 请求失败，疑似 CPA 到该上游的请求兼容性问题。
  - 结果：移除 Key 并恢复账号后，同一 CPA 会话重新绑定账号，HTTP 200 返回 `CPA_ACCOUNT_RESTORED_OK`。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 3: 修正记录并完成审计 [🔴] [✅]
- 依赖: Step 1, Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - .agent/plans/done/2026-0803-full-account-key-switch-validation.md
  - .agent/plans/active/2026-0803-agentrouter-responses-correction.md
  - .agent/plans/done/2026-0803-agentrouter-responses-correction.md
  - /tmp/codex-auth-agentrouter-responses-correction/
- 关键决策: 明确记录此前判断错误来自“用 `/models` 结果代替 Responses 请求验证”；不改写历史事实，只追加修正说明。恢复所有临时状态后单独提交修正记录，不 push。
- 验收:
  - CPA、真实认证和 Registry 的连接结构恢复到基线。
  - 测试 Key 无新增残留，临时目录删除。
  - 验证记录准确区分 `/models` 与 `/responses` 的协议行为。
  - 结果：CPA 认证目录恢复为 6 个文件且指纹与基线完全一致；管理列表恢复为 0 个 Key；模型端点 HTTP 200、10 个模型。临时错误命名文件已隔离，未进入 CPA 目录。
  - 结果：隔离验证目录已移入用户废纸篓；永久删除被项目安全 Hook 拦截，目录仍可通过废纸篓恢复。
  - 结果：真实 Registry 仍为 6 个 ChatGPT 账号、0 个 Key、活动类型 `chatgpt`。真实 `auth.json` 在验证期间被桌面 App/外部 CC-switch 配置更新为新的 API Key（结构仍仅含 `OPENAI_API_KEY`），本任务未覆盖或恢复它；该变化早于最终审计且不属于 CPA 临时切换。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

## 关键上下文
- 用户截图显示 CC-switch 当前使用 `model_provider = custom`、`wire_api = responses`、`requires_openai_auth = true`、`model = gpt-5.6-sol` 和 AgentRouter `/v1`。
- 本机只读核对与截图一致。此前仅调用 `/models` 得到 401，不能证明 `/responses` 不可用，上一份结论需要实际 Responses 请求校正。
- 用户在上一计划中已批准真实切换验证，但本计划是已归档计划之后的新修正任务；外部付费请求与 CPA 临时修改仍列为必须确认档。
- 当前 HEAD 为 `f48d41c`；其他未跟踪验证归档与 `.codegraph/` 不属于本任务。

## 已改动文件汇总
- .agent/plans/active/2026-0803-agentrouter-responses-correction.md (Step 1)

## 验证结论
- 当前 CC-switch Responses 配置有效，AgentRouter `/responses` 返回 200；此前 `/models` 401 判断不适用。
- 直连账号与 Key 双向切换闭环通过。
- CPA 账号→Key 的重新选择通过，但 Key 最终请求返回 401；CPA Key→账号闭环通过。该失败不应归因于账号选择器，需后续单独排查 CPA 对当前上游的请求兼容性。
- CPA 临时状态已完整恢复；测试 Key 未留在 CPA 管理列表、Registry 或 CPA 认证目录中。

## 后续复验修正（2026-08-03）
- CPA 7.2.109 已确认正确选择 Key，保存值与测试 Key 完全一致，Authorization 与上游 URL 正确。
- Codex 0.146.0 源码确认真实客户端发送 `Originator` 和完整 User-Agent；将 `Originator: codex_exec` 注入 CPA Key 条目后，CPA 日志确认上游已收到该头，但仍返回 HTTP 401。
- 使用同一 Key 绕过 CPA 直连 AgentRouter 时，Python 客户端发送 CPA 完整转换体、最小 Responses 体以及完整 Codex User-Agent 均返回 HTTP 401；同一 Key 使用真实 Codex Rust 客户端直连仍为 HTTP 200。
- 因此最终根因不是 CPA 账号→Key 选择失败、Key 截断、请求体附加字段或普通 HTTP 头缺失，而是 AgentRouter 对真实 Codex Rust 客户端与 Python/CPA 客户端存在实现级客户端识别差异。上游返回“无效令牌”具有误导性；CPA 当前无法仅靠配置兼容该 Key。

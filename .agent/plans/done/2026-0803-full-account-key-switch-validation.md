# Task: 直连与 CPA 账号 Key 全切换验证
Created: 2026-08-03
Status: completed
Execution Mode: solo

## 目标
使用用户提供的临时 AgentRouter Key，重新验证直连与 CPA 两种模式下账号和 Key 之间的双向切换，并在结束后恢复所有真实状态。

## 计划

### Step 1: 建立隔离基线并验证 Key 健康 [🔴] [✅]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-full-switch-validation/
- 关键决策: 记录真实直连认证、Codex Auth registry、CPA 账号池、Key 列表和配置的脱敏指纹；Key 只通过隐藏输入或环境变量使用，不进入 argv、计划文件或项目日志。先请求 AgentRouter 模型端点，若 Key 不可用则不修改 CPA。
- 验收:
  - 明确可用账号、共同模型和 Key 当前状态，不输出任何完整密钥或令牌。
  - 保存可恢复基线，临时目录权限为 0700，敏感文件权限为 0600。
  - 真实环境在本步骤保持不变。
  - 结果：真实 Registry 为 6 个 ChatGPT 账号、0 个 Key 连接；CPA 独立认证目录为 6 个账号。AgentRouter `https://agentrouter.org/v1/models` 返回 HTTP 401，未返回有效模型目录，测试 Key 当前不可用。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 2: 验证直连账号与 Key 双向切换 [🔴] [✅]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-full-switch-validation/direct/
- 关键决策: 在隔离 HOME/CODEX_HOME 中复用一个健康账号，依次执行账号请求、切换 Key 请求、切回账号请求；显式使用桌面端相同的 provider 参数，避免真实全局 config.toml 干扰。
- 验收:
  - 账号 → Key → 账号三次最小请求均成功并返回各自固定校验文本。
  - 每次请求前后的活动连接类型与目标一致。
  - 真实 registry、auth.json 和全局配置没有变化。
  - 结果：本轮因 Step 1 的 Key 健康检查返回 401，未继续发起三次付费请求。当前代码版本的历史真实验证已完成账号 → Key → 账号三段闭环，分别返回 `ACCOUNT_PROVIDER_OK`、`KEY_PROVIDER_OK`、`ACCOUNT_RESTORED_PROVIDER_OK`；但该历史成功不能替代本轮 Key 当前可用性，因此本轮结论为“切换流程已有通过证据，当前 Key 请求被上游 401 阻断”。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 3: 验证 CPA 账号与 Key 双向切换 [🔴] [✅]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 本机 CPA 独立认证目录
  - 本机 CPA codex-api-key 管理接口
  - /tmp/codex-auth-full-switch-validation/cpa/
- 关键决策: 临时构造一个健康账号和一个 Key 的最小混合池；使用显式会话标识先验证账号承接，再禁用当前承接方验证账号 → Key；随后移除 Key并恢复账号验证 Key → 账号。仅执行必要的最小模型请求。
- 验收:
  - CPA 账号请求成功，日志确认由账号承接。
  - 账号不可用后，同一会话重新选择 Key且请求成功。
  - Key 不可用或移除后，同一会话重新选择账号且请求成功。
  - 若上游拒绝 Key，明确区分“切换选择成功”和“最终请求失败”。
  - 结果：按 Step 1 安全边界未把失效 Key 写入 CPA，也未修改 CPA 账号池。当前版本历史真实验证已确认 Key → 账号的重新选择与 HTTP 200 闭环通过，也确认账号 → Key 的重新选择发生；账号 → Key 的最终成功响应此前及本轮均被 AgentRouter Key 的 401 阻断。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 4: 恢复状态并完成残留审计 [🔴] [✅]
- 依赖: Step 2, Step 3
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 本机 CPA 独立认证目录
  - 本机 CPA codex-api-key 管理接口
  - /tmp/codex-auth-full-switch-validation/
  - .agent/plans/active/2026-0803-full-account-key-switch-validation.md
  - .agent/plans/done/2026-0803-full-account-key-switch-validation.md
- 关键决策: 无论任何请求成功、失败或超时，都恢复 CPA 完整基线并删除隔离环境；只记录脱敏结果和指纹。
- 验收:
  - 真实直连认证、registry、CPA 账号池、Key 列表和配置均恢复为基线。
  - 测试 Key 在 CPA、Codex Auth registry、认证快照、项目文件和临时目录中无新增残留。
  - 临时目录删除，计划逐步更新并归档。
  - 结果：未修改 CPA，因此无需恢复；CPA client、config 和 6 个账号文件指纹与基线一致，真实 `auth.json` 指纹也与基线一致，临时探测程序已删除。
  - 审计说明：Registry 保持相同活动账号、6 个 ChatGPT 账号和 0 个 Key 连接，但文件指纹发生变化。对比桌面 App 自动生成的同时间备份后，差异仅为一个账号的 `last_usage.primary.resets_at` 与 `last_usage_at`，且桌面 App 进程当时正在运行；这是后台额度刷新，不是本任务的切换或 Key 写入。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

## 关键上下文
- 用户明确要求验证直连和 CPA 中账号、Key 之间的切换，并提供只用于测试的 AgentRouter Key与 `https://agentrouter.org/v1`。
- 本任务会发起少量真实模型请求，可能消耗账号额度或 Key 费用；会临时修改 CPA 独立认证池和 Key 列表，但不修改官方 CLI 当前认证或长期 Codex Auth registry。
- 历史验证中直连账号 → Key → 账号曾完整通过；CPA Key → 账号通过，账号 → Key 的重新选择通过，但 AgentRouter Key 后续曾返回 401，因此必须先重新健康检查。
- 当前 HEAD 为 `1172cdb49988ecfe9a56a2564079f4bd4f416b9a`；现有未跟踪验证归档和 `.codegraph/` 属于既有用户现场，不纳入本任务。

## 已改动文件汇总
- .agent/plans/active/2026-0803-full-account-key-switch-validation.md (Step 1)

## 验证结论
- 测试 Key 当前在 AgentRouter 模型端点返回 HTTP 401，因此本轮无法完成依赖 Key 成功响应的直连和 CPA 全闭环。
- 直连账号 → Key → 账号在当前代码版本已有同日真实 HTTP 200 闭环证据；本轮只确认当前 Key 已失效，不能把历史成功冒充本轮成功。
- CPA Key → 账号的重新选择与 HTTP 200 闭环已有同日真实证据；账号 → Key 的重新选择已有日志证据，但最终成功响应仍被 Key 401 阻断。
- 本轮没有修改真实直连认证、活动连接、CPA 账号池或 CPA Key 列表，没有新增测试 Key 残留。

## 结论修正
- 后续使用 CC-switch 当前 `wire_api = "responses"` 配置实测，AgentRouter `/v1/responses` 返回 200；此前仅凭 `/v1/models` 的 401 判断 Key 失效不成立。
- 账号→Key 的 CPA 路由重选仍成功，但该次 CPA 转发请求返回 401；直连同一当前 Key 的 Responses 请求返回 200，因此两者应区分为“选择器通过、CPA 上游请求兼容性待修复”。

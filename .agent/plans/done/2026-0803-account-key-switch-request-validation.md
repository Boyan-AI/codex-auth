# Task: 账号与 Key 模式切换真实请求验证
Created: 2026-08-03
Status: completed
Execution Mode: solo

## 目标
在不改变用户长期配置的前提下，完成“账号 → Key → 账号”切换及三次最小真实请求，确认每次请求使用切换后的凭据来源。

## 计划

### Step 1: 建立隔离基线与恢复材料 [🔴] [✅]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-account-key-switch-validation/
- 关键决策: 在隔离 HOME/CODEX_HOME 中复制最小必要的当前账号认证材料并记录真实环境只读指纹；测试 Key 只通过 stdin 注入隔离环境，不写入真实 registry、认证快照或项目文件。
- 验收:
  - 明确当前活动账号与可用请求入口，不输出 token、Key 或完整认证内容。
  - 隔离目录权限为 0700，敏感文件权限为 0600。
  - 真实环境基线指纹和活动连接保持不变。
  - 结果：隔离 `CODEX_HOME` 创建成功并已在验证后删除。真实 `auth.json` 基线及最终 SHA-256 均为 `aa3e384d3a0aafe7255a82d987b823c3f771588fcac9d3f4b8a67024d57d793f`；真实 registry 最终仍为原活动账号、6 个账号、0 个 Key 连接。

### Step 2: 验证账号模式请求 [🔴] [✅]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-account-key-switch-validation/
- 关键决策: 使用隔离环境中的账号模式发起一次固定短响应请求，仅记录 HTTP/CLI 状态、预期文本和脱敏的凭据类型证据。
- 验收:
  - 账号模式请求成功并返回预期短文本。
  - 请求前后隔离环境活动类型为账号，真实环境无变化。
  - 结果：首次请求返回 `ACCOUNT_MODE_OK`，但后续取证发现隔离环境继承了真实 `config.toml` 的全局 AgentRouter provider，因此该请求不能证明实际走官方账号端点，只能证明当前活动认证可完成请求。

### Step 3: 切换到 Key 并验证请求 [🔴] [✅]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-account-key-switch-validation/
- 关键决策: 在隔离 registry 中临时新增 AgentRouter Key 连接并激活，发起一次固定短响应请求；Key 不进入 argv、日志或项目文件。
- 验收:
  - 活动类型从账号切换为 Key。
  - Key 模式请求成功并返回预期短文本。
  - 可证明请求配置指向 AgentRouter，且不输出完整 Key。
  - 结果：仓库当前源码成功添加并激活隔离 Key 连接，registry 活动类型为 `apikey`、base URL 已配置；按桌面应用直连 provider 参数请求返回 `KEY_MODE_OK`。已安装的旧 `codex-auth` 二进制不支持 `gui add-key`，与当前源码版本不一致。

### Step 4: 切回账号并最终审计 [🔴] [✅]
- 依赖: Step 3
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-account-key-switch-validation/
  - .agent/plans/active/2026-0803-account-key-switch-request-validation.md
- 关键决策: 切回原账号后再发起一次最小请求；无论中途结果如何都删除隔离环境，并核验真实 registry、认证文件和 CPA 配置指纹未变化。
- 验收:
  - 活动类型恢复为账号，第三次请求成功。
  - 真实环境活动账号和关键配置指纹与基线一致。
  - 测试 Key 在真实 Codex Auth、CPA、项目和临时目录中的残留均为 0。
  - 结果：隔离 registry 已切回原 ChatGPT 账号且活动 `auth.json` 与该账号快照一致，但第三次请求仍访问 AgentRouter，并因账号令牌不适用于该端点而返回 401；随后隔离账号刷新令牌报告失效。真实环境未被切换或覆盖，临时目录已删除。
  - 阻断：真实 `~/.codex/config.toml` 在验证前已固定 `model_provider = "custom"` 和 AgentRouter `base_url`，同时真实 `auth.json` 已是 API Key，而 Codex Auth registry 仍显示 ChatGPT 账号为活动项。要完成可靠复测，必须先修复“全局 provider 与 registry 活动连接不一致”，该操作会改变真实 Codex 全局连接方式，需用户单独确认。
  - 修复：直连官方账号和官方 Key 的启动命令显式附加 `model_provider="openai"`，中转站 Key 继续使用 `codex_auth_direct` 单次 provider，均不修改用户全局 `config.toml`。
  - 复测结果：隔离环境中账号请求返回 `ACCOUNT_PROVIDER_OK`；切换 AgentRouter Key 后请求返回 `KEY_PROVIDER_OK`；切回同一账号后请求返回 `ACCOUNT_RESTORED_PROVIDER_OK`，三段均成功。
  - 最终审计：隔离目录已删除；真实环境仍为 6 个账号、0 个 Key 连接、原活动账号不变，真实 `auth.json` SHA-256 仍为 `aa3e384d3a0aafe7255a82d987b823c3f771588fcac9d3f4b8a67024d57d793f`。

## 关键上下文
- 用户已明确授权三次最小真实请求及必要的临时验证操作，允许少量账号额度和 Key 费用。
- 真实 Key 与 CPA 请求此前已经通过；本计划重点验证应用的账号/Key 活动连接切换与请求来源。
- 项目当前 HEAD 为 `1d92a2c1555836b1bcdc5f7635263c5495ae24cb`，已有未跟踪 `.codegraph/` 和上一份验证归档，不得纳入产品改动。
- 测试 Key 在本计划开始前已存在于真实 `~/.codex/auth.json` 和全局 AgentRouter 配置中；本次验证没有向真实 registry 或账号快照新增 Key。由于用户在对话中直接提供 Key，Codex 自身 history/session 也包含该文本，这不是 Codex Auth 写入，且未经授权不得删除当前会话历史。

## 已改动文件汇总
- .agent/plans/active/2026-0803-account-key-switch-request-validation.md (Step 1)
- macos/CodexAuthApp/Sources/CodexAuthApp/CPARuntime.swift (Step 4)
- macos/CodexAuthApp/Tests/CodexAuthAppTests/CPARuntimeTests.swift (Step 4)

## 验证结论
- 账号 → Key → 账号的活动连接切换与真实请求闭环通过。
- Swift 全量测试 72 项通过，Debug 构建通过。
- 全局 `config.toml` 即使固定自定义 provider，也不会再覆盖由桌面 App 启动的官方账号/官方 Key 直连会话。

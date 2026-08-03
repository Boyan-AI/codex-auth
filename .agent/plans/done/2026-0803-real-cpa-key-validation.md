# Task: 真实 Key 与 CPA 临时闭环验证
Created: 2026-08-03
Status: completed
Execution Mode: solo

## 目标
使用用户提供的临时 AgentRouter Key，在真实本机 CPA 中完成一次 API Key 路由请求，并在结束后恢复 CPA 原配置、确认测试 Key 未残留。

## 计划

### Step 1: 基线与安全边界 [🔴] [✅]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 本机 CPA 管理 API 配置
  - /tmp/codex-auth-real-cpa/
- 关键决策: 测试 Key 只通过环境变量和请求体使用，不写入 Codex Auth registry、认证快照或项目文件；CPA 原 `codex-api-key` 列表必须在变更前完整保存到受保护临时目录。
- 验收:
  - CPA 客户端配置存在且只读取地址/是否有管理配置，不输出密钥。
  - 获取并保存 CPA 原 `codex-api-key` 列表，输出仅包含数量与脱敏元数据。
  - 确认 Codex Auth registry 与认证目录没有新增测试连接。
  - 结果：CPA 原列表数量为 0，基线 SHA-256 为 `37517e5f3dc66819f61f5a7bb8ace1921282415f10551d2defa5c3eb0985b570`；未发现测试连接。

### Step 2: 临时加入 CPA Key [🔴] [✅]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 本机 CPA `codex-api-key` 管理接口
- 关键决策: 只追加 `{api-key, base-url}`，不覆盖 CPA 其他 Key 或高级配置；失败时立即进入恢复流程。
- 验收:
  - CPA GET 能看到临时条目数量增加一项。
  - 项目 registry、认证快照和 Git 工作区无变化。
  - 结果：CPA 临时列表数量为 1，测试条目匹配为 1；未写入项目或 Codex Auth registry。

### Step 3: 真实请求验证 [🔴] [✅]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-real-cpa/
- 关键决策: 只执行一次最小模型请求；不启动交互式 Codex 会话，不保存响应中的敏感信息。
- 验收:
  - 记录 HTTP 状态、响应是否为有效模型响应、使用的模型标识。
  - 不输出完整 Key、管理密钥或完整响应正文。
  - 结果：`/v1/models` HTTP 200，发现可用模型；`/v1/responses` HTTP 200，响应包含预期校验文本，未发现错误类型。

### Step 4: 恢复与最终审计 [🔴] [✅]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 本机 CPA `codex-api-key` 管理接口
  - /tmp/codex-auth-real-cpa/
- 关键决策: 无论真实请求成功、失败或超时，都 PUT 回 Step 1 保存的完整 CPA 列表。
- 验收:
  - CPA Key 列表恢复到原始数量和指纹。
  - 测试 Key 不存在于 CPA 配置、Codex Auth registry、认证快照和项目输出。
  - 删除临时验证文件；项目只保留本计划归档记录。
  - 结果：CPA 恢复数量为 0，SHA-256 恢复为基线值，测试 Key 匹配为 0；CPA、Codex Auth 目录、项目目录和临时目录扫描均为 0；临时脚本与目录已删除。

## 关键上下文
- 测试服务: AgentRouter，base URL 为用户提供的 `https://agentrouter.org/v1`。
- 测试 Key 不应写入磁盘；如工具或 CPA 管理 API 发生落盘，仅限 CPA 临时配置，验证后立即恢复。
- 本项目当前提交为 `1d92a2c`，已有未跟踪 `.codegraph/`，不得纳入项目改动。

## 已改动文件汇总
- .agent/plans/active/2026-0803-real-cpa-key-validation.md (Step 1)

## 验证结论
- 真实 CPA Key 路由闭环通过：临时配置、模型发现、Responses 请求、配置恢复均成功。
- 测试 Key 未写入 Codex Auth registry、认证快照或项目文件；验证产生的临时文件已清理。

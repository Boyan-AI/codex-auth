# Task: 账号与 Key 切换时同步 Codex 配置预设
Created: 2026-08-04
Status: completed
Execution Mode: solo

## 目标
在保留用户现有 plugins、projects、hooks、MCP 等配置的前提下，让 ChatGPT 账号与 API Key 切换同时更新各自需要的 Codex 根级配置预设。

## 计划

### Step 1: 扩展统一配置同步逻辑 [🟡 推荐默认档] [✅ 完成]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - src/registry/account_ops.zig
  - src/registry/root.zig
- 关键决策: 继续复用所有切换入口共用的 `activateAccountByKey`，按 CC Switch 的 Codex provider 格式补丁式管理配置，不覆盖整个 config.toml。账号预设写入 `model`、`service_tier=default`、`approvals_reviewer=auto_review`，并清理 Key 专属配置；Key 预设写入 `model_provider="custom"`、`model`、`disable_response_storage=true`，以及 `[model_providers.custom]` 下的 `name="Sub2API"`、当前 Key Base URL、`wire_api="responses"`、`requires_openai_auth=true`，并清理账号专属键与旧 `openai_base_url`。`model_reasoning_effort` 不由工具写入或删除，保留 Codex 默认值或用户已有设置。账号模式移除由本工具生成的 custom provider 表；其余 plugins、projects、hooks、MCP 和未知配置保持不变。
- 验收:
  - CLI、实时模式和桌面端切换均通过统一激活链路得到对应预设
  - 账号与 Key 双向切换不会残留对方专属根级键
  - 重复同步幂等，配置不存在时可安全创建
  - 除工具托管的 `[model_providers.custom]` 外，原有表、注释、未知根级键和文件权限保持不变
- 完成记录: 统一激活链路现已按账号/Key 生成对应配置预设；Key 使用并选中 `custom` provider，账号清理该托管表；根级未知内容、文件权限和 reasoning effort 均保留。重复激活幂等，配置不存在时可创建。完整测试 436 项通过、8 项按既有条件跳过。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 2: 补齐配置切换回归测试与文档 [🔵 自动档] [✅ 完成]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - tests/registry_test.zig
  - docs/commands/switch.md
- 关键决策: 测试覆盖账号→Key、Key→账号、官方 Key/中转 Key、CC Switch provider 表格式、内容保留、权限与幂等；文档只描述用户可观察行为和新会话生效边界。
- 验收:
  - 配置专项测试覆盖双向切换和非托管内容保留
  - `docs/commands/switch.md` 与公开行为一致
- 完成记录: 回归测试覆盖中转 Key、官方 Key、Key→账号、配置创建、重复同步、内容与权限保留；切换文档已补充配置预设、新进程生效和 provider 会话可见性边界。完整测试 437 项通过、8 项按既有条件跳过。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 3: 隔离验证并交付桌面版本 [🔴 必须确认档] [✅ 完成]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /tmp/codex-auth-config-presets
  - .agent/desktop-delivery-ready.json
  - .agent/plans/active/2026-0804-账号与key配置预设切换.md
  - .agent/plans/done/2026-0804-account-key-config-presets.md
- 关键决策: 所有 Zig 测试与运行验证使用隔离 HOME；验证通过后创建精确交付 marker，由受信任 Hook 使用项目唯一安装脚本覆盖并重启桌面 App，然后仅提交本任务文件并 push。该步骤会修改真实桌面 App 和当前 `$CODEX_HOME/config.toml`，并产生外部 Git push，执行前需用户明确批准。
- 验收:
  - `zig build test` 通过
  - 按项目约束执行 `zig build run -- list` 通过
  - `git diff --check` 通过
  - 桌面 App 单实例运行，真实配置与当前活动连接匹配
  - 计划归档，相关文件提交并成功 push
- 完成记录: 隔离环境中 `zig build test` 共 437 项通过、8 项按既有条件跳过，`zig build run -- list` 与 `git diff --check` 通过。桌面 App 已由唯一安装脚本覆盖并重启，单实例 PID 15618；当前活动连接为 ChatGPT 账号，真实配置已同步 `model=gpt-5.6-sol`、`service_tier=default`、`approvals_reviewer=auto_review`，未写入 reasoning effort。计划归档后由自动交付 Hook 对精确文件集合再次安装校验、提交并 push。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

## 关键上下文
- 当前项目已在统一激活链路中同步 `model_provider` 与 `openai_base_url`，本任务是在此基础上扩展配置预设，不需要改桌面端切换入口。
- 官方 Codex 文档确认 `model`、`model_provider`、`model_reasoning_effort`、`service_tier`、`disable_response_storage`、`openai_base_url` 和 `model_providers.*` 属于用户级 `config.toml` 配置；自定义 provider 只有被 `model_provider` 选中才生效。
- `model_reasoning_effort` 按用户要求使用默认行为，因此不纳入工具托管键；`approvals_reviewer` 未出现在当前公开配置参考中，但当前运行环境明确支持该值，实现会按用户当前客户端配置写入账号预设，并以本机 Codex 实际解析结果为准。
- CC Switch 官方用户手册给出的 Key 格式明确包含 `model_provider = "custom"`，且该值必须与 `[model_providers.custom]` 的表名匹配；因此会在用户示例基础上补齐这一必需根级键。
- 切换到 custom provider 可能使 Codex App 暂时不展示由 `openai` provider 创建的历史会话；会话文件不会被删除，切回账号模式后可恢复显示。这是 provider 身份变化带来的已知产品行为。
- 配置只影响之后新建的 Codex 进程或线程，不会热切换已经运行的会话。

## 已改动文件汇总
- .agent/plans/done/2026-0804-account-key-config-presets.md (计划创建与归档)
- src/registry/account_ops.zig (Step 1)
- tests/registry_test.zig (Step 1、Step 2)
- docs/commands/switch.md (Step 2)

# 账号与 API Key 重新连接入口区分设计

状态：书面规格已确认，待实施计划审批

日期：2026-08-07

## 背景与根因

账号管理页已经用 `CodexAccount.isAPIKey` 区分 ChatGPT 账号与 API Key，并分别展示额度、余额、连接类型和 Base URL；但详情页底部仍统一显示“重新登录”。点击该按钮后，`ManageAccountsView` 无条件打开账号登录表单，并最终调用 `AppState.login()` 执行 OAuth 登录。

因此，API Key 连接虽然在展示层已被识别为 Key，低频操作入口却仍按 ChatGPT 账号处理。现有后端只提供“添加 Key”，没有能够安全替换旧连接的原子“编辑 Key”命令；仅把按钮改名为“编辑 Key”会造成行为与文案不一致。

## 目标

- ChatGPT 账号继续显示“重新登录”，并保持现有 OAuth 登录流程。
- API Key 显示“重新添加 Key”，打开只提供 API Key 类型的重新添加表单。
- API Key 表单预填现有别名、服务商和 Base URL，但绝不展示或回填密钥原文。
- 复用现有 `AppState.addAPIKey` 与 `gui add-key` 流程，不增加新的后端命令。
- 新 Key 验证或保存失败时，不修改或删除原连接。

## 非目标

- 不实现原地编辑或原子替换 API Key。
- 不自动删除旧 Key，也不自动切换当前直连连接。
- 不给“已删除连接”增加恢复操作；该页面继续只保存和展示脱敏记录。
- 不修改 CPA、CPAMP、全局路由或 Codex 配置预设。
- 不保存、记录、复制或回显 API Key 原文。

## 界面行为

### ChatGPT 账号

- 详情页按钮文案保持“重新登录”。
- 点击后继续打开现有账号登录 sheet。
- 表单继续预填账号别名，确认后调用 `AppState.login(alias:)`。

### API Key

- 详情页按钮文案改为“重新添加 Key”。
- 点击后打开 Key 专用 sheet，不显示“ChatGPT 账号 / API Key”类型切换器。
- 表单预填：
  - 名称：现有 `alias`，没有别名时为空。
  - 服务商：由 `providerKind` 映射为 `APIKeyProvider`；无法识别时回退为 `.relay`，避免把自定义地址误当成 OpenAI 官方地址。
  - Base URL：现有 `baseURL`；缺失时使用所选服务商的默认值。
  - API Key：始终为空，由用户重新输入。
- 主按钮文案为“添加 Key”。只有 Key 和 Base URL 均为非空时才能提交。
- 提交后调用现有 `AppState.addAPIKey(alias:provider:baseURL:apiKey:)`。

## 数据与结果语义

`gui add-key` 使用服务商身份与密钥共同派生连接标识：

- 用户在相同服务商身份范围内输入相同 Key 时，后端会按同一连接标识更新对应记录和快照。
- 用户输入不同 Key，或修改了中转站 Base URL 时，后端会创建新连接，旧连接继续保留。
- 添加流程本身不切换当前直连连接，也不自动把旧连接删除。

界面不使用“编辑”或“替换”等文案，避免暗示旧连接一定会被覆盖。用户若希望淘汰旧 Key，可在确认新连接可用后手动删除旧连接。

## 组件与状态设计

- 在管理页增加独立的 API Key 重新添加 sheet 状态，与账号 `reloginAccount` 分开，避免两类连接共用错误流程。
- 将 Key 表单的可复用部分提取为可配置视图或为现有添加表单增加明确的 Key-only 初始化入口。
- 用一个可测试的轻量展示模型集中决定：
  - 当前连接的操作文案；
  - 应打开账号登录还是 Key 重新添加 sheet；
  - Key 表单的非敏感初始值。
- 不向 `CodexAccount`、持久化注册表或删除记录增加新字段。

## 错误处理与安全边界

- Key 字段保持 `SecureField`，且不从任何磁盘快照读取旧密钥进行回填。
- 提交失败继续复用 `AppState.load` 的错误展示，原连接和当前选择保持不变。
- 无法识别服务商时采用兼容中转站模式，并保留现有 Base URL；不静默改写为 OpenAI 官方地址。
- 若历史记录缺少 Base URL，表单仍要求用户补全后才能提交。
- 不把 Key 放入命令行参数；继续通过 `CODEX_AUTH_API_KEY` 环境变量传给本地 CLI。

## 测试与验收

先按 TDD 增加失败测试，再实现最小代码：

- ChatGPT 账号的操作文案为“重新登录”，操作类型为账号登录。
- API Key 的操作文案为“重新添加 Key”，操作类型为 Key 表单。
- OpenAI Key 能正确预填 `.openai` 和官方 Base URL。
- Relay Key 能正确预填 `.relay`、别名和自定义 Base URL。
- 未知 provider 不会误选 OpenAI，且 Key 初始值始终为空。
- 现有账号登录与添加 Key 测试继续通过。

代码完成后，在隔离 HOME 下运行 Swift 定向测试、完整测试和 Release 构建。桌面 App 覆盖安装仍按项目规则单独等待确认；本任务不改变当前暂停中的 CPAMP 发布与安装步骤。

## 交付边界

本设计作为独立任务实施，不并入 CPAMP 日志页发布范围。实施计划只允许修改账号管理 UI、必要的展示模型、对应 Swift 测试、设计文档和独立计划文件；除非后续证据表明现有 `add-key` 契约不满足上述语义，否则不修改 Zig 后端。

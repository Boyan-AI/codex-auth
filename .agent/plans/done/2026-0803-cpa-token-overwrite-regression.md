# Task: 修复 CPA 独立授权并补充已删除连接查看
Created: 2026-08-03
Status: complete
Execution Mode: solo

## 目标
修正直连与 CPA 共用旋转凭据导致的 502，让账号仅在用户主动加入智能路由时完成独立授权，并在管理页提供已删除账号和 Key 的只读清单。

## 计划

### Step 1: 脱敏核对 CPA 现场与 Token 来源 [🔵 自动档] [✅ 完成]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - .agent/plans/active/2026-0803-cpa-token-overwrite-regression.md
  - /tmp/codex-auth-cpa-token-regression/
- 关键决策: 只比较文件成员、时间戳和认证字段哈希，不输出 Token、客户端 Key、管理 Key或完整响应；优先验证启动对账是否覆盖 CPA 自主刷新后的凭据。
- 验收:
  - 定位最新 `/v1/responses` 失败对应的 CPA 上游认证错误
  - 明确 CPA auth 文件与 Codex Auth 标准快照是否被启动流程重写
- 验证结果: 重装后的启动对账连续重写两份 CPA 文件，CPA 随即报告凭据已被复用；最新 Responses 的真实上游状态为 401。三处认证来源一致，说明当前并非独立会话。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 2: 固化独立 CPA OAuth 边界的回归测试 [🔵 自动档] [✅ 完成]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - tests/registry_test.zig
  - tests/cli_integration_test.zig
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/AppStateTests.swift
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/CLIClientTests.swift
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/CPARuntimeTests.swift
- 关键决策: 旋转型凭据不能在直连与 CPA 间复制；对账按稳定账号身份保留成员、删除非成员，但绝不从直连快照补齐或覆盖。直连认证失败也不能删除独立 CPA 会话。
- 验收:
  - 测试证明任意文件名的合法 CPA OAuth 成员被保留且内容不变
  - 测试证明孤儿被删除、缺失成员只报告不复制、直连失败不再联动删除 CPA 会话
  - 测试覆盖 CPA 官方 OAuth URL、状态轮询和错误处理
  - 测试证明只有授权成功且账号身份匹配时才提交“加入智能路由”状态
- 验证结果: Zig 回归覆盖默认排除、旧版复制文件清理和 CPA 自主文件保留；Swift 回归覆盖 OAuth 复用、首次授权、身份不匹配拒绝、事务性开关与直连故障隔离。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 3: 修复 Token 所有权并接入 CPA 独立登录 [🔴 必须确认档] [✅ 完成]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - src/registry/export.zig
  - src/workflows/gui.zig
  - macos/CodexAuthApp/Sources/CodexAuthApp/CPARuntime.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/CodexAuthCLIClient.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/AppState.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/ManageAccountsView.swift
  - docs/cpa-smart-routing.md
  - 外部：本机 CPA 专用认证目录
- 关键决策: 新账号默认不加入智能路由；用户开启“加入智能路由”时，若缺少独立 CPA 会话则自动发起官方 OAuth，按稳定身份验证浏览器登录账号，验证成功后才提交开关状态。关闭开关只在 CPA 中禁用凭据并保留授权，重新开启无需再次登录；彻底删除授权另设低频操作。当前两份失效 CPA 文件先可恢复隔离，再由用户分别登录两个智能池账号。
- 验收:
  - 任何路径都不再把直连 OAuth 凭据写入 CPA
  - 对账不再覆盖或补写 CPA 成员文件
  - 关闭智能路由仅禁用独立凭据，重新开启可复用授权
  - 登录账号与所选账号不匹配时拒绝加入并给出明确提示
  - 两个账号完成独立 CPA OAuth 后，最小真实 Responses 请求成功
- 验证结果: 代码路径已停止复制直连 OAuth；智能路由开关接入 CPA 原生 OAuth、精确邮箱核对及保留授权的启停接口。真实账号授权与 Responses 请求留待桌面交付后的用户浏览器交互验证。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 4: 在管理页展示已删除账号与 Key [🔵 自动档] [✅ 完成]
- 依赖: Step 3
- 可并行: 否
- 执行者: lead
- 写入范围:
  - macos/CodexAuthApp/Sources/CodexAuthApp/Models.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/AppState.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/ManageAccountsView.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/TokenUsageView.swift
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/AppStateTests.swift
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/ModelsTests.swift
- 关键决策: 复用现有 `DeletedAccountStore`，扩展记录以区分 ChatGPT 账号与 API Key 连接，但只保存脱敏标签、非敏感连接类型和删除时间；不保存 Key 原文。管理页工具栏增加“已删除”只读入口，历史旧记录保持兼容。
- 验收:
  - 从 App 删除的账号和 Key 均出现在已删除清单
  - 清单可区分账号与 Key，并显示脱敏信息和删除时间
  - 旧版删除记录可继续读取；不提供恢复或泄露密钥的能力
- 验证结果: 管理页工具栏已接入只读清单；记录新增可选类型字段兼容旧数据，API Key 测试确认只保存脱敏标签、Base URL、类型和删除时间。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 5: 隔离验证与桌面交付 [🔵 自动档] [✅ 完成]
- 依赖: Step 4
- 可并行: 否
- 执行者: lead
- 写入范围:
  - .agent/plans/active/2026-0803-cpa-token-overwrite-regression.md
  - .agent/plans/done/2026-0803-cpa-token-overwrite-regression.md
  - .agent/desktop-delivery-ready.json
  - macos/CodexAuthApp/Sources/CodexAuthApp/CPARuntime.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/CodexAuthCLIClient.swift
  - macos/CodexAuthApp/Sources/CodexAuthApp/StatusItemController.swift
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/CPARuntimeTests.swift
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/CLIClientTests.swift
  - macos/CodexAuthApp/Tests/CodexAuthAppTests/ModelsTests.swift
  - docs/cpa-smart-routing.md
- 关键决策: 在隔离 HOME 下运行 Zig 与 Swift 验证，使用唯一桌面安装脚本交付，并通过精确清单 Hook 提交推送。
- 验收:
  - `zig build run -- list`、Zig 测试、Swift 测试通过
  - 桌面 App 单进程运行
  - 提交推送完成且工作区干净
- 当前结果: Swift 87 项测试全通过；Zig 全套 441 项无失败（432 通过、8 跳过），`zig build run -- list` 通过；桌面 App 已重装并单进程启动。真实 CPA OAuth 与 Responses 请求需要用户在管理页逐个开启账号并完成浏览器授权后继续验证，因此暂不归档、不创建交付 marker。
- UI 复核: 根据用户反馈取消无法关闭的已删除弹窗，将“已删除”并入状态筛选菜单；选中后在原管理页左右栏展示删除记录和只读详情。Swift 87 项测试再次通过，桌面 App 已覆盖安装并以单进程 PID 80365 运行。
- 筛选语义修正: 状态筛选首项由“全部”改为“现有”，明确该入口只汇总未删除连接，“已删除”继续作为独立只读历史集合；隔离 HOME 下 Swift 全量 89 项测试通过。
- 菜单栏锚点修正: 状态项固定为可容纳 `100%` 的 47pt 紧凑宽度，`--`、两位和三位百分比均在按钮内水平居中，避免刷新前后按钮宽度变化或短文案左对齐导致弹窗箭头视觉漂移；新增回归后隔离 Swift 全量 90 项测试通过。
- 菜单栏锚点桌面交付: 用户确认后已通过唯一安装脚本覆盖桌面 App，完成构建、重签名、重启与单进程验证；当前 PID 88202，等待用户切换已知额度与查询失败状态复核箭头位置。
- 真实链路验收: CPA 本地请求日志确认 Ghostty 环境修复后于 2026-08-04 10:54 至 11:13 连续收到 `/v1/responses`，记录均为 HTTP 200，证明智能启动请求已直达本机 CPA 并成功完成上游响应。
- 最终验证: 隔离 HOME、独立 Swift scratch path 与 Zig cache 下，Swift 90 项测试全通过，`zig build test` 与强制 `zig build run -- list` 均以 0 退出；桌面 App 已安装并完成单进程验证。用户已授权整理提交推送，计划归档并交由精确交付清单完成提交。
- 交互修正: 管理页不再用后台全量刷新状态禁用“设为当前”和“加入智能路由”；切换账号与智能路由改用各自的操作级忙状态。Swift 88 项测试全通过，桌面 App 已覆盖安装并以单进程 PID 81165 运行。
- 现场复核（2026-08-04）: 第二次 CPA 原生 OAuth 于 10:14:08 成功落盘并被运行时增量加载；管理接口显示唯一 Codex 凭据为 `active`、未禁用且可用，`/v1/models` 返回 10 个模型。成功授权后的日志中尚无 `/v1/responses` 请求，用户粘贴的 502 没有经过这份新凭据，需从新启动的智能路由会话重试后再判定。
- 启动会话纠偏: 用户确认同一项目的智能启动始终恢复旧会话；代码核对发现智能命令硬编码 `resume --last`。智能启动改为创建新会话并使用本次 CPA provider 覆盖，直连恢复行为保持不变；补充命令级回归测试和运行契约文档。
- 启动会话验证: 定向命令测试通过；隔离 HOME 与 scratch path 下 Swift 全量 88 项测试通过，`git diff --check` 通过。等待用户确认覆盖安装桌面 App 后进行新智能会话与真实 Responses 复核。
- 桌面交付复核: 用户确认后已通过唯一安装脚本覆盖桌面 App，安装脚本完成构建、重签名、重启与单进程验证；当前 PID 83133。等待用户从新版 App 发起一次智能启动，确认进入新会话并验证真实 Responses。
- 本机代理根因: 新会话确认使用 `codex_auth_cpa` provider，但 49 秒后 502 且 CPA 未收到 POST；系统 HTTP/HTTPS/SOCKS 代理启用。本机假服务探针在无 `NO_PROXY` 时复现相同 502，注入大小写 `NO_PROXY=127.0.0.1,localhost,::1` 后立即直连。修复限定为智能启动子进程合并本机绕过项，不改系统代理或直连会话。
- 本机代理修复验证: 智能启动环境现会保留已有代理绕过规则，并为大小写变量补齐 `127.0.0.1,localhost,::1`；定向测试与隔离 Swift 全量 89 项测试通过，`git diff --check` 通过，诊断进程已全部退出。等待用户再次确认覆盖安装桌面 App。
- 代理修复桌面交付: 用户确认后已通过唯一安装脚本覆盖桌面 App，完成构建、重签名、重启与单进程验证；当前 PID 84961。等待新版智能启动的真实 Responses 结果。
- Ghostty 环境转交缺陷: 新版真实请求仍为 502 且 CPA 未收到 POST。结构核对确认智能启动环境字典虽已含代理绕过项，但 Ghostty surface 只显式接收 CPA Key；修复为按变量名转交完整环境字典，值由 `osascript` 子进程通过 `printenv` 读取，避免密钥进入脚本文本。Terminal fallback 与直连行为不变。
- Ghostty 转交验证: 命令级测试确认 Ghostty AppleScript 同时读取 CPA Key、`NO_PROXY` 与 `no_proxy`，脚本文本不含密钥值；隔离 Swift 全量 89 项测试与 `git diff --check` 通过。等待用户确认覆盖安装。
- Ghostty 修复桌面交付: 用户确认后已通过唯一安装脚本覆盖桌面 App，完成构建、重签名、重启与单进程验证；当前 PID 86100。等待新版智能启动真实请求。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

## 关键上下文
- 上一版已证明删除两份孤儿凭据后最小 Responses 请求返回 200，但重装并触发启动对账后持续恢复 502。
- CPA 与直连路径按设计独立刷新 Token；任何启动时无条件覆盖都可能回滚 CPA 已旋转的 refresh token。
- CPA 7.2.109 官方提供管理接口启动 Codex OAuth 并轮询状态，认证结果直接保存到专用目录；应使用该接口而不是复制直连快照。
- 现有 `DeletedAccountStore` 已记录从 App 删除的连接，`DeletedAccountsView` 也已实现但未挂载；记录目前缺少账号/Key 类型字段。
- 认证内容和密钥不得进入项目文件、日志摘要或提交。

## 已改动文件汇总
- .agent/plans/active/2026-0803-cpa-token-overwrite-regression.md (计划初始化)
- .agent/plans/active/2026-0803-cpa-token-overwrite-regression.md (根据现场证据升级为独立 CPA OAuth 修复)
- .agent/plans/active/2026-0803-cpa-token-overwrite-regression.md (确定开关内独立授权，并加入已删除账号与 Key 查看)
- src/registry/common.zig (智能池安全默认值)
- src/registry/storage_parse.zig (旧记录安全迁移)
- src/registry/export.zig (停止复制 OAuth 并清理旧版副本)
- tests/registry_test.zig (CPA 所有权回归)
- macos/CodexAuthApp/Sources/CodexAuthApp/CPARuntime.swift (CPA 原生 OAuth 与身份核对)
- macos/CodexAuthApp/Sources/CodexAuthApp/CodexAuthCLIClient.swift (按连接类型分派 CPA 同步)
- macos/CodexAuthApp/Sources/CodexAuthApp/AppState.swift (事务性智能路由开关)
- macos/CodexAuthApp/Sources/CodexAuthApp/Models.swift (已删除连接类型与安全默认值)
- macos/CodexAuthApp/Sources/CodexAuthApp/ManageAccountsView.swift (已删除状态筛选与只读详情)
- macos/CodexAuthApp/Sources/CodexAuthApp/TokenUsageView.swift (移除旧弹窗视图)
- macos/CodexAuthApp/Sources/CodexAuthApp/StatusItemController.swift (固定菜单栏宽度并居中额度胶囊)
- macos/CodexAuthApp/Tests/CodexAuthAppTests/AppStateTests.swift (状态边界回归)
- macos/CodexAuthApp/Tests/CodexAuthAppTests/CPARuntimeTests.swift (CPA OAuth 回归)
- macos/CodexAuthApp/Tests/CodexAuthAppTests/CLIClientTests.swift (客户端 OAuth 分派回归)
- macos/CodexAuthApp/Tests/CodexAuthAppTests/ModelsTests.swift (删除记录兼容与脱敏回归)
- docs/cpa-smart-routing.md (独立授权契约)

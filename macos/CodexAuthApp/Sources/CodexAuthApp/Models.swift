import Foundation

enum CodexAuthAPIMode: Equatable {
    case automatic
    case forceApi
    case skipApi

    var arguments: [String] {
        switch self {
        case .automatic:
            return []
        case .forceApi:
            return ["--api"]
        case .skipApi:
            return ["--skip-api"]
        }
    }
}

/// 映射后端支持的 API Key provider 类型。
enum APIKeyProvider: String, CaseIterable, Identifiable {
    case openai
    case relay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openai: return "OpenAI 官方"
        case .relay: return "兼容中转站"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .relay: return ""
        }
    }
}

/// 区分菜单全量校验与 CPA 事件触发的增量 Token 文件扫描。
enum TokenUsageScanMode: Equatable {
    case incremental
    case full

    /// 映射为 GUI 后端的稳定英文命令参数。
    var arguments: [String] {
        switch self {
        case .incremental:
            return []
        case .full:
            return ["--full"]
        }
    }
}

/// 表示所有新建 Codex 会话当前采用的全局路由。
enum GlobalRoute: String, Codable, Equatable {
    case direct
    case cpa
    case newapi
}

struct CodexAuthState: Decodable, Equatable {
    let schemaVersion: Int
    let codexHome: String
    let globalRoute: GlobalRoute
    let activeAccountKey: String?
    let generatedAt: Date
    let refresh: RefreshInfo
    var resetCredits: ResetCreditsInfo? = nil
    let warnings: [String]
    var tokenUsage: TokenUsageInfo? = nil
    let accounts: [CodexAccount]

    /// 提供带安全直连默认值的显式初始化器，兼容测试和本地空状态。
    init(
        schemaVersion: Int,
        codexHome: String,
        globalRoute: GlobalRoute = .direct,
        activeAccountKey: String?,
        generatedAt: Date,
        refresh: RefreshInfo,
        resetCredits: ResetCreditsInfo? = nil,
        warnings: [String],
        tokenUsage: TokenUsageInfo? = nil,
        accounts: [CodexAccount]
    ) {
        self.schemaVersion = schemaVersion
        self.codexHome = codexHome
        self.globalRoute = globalRoute
        self.activeAccountKey = activeAccountKey
        self.generatedAt = generatedAt
        self.refresh = refresh
        self.resetCredits = resetCredits
        self.warnings = warnings
        self.tokenUsage = tokenUsage
        self.accounts = accounts
    }

    /// 解码后端状态；旧输出缺少根级路由时按直连处理。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        codexHome = try container.decode(String.self, forKey: .codexHome)
        let routeValue = try? container.decode(String.self, forKey: .globalRoute)
        globalRoute = routeValue.flatMap(GlobalRoute.init(rawValue:)) ?? .direct
        activeAccountKey = try container.decodeIfPresent(String.self, forKey: .activeAccountKey)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        refresh = try container.decode(RefreshInfo.self, forKey: .refresh)
        resetCredits = try container.decodeIfPresent(ResetCreditsInfo.self, forKey: .resetCredits)
        warnings = try container.decode([String].self, forKey: .warnings)
        tokenUsage = try container.decodeIfPresent(TokenUsageInfo.self, forKey: .tokenUsage)
        accounts = try container.decode([CodexAccount].self, forKey: .accounts)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, codexHome, globalRoute, activeAccountKey, generatedAt
        case refresh, resetCredits, warnings, tokenUsage, accounts
    }

    var activeAccount: CodexAccount? {
        accounts.first { $0.accountKey == activeAccountKey || $0.isActive }
    }

    /// 保留当前界面已经接受的账号遥测，同时采用切换结果中的账号结构与活动状态。
    func preservingDisplayedTelemetry(from currentState: CodexAuthState?) -> CodexAuthState {
        guard let currentState, currentState.codexHome == codexHome else {
            return self
        }
        let mergedAccounts = accounts.map { account in
            guard let currentAccount = currentState.accounts.first(where: { $0.accountKey == account.accountKey }) else {
                return account
            }
            return account.preservingDisplayedTelemetry(from: currentAccount)
        }
        let activeResetCredits = mergedAccounts.first(where: {
            $0.accountKey == activeAccountKey || $0.isActive
        })?.resetCredits

        return CodexAuthState(
            schemaVersion: schemaVersion,
            codexHome: codexHome,
            globalRoute: globalRoute,
            activeAccountKey: activeAccountKey,
            generatedAt: generatedAt,
            refresh: currentState.refresh,
            resetCredits: activeResetCredits ?? resetCredits,
            warnings: warnings,
            tokenUsage: currentState.tokenUsage,
            accounts: mergedAccounts
        )
    }

    static func empty(codexHome: String) -> CodexAuthState {
        CodexAuthState(
            schemaVersion: 1,
            codexHome: codexHome,
            globalRoute: .direct,
            activeAccountKey: nil,
            generatedAt: Date(timeIntervalSince1970: 0),
            refresh: RefreshInfo(attempted: false, status: "skipped", message: nil),
            resetCredits: nil,
            warnings: [],
            accounts: []
        )
    }
}

struct TokenUsageInfo: Decodable, Equatable {
    let timezone: String
    let summary: TokenUsageTotals
    let today: TokenUsageDay?
    let latestDay: TokenUsageDay?
    let days: [TokenUsageDay]
    let quality: TokenUsageQuality

    var todayTotalText: String {
        TokenUsageFormatter.compact(today?.totals.totalTokens ?? 0)
    }
}

struct TokenUsageTotals: Decodable, Equatable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
}

struct TokenUsageDay: Decodable, Equatable, Identifiable {
    let date: String
    let sessions: Int
    let totals: TokenUsageTotals

    var id: String { date }
}

struct TokenUsageQuality: Decodable, Equatable {
    let filesScanned: Int
    let filesWithUsage: Int
    let repeatedSnapshots: Int
    let segmentedSessions: Int
    let parseErrors: Int

    var hasWarnings: Bool {
        segmentedSessions > 0 || parseErrors > 0
    }
}

/// 区分已删除的 ChatGPT 账号与 API Key 连接，不包含任何密钥内容。
enum DeletedConnectionType: String, Codable {
    case account
    case apiKey
}

/// 记录由菜单栏 App 删除的连接，避免其从主列表消失后无法追踪。
struct DeletedAccountRecord: Codable, Equatable, Identifiable {
    let accountKey: String
    let label: String
    let detail: String
    let deletedAt: Date
    let connectionType: DeletedConnectionType?

    var id: String { accountKey }

    /// 旧记录缺少类型字段时用历史 Key 的 Base URL 特征兼容识别。
    var resolvedConnectionType: DeletedConnectionType {
        if let connectionType { return connectionType }
        guard let scheme = URL(string: detail)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return .account
        }
        return .apiKey
    }
}

/// 使用 App 自己的偏好存储持久化失效账号清单，不改动 Codex 原始账号文件。
enum DeletedAccountStore {
    private static let key = "deleted-account-records"

    static func load() -> [DeletedAccountRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([DeletedAccountRecord].self, from: data)
        else {
            return []
        }
        return records.sorted { $0.deletedAt > $1.deletedAt }
    }

    static func append(_ account: CodexAccount) {
        var records = load().filter { $0.accountKey != account.accountKey }
        records.insert(
            DeletedAccountRecord(
                accountKey: account.accountKey,
                label: account.primaryLabel,
                detail: account.secondaryLabel,
                deletedAt: Date(),
                connectionType: account.isAPIKey ? .apiKey : .account
            ),
            at: 0
        )
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum TokenUsageFormatter {
    static func compact(_ value: Int64) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

struct ResetCreditsInfo: Decodable, Equatable {
    let availableCount: Int
    let expiresAt: Date?

    /// 返回账户详情使用的 reset 文案，不携带菜单栏胶囊中的分隔符。
    var accountDetailText: String {
        let expiry = expiresAt.map { " · 最近到期 \(UsageResetDateFormatter.string(from: $0))" } ?? ""
        return "重置 \(availableCount)次\(expiry)"
    }

    /// 返回菜单栏使用的 reset 摘要，日期使用本地时区显示。
    var menuBarText: String {
        let expiry = expiresAt.map { " · \(UsageResetDateFormatter.string(from: $0))" } ?? ""
        return "重置 \(availableCount)次\(expiry)"
    }
}

struct RefreshInfo: Decodable, Equatable {
    let attempted: Bool
    let status: String
    let message: String?
}

struct CodexAccount: Decodable, Identifiable, Equatable {
    let accountKey: String
    let displayName: String
    let alias: String?
    let email: String?
    let accountName: String?
    let plan: String?
    let authMode: String?
    var resetCredits: ResetCreditsInfo? = nil
    var providerKind: String? = nil
    var baseURL: String? = nil
    var balance: BalanceSnapshot? = nil
    let isActive: Bool
    let usage: UsageInfo
    let lastUsageAt: Date?
    let lastRefreshAt: Date?

    enum CodingKeys: String, CodingKey {
        case accountKey, displayName, alias, email, accountName, plan, authMode
        case resetCredits, providerKind, balance, isActive
        case baseURL = "baseUrl"
        case usage, lastUsageAt, lastRefreshAt
    }

    var id: String { accountKey }

    /// 判断统一连接列表中的 API Key 类型。
    var isAPIKey: Bool { authMode?.lowercased() == "apikey" }

    /// 返回余额连接的紧凑展示文案；没有成功余额时保持隐藏。
    var balanceText: String? {
        guard let balance else { return nil }
        return "\(balance.amount) \(balance.currency)"
    }

    /// 仅识别要求重新登录的终止性认证错误，避免临时网络或额度错误误暂停路由。
    var hasTerminalAuthenticationFailure: Bool {
        guard !isAPIKey else { return false }
        let statusTokens = usage.sevenDay.status
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
        return statusTokens.contains("token_invalidated") || statusTokens.contains("token_revoked")
    }

    /// 仅把存在有效周额度的账号视为可选择状态，错误文本继续原样展示。
    var isAvailable: Bool {
        if isAPIKey { return true }
        return usage.sevenDay.status == "ok" && usage.sevenDay.remainingPercent != nil
    }

    var primaryLabel: String {
        if let alias, !alias.isEmpty {
            return alias
        }
        if let maskedEmail, !maskedEmail.isEmpty {
            return maskedEmail
        }
        if let accountName, !accountName.isEmpty {
            return accountName
        }
        if !displayName.isEmpty, displayName != email {
            return displayName
        }
        return "未命名账号"
    }

    var secondaryLabel: String {
        if isAPIKey {
            return baseURL ?? email ?? "API Key"
        }
        if let maskedEmail, !maskedEmail.isEmpty {
            return maskedEmail
        }
        return "账号 \(accountKey.suffix(6))"
    }

    /// 使用当前展示中的额度、余额和刷新时间，避免纯本地切换回退到旧缓存。
    func preservingDisplayedTelemetry(from currentAccount: CodexAccount) -> CodexAccount {
        CodexAccount(
            accountKey: accountKey,
            displayName: displayName,
            alias: alias,
            email: email,
            accountName: accountName,
            plan: plan,
            authMode: authMode,
            resetCredits: currentAccount.resetCredits,
            providerKind: providerKind,
            baseURL: baseURL,
            balance: currentAccount.balance,
            isActive: isActive,
            usage: currentAccount.usage,
            lastUsageAt: currentAccount.lastUsageAt,
            lastRefreshAt: currentAccount.lastRefreshAt
        )
    }

    private var maskedEmail: String? {
        guard let email, let atIndex = email.firstIndex(of: "@") else {
            return nil
        }
        let local = String(email[..<atIndex])
        let domain = String(email[atIndex...])
        guard !local.isEmpty, !domain.isEmpty else {
            return nil
        }
        return "\(local.prefix(2))***\(domain)"
    }

    var planLabel: String {
        guard let plan, !plan.isEmpty else {
            return "Unknown"
        }
        switch plan.lowercased() {
        case "free":
            return "Free"
        case "plus":
            return "Plus"
        case "pro":
            return "Pro"
        case "team":
            return "Team"
        case "enterprise":
            return "Enterprise"
        default:
            return plan.prefix(1).uppercased() + plan.dropFirst()
        }
    }

    /// 返回可选的 5 小时用量文案；接口未提供该窗口时不生成占位内容。
    var fiveHourUsageText: String? {
        if isAPIKey { return nil }
        return usage.fiveHour?.displayTextWithReset
    }

    var sevenDayUsageText: String {
        if isAPIKey { return "" }
        return usage.sevenDay.displayTextWithReset
    }

    /// 返回菜单栏 5 小时片段；窗口不存在时由展示层直接省略。
    var menuBarFiveHourText: String? {
        if isAPIKey { return nil }
        guard let fiveHour = usage.fiveHour else {
            return nil
        }
        return "5h \(fiveHour.menuBarPercentText)"
    }

    var menuBarSevenDayText: String {
        if isAPIKey { return "" }
        return "7d \(usage.sevenDay.menuBarPercentText)"
    }

    static func sample(accountKey: String, alias: String?, isActive: Bool) -> CodexAccount {
        CodexAccount(
            accountKey: accountKey,
            displayName: alias ?? accountKey,
            alias: alias,
            email: "me@example.com",
            accountName: nil,
            plan: "pro",
            authMode: "chatgpt",
            providerKind: nil,
            baseURL: nil,
            balance: nil,
            isActive: isActive,
            usage: UsageInfo(
                fiveHour: UsageWindow(status: "ok", remainingPercent: 100, total: 100, used: 0, resetAt: nil),
                sevenDay: UsageWindow(status: "ok", remainingPercent: 100, total: 100, used: 0, resetAt: nil)
            ),
            lastUsageAt: nil,
            lastRefreshAt: nil
        )
    }
}

/// API Key provider 的最近一次余额结果；查询失败或不支持时由后端返回 null。
struct BalanceSnapshot: Decodable, Equatable {
    let amount: String
    let currency: String
    let updatedAt: Int64
}

/// 定义账号列表支持的稳定排序方式。
enum AccountSortOrder: String, CaseIterable, Identifiable {
    case added = "默认"
    case quota = "额度"

    var id: String { rawValue }
}

/// 集中处理菜单和管理页共用的账号排序规则。
enum AccountOrdering {
    /// 默认排序保持后端数组不变；额度按 7 天剩余百分比降序，未知值置后且同值保持原顺序。
    static func sorted(_ accounts: [CodexAccount], by order: AccountSortOrder) -> [CodexAccount] {
        guard order == .quota else {
            return accounts
        }

        return accounts.enumerated().sorted { left, right in
            let leftQuota = left.element.usage.sevenDay.remainingPercent
            let rightQuota = right.element.usage.sevenDay.remainingPercent

            switch (leftQuota, rightQuota) {
            case let (leftValue?, rightValue?):
                return leftValue == rightValue ? left.offset < right.offset : leftValue > rightValue
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return left.offset < right.offset
            }
        }.map(\.element)
    }
}

struct UsageInfo: Decodable, Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow
}

struct UsageWindow: Decodable, Equatable {
    let status: String
    let remainingPercent: Int?
    let total: Int?
    let used: Int?
    let resetAt: Date?

    /// 将后端返回的刷新失败状态直接展示出来，避免用“未知”掩盖具体错误。
    var displayText: String {
        if status == "ok", let remainingPercent {
            return "\(remainingPercent)%"
        }
        if isDisplayOverrideStatus {
            return status
        }
        return "未知"
    }

    var menuBarPercentText: String {
        guard status == "ok", let remainingPercent else {
            return "--"
        }
        return "\(remainingPercent)%"
    }

    var resetLabel: String? {
        guard let resetText else {
            return nil
        }
        return "（\(resetText)刷新）"
    }

    var displayTextWithReset: String {
        guard let resetLabel else {
            return displayText
        }
        return "\(displayText)\(resetLabel)"
    }

    var isLowRemaining: Bool {
        guard status == "ok", let remainingPercent else {
            return false
        }
        return remainingPercent < 20
    }

    /// 按剩余额度映射菜单栏绿、黄、红三档视觉状态。
    var menuBarUsageTone: UsageTone {
        guard status == "ok", let remainingPercent else {
            return .unavailable
        }
        if remainingPercent < 20 {
            return .low
        }
        if remainingPercent < 50 {
            return .warning
        }
        return .available
    }

    private var resetText: String? {
        guard let resetAt else {
            return nil
        }
        return UsageResetDateFormatter.string(from: resetAt)
    }

    /// 识别后端透传的刷新失败文案，内置状态仍走本地化降级显示。
    private var isDisplayOverrideStatus: Bool {
        !["unknown", "missing_auth", "network_error", "http_error"].contains(status) && !status.isEmpty
    }

    var detailText: String {
        switch status {
        case "ok":
            return "可用"
        case "missing_auth":
            return "缺少认证信息"
        case "network_error":
            return "网络错误"
        case "http_error":
            return "接口错误"
        default:
            return "未知状态"
        }
    }
}

/// 表示额度可用、警告、低额度和不可用四种视觉状态。
enum UsageTone: Equatable {
    case available
    case warning
    case low
    case unavailable
}

private enum UsageResetDateFormatter {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

extension JSONDecoder {
    static var codexAuth: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            if let date = CodexAuthDateParser.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        return decoder
    }
}

private enum CodexAuthDateParser {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let internetFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from value: String) -> Date? {
        fractionalFormatter.date(from: value) ?? internetFormatter.date(from: value)
    }
}

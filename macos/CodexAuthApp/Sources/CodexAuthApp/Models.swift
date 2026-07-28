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

struct CodexAuthState: Decodable, Equatable {
    let schemaVersion: Int
    let codexHome: String
    let activeAccountKey: String?
    let generatedAt: Date
    let refresh: RefreshInfo
    var resetCredits: ResetCreditsInfo? = nil
    let warnings: [String]
    var tokenUsage: TokenUsageInfo? = nil
    let accounts: [CodexAccount]

    var activeAccount: CodexAccount? {
        accounts.first { $0.accountKey == activeAccountKey || $0.isActive }
    }

    static func empty(codexHome: String) -> CodexAuthState {
        CodexAuthState(
            schemaVersion: 1,
            codexHome: codexHome,
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

/// 记录由菜单栏 App 删除的账号，避免账号从主列表消失后无法追踪。
struct DeletedAccountRecord: Codable, Equatable, Identifiable {
    let accountKey: String
    let label: String
    let detail: String
    let deletedAt: Date

    var id: String { accountKey }
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
                deletedAt: Date()
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
        let expiry = expiresAt.map { "  \(UsageResetDateFormatter.string(from: $0))" } ?? ""
        return "重置: \(availableCount)次\(expiry)"
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
    let isActive: Bool
    let usage: UsageInfo
    let lastUsageAt: Date?
    let lastRefreshAt: Date?

    var id: String { accountKey }

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
        if let maskedEmail, !maskedEmail.isEmpty {
            return maskedEmail
        }
        return "账号 \(accountKey.suffix(6))"
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
        usage.fiveHour?.displayTextWithReset
    }

    var sevenDayUsageText: String {
        usage.sevenDay.displayTextWithReset
    }

    /// 返回菜单栏 5 小时片段；窗口不存在时由展示层直接省略。
    var menuBarFiveHourText: String? {
        guard let fiveHour = usage.fiveHour else {
            return nil
        }
        return "5h \(fiveHour.menuBarPercentText)"
    }

    var menuBarSevenDayText: String {
        "7d \(usage.sevenDay.menuBarPercentText)"
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

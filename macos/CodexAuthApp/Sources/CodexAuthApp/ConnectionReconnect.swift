/// 区分统一连接表单中的账号和 API Key 类型，避免使用裸整数驱动界面。
enum ConnectionFormType: Int, Equatable {
    case account
    case apiKey
}

/// 描述详情页重新连接动作，并保留触发动作所需的原连接。
enum ConnectionReconnectAction: Identifiable, Equatable {
    case account(CodexAccount)
    case apiKey(CodexAccount)

    /// 按认证模式选择 OAuth 登录或 Key 重新添加流程。
    init(account: CodexAccount) {
        self = account.isAPIKey ? .apiKey(account) : .account(account)
    }

    /// 使用连接标识稳定关联 SwiftUI sheet。
    var id: String { account.accountKey }

    /// 返回与实际认证流程一致的详情页按钮文案。
    var buttonTitle: String {
        switch self {
        case .account: return "重新登录"
        case .apiKey: return "重新添加 Key"
        }
    }

    /// 返回当前动作携带的连接，供 sheet 和按钮展示复用。
    var account: CodexAccount {
        switch self {
        case .account(let account), .apiKey(let account): return account
        }
    }
}

/// 集中保存统一连接表单的模式与非敏感初始值。
struct ConnectionFormConfiguration: Equatable {
    let title: String
    let initialType: ConnectionFormType
    let allowsTypeSelection: Bool
    let initialAlias: String
    let initialProvider: APIKeyProvider
    let initialBaseURL: String
    let initialAPIKey: String

    /// 保持现有统一添加入口的默认账号模式和类型选择器。
    static let adding = ConnectionFormConfiguration(
        title: "添加连接",
        initialType: .account,
        allowsTypeSelection: true,
        initialAlias: "",
        initialProvider: .openai,
        initialBaseURL: APIKeyProvider.openai.defaultBaseURL,
        initialAPIKey: ""
    )

    /// 从现有 Key 读取可公开元数据，未知 provider 保守回退到中转站。
    static func readdingAPIKey(for account: CodexAccount) -> ConnectionFormConfiguration {
        let provider = APIKeyProvider(rawValue: account.providerKind?.lowercased() ?? "") ?? .relay
        let storedBaseURL = account.baseURL.flatMap { $0.isEmpty ? nil : $0 }
        return ConnectionFormConfiguration(
            title: "重新添加 Key",
            initialType: .apiKey,
            allowsTypeSelection: false,
            initialAlias: account.alias ?? "",
            initialProvider: provider,
            initialBaseURL: storedBaseURL ?? provider.defaultBaseURL,
            initialAPIKey: ""
        )
    }
}

import AppKit
import Foundation

/// 表示菜单和管理窗口使用的 CPA 连接状态。
enum CPAConnectionStatus: Equatable {
    case unknown
    case connected
    case notConfigured
    case unavailable

    /// 返回精简菜单中使用的短状态文案。
    var label: String {
        switch self {
        case .unknown:
            return "CPA 检查中"
        case .connected:
            return "CPA 已连接"
        case .notConfigured:
            return "CPA 未配置"
        case .unavailable:
            return "CPA 未连接"
        }
    }
}

/// 描述 CPA 配置或健康检查失败，并为菜单栏提供可执行的中文提示。
enum CPARuntimeError: LocalizedError, Equatable {
    case missingAPIKey
    case missingInstalledConfiguration
    case invalidInstalledConfiguration(String)
    case missingManagementKey
    case missingAuthDirectory
    case invalidBaseURL(String)
    case nonLocalBaseURL(String)
    case missingAccountIdentity
    case oauthAccountMismatch(expected: String, actual: String)
    case oauthTimedOut
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "尚未配置 CPA API Key。"
        case .missingInstalledConfiguration:
            return "尚未安装 CPA 运行配置。"
        case .invalidInstalledConfiguration(let reason):
            return "CPA 运行配置无效：\(reason)"
        case .missingManagementKey:
            return "CPA 管理密钥未配置。"
        case .missingAuthDirectory:
            return "CPA 认证目录未配置。"
        case .invalidBaseURL(let value):
            return "CPA 地址无效：\(value)"
        case .nonLocalBaseURL(let value):
            return "CPA 必须使用本机地址：\(value)"
        case .missingAccountIdentity:
            return "当前账号缺少可用于核对 CPA 登录的邮箱。"
        case .oauthAccountMismatch(let expected, let actual):
            return "CPA 登录账号不匹配：需要 \(expected)，实际为 \(actual)。"
        case .oauthTimedOut:
            return "CPA 登录等待超时，请重新开启智能路由。"
        case .unavailable(let reason):
            return "CPA 当前不可用：\(reason)"
        }
    }
}

/// 抽象 CPA OAuth 与认证文件状态管理，确保直连认证和智能路由认证互不复制。
protocol CPAOAuthManaging {
    func setRouting(for account: CodexAccount, enabled: Bool, configuration: CPAConfiguration) async throws
}

/// 通过 CPA 官方管理接口完成浏览器 OAuth、账号身份核对和启停控制。
struct URLSessionCPAOAuthManager: CPAOAuthManaging {
    let session: URLSession
    let openBrowser: (URL) -> Bool
    let pollDelayNanoseconds: UInt64
    let maximumPollAttempts: Int

    /// 注入浏览器和轮询参数，使单元测试不打开真实浏览器或等待真实时间。
    init(
        session: URLSession = .shared,
        openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        pollDelayNanoseconds: UInt64 = 1_000_000_000,
        maximumPollAttempts: Int = 120
    ) {
        self.session = session
        self.openBrowser = openBrowser
        self.pollDelayNanoseconds = pollDelayNanoseconds
        self.maximumPollAttempts = maximumPollAttempts
    }

    /// 已有独立会话时只切换禁用状态；缺失或失效时才发起新的 CPA OAuth。
    func setRouting(for account: CodexAccount, enabled: Bool, configuration: CPAConfiguration) async throws {
        guard let expectedEmail = account.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !expectedEmail.isEmpty
        else {
            throw CPARuntimeError.missingAccountIdentity
        }
        let existingFiles = try await listAuthFiles(configuration)
        if let existing = existingFiles.first(where: { $0.matches(email: expectedEmail) }),
           !enabled || existing.isReusable
        {
            try await setDisabled(!enabled, name: existing.name, configuration: configuration)
            return
        }
        guard enabled else { return }

        let previousNames = Set(existingFiles.map(\.name))
        let start = try await startOAuth(configuration)
        guard openBrowser(start.url) else {
            throw CPARuntimeError.unavailable("无法打开浏览器")
        }
        try await waitForOAuth(state: start.state, configuration: configuration)
        let refreshedFiles = try await listAuthFiles(configuration)
        guard let matched = refreshedFiles.first(where: { $0.matches(email: expectedEmail) }) else {
            let newlyAdded = refreshedFiles.filter {
                !previousNames.contains($0.name) && ($0.type ?? "").lowercased() == "codex"
            }
            for file in newlyAdded {
                try? await setDisabled(true, name: file.name, configuration: configuration)
            }
            let actual = newlyAdded.compactMap(\.email).first ?? "未知账号"
            throw CPARuntimeError.oauthAccountMismatch(expected: expectedEmail, actual: actual)
        }
        try await setDisabled(false, name: matched.name, configuration: configuration)
    }

    /// 列出 CPA 认证文件的非敏感元数据，用邮箱匹配独立 OAuth 会话。
    private func listAuthFiles(_ configuration: CPAConfiguration) async throws -> [CPAAuthFile] {
        let data = try await request(path: "auth-files", configuration: configuration)
        return try JSONDecoder().decode(CPAAuthFilesResponse.self, from: data).files
    }

    /// 请求 CPA 生成 Codex OAuth 地址和一次性状态标识。
    private func startOAuth(_ configuration: CPAConfiguration) async throws -> CPAOAuthStart {
        let data = try await request(
            path: "codex-auth-url",
            queryItems: [URLQueryItem(name: "is_webui", value: "true")],
            configuration: configuration
        )
        return try JSONDecoder().decode(CPAOAuthStart.self, from: data)
    }

    /// 轮询 CPA 授权结果，错误和超时都不会提交智能池成员状态。
    private func waitForOAuth(state: String, configuration: CPAConfiguration) async throws {
        for _ in 0..<maximumPollAttempts {
            let data = try await request(
                path: "get-auth-status",
                queryItems: [URLQueryItem(name: "state", value: state)],
                configuration: configuration
            )
            let status = try JSONDecoder().decode(CPAOAuthStatus.self, from: data)
            switch status.status {
            case "ok": return
            case "error": throw CPARuntimeError.unavailable(status.error ?? "OAuth failed")
            default:
                if pollDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: pollDelayNanoseconds)
                }
            }
        }
        throw CPARuntimeError.oauthTimedOut
    }

    /// 使用 CPA 状态接口禁用或启用指定认证文件，关闭路由时保留授权。
    private func setDisabled(_ disabled: Bool, name: String, configuration: CPAConfiguration) async throws {
        let body = try JSONEncoder().encode(CPAAuthFileStatusRequest(name: name, disabled: disabled))
        _ = try await request(path: "auth-files/status", method: "PATCH", body: body, configuration: configuration)
    }

    /// 统一构造带管理密钥的本机请求，并将非成功响应转换为可展示错误。
    private func request(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        configuration: CPAConfiguration
    ) async throws -> Data {
        guard let managementKey = configuration.managementKey else {
            throw CPARuntimeError.missingManagementKey
        }
        var components = URLComponents(
            url: configuration.managementBaseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else {
            throw CPARuntimeError.invalidBaseURL(configuration.baseURL.absoluteString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 5
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CPARuntimeError.unavailable("management HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }
}

/// 对应 CPA OAuth 启动响应中的浏览器地址和状态标识。
private struct CPAOAuthStart: Decodable {
    let url: URL
    let state: String
}

/// 对应 CPA OAuth 状态轮询的最小响应。
private struct CPAOAuthStatus: Decodable {
    let status: String
    let error: String?
}

/// 对应 CPA 认证文件列表的非敏感字段。
private struct CPAAuthFilesResponse: Decodable {
    let files: [CPAAuthFile]
}

/// 用于按账号身份和健康状态选择 CPA OAuth 文件。
private struct CPAAuthFile: Decodable {
    let name: String
    let type: String?
    let email: String?
    let disabled: Bool?
    let unavailable: Bool?
    let status: String?

    /// 邮箱比较忽略大小写，但不接受掩码或模糊匹配。
    func matches(email expected: String) -> Bool {
        email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expected
    }

    /// 只有 CPA 未报告不可用或终止性状态时才复用现有授权。
    var isReusable: Bool {
        guard unavailable != true else { return false }
        let value = status?.lowercased() ?? ""
        return !["invalid", "revoked", "error", "failed"].contains { value.contains($0) }
    }
}

/// CPA 认证文件启停请求不包含任何 Token 内容。
private struct CPAAuthFileStatusRequest: Encodable {
    let name: String
    let disabled: Bool
}

/// 保存单次智能启动所需的本机 CPA 连接参数。
struct CPAConfiguration: Equatable {
    static let defaultBaseURL = "http://127.0.0.1:8317/v1"
    static let apiKeyEnvironmentName = "CODEX_AUTH_CPA_API_KEY"

    let baseURL: URL
    let apiKey: String
    let managementKey: String?
    let authDirectoryPath: String?

    /// 校验地址、协议和本机绑定，避免把账号请求意外转发到远端代理。
    init(
        baseURLString: String,
        apiKey: String,
        managementKey: String? = nil,
        authDirectoryPath: String? = nil
    ) throws {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw CPARuntimeError.missingAPIKey
        }
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased()
        else {
            throw CPARuntimeError.invalidBaseURL(baseURLString)
        }
        guard ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw CPARuntimeError.nonLocalBaseURL(baseURLString)
        }
        self.baseURL = url
        self.apiKey = trimmedKey
        self.managementKey = managementKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.authDirectoryPath = authDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// 返回 CPA 的模型端点，用于在打开终端前验证服务和客户端密钥。
    var modelsURL: URL {
        baseURL.appendingPathComponent("models")
    }

    /// 返回只允许本机访问的 CPA 管理 API 根地址。
    var managementBaseURL: URL {
        baseURL.deletingLastPathComponent().appendingPathComponent("v0/management")
    }
}

/// 统一用户级 CPA 安装目录，避免桌面 App 依赖 shell 环境变量。
enum CPAInstallationPaths {
    /// 返回应用支持目录中的客户端配置文件路径。
    static func clientConfigurationURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Codex Auth", isDirectory: true)
            .appendingPathComponent("CPA", isDirectory: true)
            .appendingPathComponent("client.json")
    }
}

/// 抽象 CPA 配置来源，便于后续切换到设置页和钥匙串存储。
protocol CPAConfigurationProviding {
    func load() throws -> CPAConfiguration
}

/// 第一阶段从进程环境读取 CPA 参数，不修改用户全局 Codex 配置。
struct EnvironmentCPAConfigurationProvider: CPAConfigurationProviding {
    let environment: [String: String]

    /// 使用固定的本机默认地址，并要求显式提供客户端 API Key。
    func load() throws -> CPAConfiguration {
        try CPAConfiguration(
            baseURLString: environment["CODEX_AUTH_CPA_BASE_URL"] ?? CPAConfiguration.defaultBaseURL,
            apiKey: environment[CPAConfiguration.apiKeyEnvironmentName] ?? "",
            managementKey: environment["CODEX_AUTH_CPA_MANAGEMENT_KEY"],
            authDirectoryPath: environment["CODEX_AUTH_CPA_AUTH_DIR"]
        )
    }
}

/// 优先接受显式环境覆盖，否则读取安装器生成的 0600 客户端配置。
struct InstalledCPAConfigurationProvider: CPAConfigurationProviding {
    let environment: [String: String]
    let configurationURL: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configurationURL: URL = CPAInstallationPaths.clientConfigurationURL()
    ) {
        self.environment = environment
        self.configurationURL = configurationURL
    }

    /// 解码不含 OAuth 凭据的本机 CPA 连接配置。
    func load() throws -> CPAConfiguration {
        let hasInstalledConfiguration = FileManager.default.fileExists(atPath: configurationURL.path)
        if !hasInstalledConfiguration,
           environment[CPAConfiguration.apiKeyEnvironmentName]?.nilIfEmpty != nil
        {
            return try EnvironmentCPAConfigurationProvider(environment: environment).load()
        }
        guard hasInstalledConfiguration else {
            throw CPARuntimeError.missingInstalledConfiguration
        }
        do {
            let data = try Data(contentsOf: configurationURL)
            let document = try JSONDecoder().decode(InstalledCPAConfigurationDocument.self, from: data)
            return try CPAConfiguration(
                baseURLString: environment["CODEX_AUTH_CPA_BASE_URL"] ?? document.baseURL,
                apiKey: environment[CPAConfiguration.apiKeyEnvironmentName] ?? document.apiKey,
                managementKey: environment["CODEX_AUTH_CPA_MANAGEMENT_KEY"] ?? document.managementKey,
                authDirectoryPath: environment["CODEX_AUTH_CPA_AUTH_DIR"] ?? document.authDirectory
            )
        } catch let error as CPARuntimeError {
            throw error
        } catch {
            throw CPARuntimeError.invalidInstalledConfiguration(error.localizedDescription)
        }
    }
}

/// 对应安装器写入的最小客户端配置结构。
private struct InstalledCPAConfigurationDocument: Decodable {
    let baseURL: String
    let apiKey: String
    let managementKey: String?
    let authDirectory: String?

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case apiKey = "api_key"
        case managementKey = "management_key"
        case authDirectory = "auth_directory"
    }
}

/// 隔离 CPA 健康检查，避免启动失败后静默回退到直连账号。
protocol CPAHealthChecking {
    func validate(_ configuration: CPAConfiguration) async throws
}

/// 通过受保护的模型端点同时验证 CPA 可达性和客户端密钥。
struct URLSessionCPAHealthChecker: CPAHealthChecking {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 将网络错误和非成功状态统一转换为可展示的 CPA 错误。
    func validate(_ configuration: CPAConfiguration) async throws {
        var request = URLRequest(url: configuration.modelsURL)
        request.timeoutInterval = 3
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw CPARuntimeError.unavailable("HTTP \(status)")
            }
            let catalog = try CPAModelCatalog.decode(data)
            guard !catalog.modelIDs.isEmpty else {
                throw CPARuntimeError.unavailable("未发现可用模型")
            }
        } catch let error as CPARuntimeError {
            throw error
        } catch {
            throw CPARuntimeError.unavailable(error.localizedDescription)
        }
    }
}

/// 保存健康检查所需的最小 CPA 模型目录，避免仅凭 HTTP 200 误判连接可用。
struct CPAModelCatalog: Equatable {
    let modelIDs: [String]

    /// 解码 OpenAI 兼容模型列表，并忽略空白模型标识。
    static func decode(_ data: Data) throws -> CPAModelCatalog {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return CPAModelCatalog(
            modelIDs: response.data
                .map(\.id)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private struct Response: Decodable {
        let data: [Model]
    }

    private struct Model: Decodable {
        let id: String
    }
}

/// 汇总一次管理队列轮询结果，不直接采用 CPA 的 Token 数值。
struct CPAEventBatch: Equatable {
    let eventCount: Int
    let quotaExceeded: Bool

    static let empty = CPAEventBatch(eventCount: 0, quotaExceeded: false)

    /// 只解析事件数量和 429 状态，保持本地 rollout 统计为 Token 权威来源。
    static func decode(_ data: Data) throws -> CPAEventBatch {
        let records = try JSONDecoder().decode([CPAUsageQueueRecord].self, from: data)
        return CPAEventBatch(
            eventCount: records.count,
            quotaExceeded: records.contains { $0.fail?.statusCode == 429 }
        )
    }
}

/// 抽象 CPA 管理事件轮询，便于 AppState 测试不访问真实服务。
protocol CPAEventPolling {
    func poll(_ configuration: CPAConfiguration) async throws -> CPAEventBatch
}

/// 从受管理密钥保护的队列弹出有限数量事件。
struct URLSessionCPAEventPoller: CPAEventPolling {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 请求 CPA v7.2.109 的 usage queue，并识别其中的 429 失败。
    func poll(_ configuration: CPAConfiguration) async throws -> CPAEventBatch {
        guard let managementKey = configuration.managementKey else {
            throw CPARuntimeError.missingManagementKey
        }
        var components = URLComponents(
            url: configuration.managementBaseURL.appendingPathComponent("usage-queue"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "count", value: "100")]
        guard let url = components?.url else {
            throw CPARuntimeError.invalidBaseURL(configuration.baseURL.absoluteString)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CPARuntimeError.unavailable("management HTTP \(status)")
        }
        return try CPAEventBatch.decode(data)
    }
}

/// 对应 CPA usage queue 中用于刷新决策的最小字段。
private struct CPAUsageQueueRecord: Decodable {
    let fail: Failure?

    struct Failure: Decodable {
        let statusCode: Int?

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
        }
    }
}

/// 生成智能启动子进程使用的密钥和本机代理绕过环境。
enum CodexSmartLaunchEnvironment {
    private static let localHosts = ["127.0.0.1", "localhost", "::1"]

    /// 保留已有绕过规则，并确保大小写变量都覆盖 CPA 的本机地址。
    static func build(apiKey: String, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = [CPAConfiguration.apiKeyEnvironmentName: apiKey]
        for name in ["NO_PROXY", "no_proxy"] {
            environment[name] = mergedProxyBypass(inherited[name])
        }
        return environment
    }

    /// 合并逗号分隔的代理绕过项，忽略空值和大小写重复项。
    private static func mergedProxyBypass(_ existing: String?) -> String {
        var entries = (existing ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var normalized = Set(entries.map { $0.lowercased() })
        for host in localHosts where normalized.insert(host.lowercased()).inserted {
            entries.append(host)
        }
        return entries.joined(separator: ",")
    }
}

/// 生成只对当前 Codex CLI 进程生效的 CPA provider 参数。
enum CodexSmartLaunchCommand {
    /// 构造新建智能会话的完整 shell 命令，客户端密钥只通过环境变量传递。
    static func build(configuration: CPAConfiguration) -> String {
        let overrides = [
            #"model_provider="codex_auth_cpa""#,
            #"model_providers.codex_auth_cpa.name="Codex Auth CPA""#,
            #"model_providers.codex_auth_cpa.base_url="\#(configuration.baseURL.absoluteString)""#,
            #"model_providers.codex_auth_cpa.env_key="CODEX_AUTH_CPA_API_KEY""#,
            #"model_providers.codex_auth_cpa.wire_api="responses""#,
        ]
        let arguments = overrides.flatMap { ["-c", shellQuote($0)] }
        return (["codex"] + arguments).joined(separator: " ")
    }

    /// 使用 POSIX 单引号保护单次配置参数中的空格和特殊字符。
    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// 生成只对本次直连 Codex 进程生效的 provider 参数。
enum CodexDirectLaunchCommand {
    /// 为官方连接显式选择内置 OpenAI provider，避免继承用户全局中转站配置；中转站使用独立 provider。
    static func build(account: CodexAccount) -> String {
        guard account.isAPIKey,
              account.providerKind?.lowercased() == APIKeyProvider.relay.rawValue,
              let baseURL = account.baseURL,
              !baseURL.isEmpty
        else {
            return officialProviderCommand()
        }
        let overrides = [
            #"model_provider="codex_auth_direct""#,
            #"model_providers.codex_auth_direct.name="Codex Auth Direct""#,
            #"model_providers.codex_auth_direct.base_url="\#(baseURL)""#,
            #"model_providers.codex_auth_direct.requires_openai_auth=true"#,
            #"model_providers.codex_auth_direct.wire_api="responses""#,
        ]
        let arguments = overrides.flatMap { ["-c", shellQuote($0)] }
        return (["codex"] + arguments + ["resume", "--last"]).joined(separator: " ")
    }

    /// 只对本次 CLI 进程覆盖 provider，确保账号和官方 Key 不被全局自定义 provider 劫持。
    private static func officialProviderCommand() -> String {
        let argument = shellQuote(#"model_provider="openai""#)
        return "codex -c \(argument) resume --last"
    }

    /// 使用 POSIX 单引号保护单次配置参数中的特殊字符。
    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private extension String {
    /// 将空白字符串规整为 nil，避免把空密钥或目录当成已配置。
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 抽象 Terminal 临时启动脚本，便于测试密钥不会出现在 AppleScript 参数中。
protocol TerminalLaunchScriptWriting {
    func create(command: String, environment: [String: String]) throws -> URL
}

/// 在系统临时目录创建仅当前用户可读的自删除启动脚本。
struct TemporaryTerminalLaunchScriptWriter: TerminalLaunchScriptWriting {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// 写入后设置 0700 权限；脚本启动后先删除自身，再执行 Codex。
    func create(command: String, environment: [String: String]) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("codex-auth-smart-launch", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("launch-\(UUID().uuidString).command")
        let exports = environment
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellQuote($0.value))" }
            .joined(separator: "\n")
        let script = """
        #!/bin/zsh
        \(exports)
        /bin/rm -f -- "$0"
        exec \(command)
        """
        try Data(script.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// 对写入临时脚本的环境值执行 POSIX 单引号转义。
    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

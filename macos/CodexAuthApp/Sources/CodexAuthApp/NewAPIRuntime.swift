import AppKit
import CFNetwork
import Darwin
import Foundation

/// 表示桌面端可展示的 NewAPI 用户级服务状态。
enum NewAPIServiceStatus: Equatable {
    case unknown
    case notInstalled
    case stopped
    case starting
    case setupRequired
    case tokenRequired
    case tokenInvalid
    case running
    case unavailable
    case incompatible

    /// 返回菜单栏和设置页共用的短状态文案。
    var label: String {
        switch self {
        case .unknown: return "NewAPI 检查中"
        case .notInstalled: return "NewAPI 未安装"
        case .stopped: return "NewAPI 已关闭"
        case .starting: return "NewAPI 启动中"
        case .setupRequired: return "NewAPI 待初始化"
        case .tokenRequired: return "NewAPI Token 未配置"
        case .tokenInvalid: return "NewAPI Token 无效"
        case .running: return "NewAPI 已连接"
        case .unavailable: return "NewAPI 不可用"
        case .incompatible: return "NewAPI 配置不兼容"
        }
    }

    /// 返回收起菜单栏时使用的短状态，确保 NewAPI 模式不依赖颜色表达健康度。
    var menuBarText: String {
        switch self {
        case .running: return "自动"
        case .starting: return "NewAPI · 启动中"
        case .setupRequired: return "NewAPI · 待初始化"
        case .tokenRequired: return "NewAPI · 缺 Token"
        case .tokenInvalid: return "NewAPI · Token 无效"
        case .notInstalled: return "NewAPI · 未安装"
        case .stopped: return "NewAPI · 已关闭"
        case .unavailable: return "NewAPI · 不可用"
        case .incompatible: return "NewAPI · 配置异常"
        case .unknown: return "NewAPI · 检查中"
        }
    }

    /// 将服务状态映射到菜单栏状态胶囊的颜色语义。
    var menuBarTone: UsageTone {
        switch self {
        case .running: return .available
        case .starting, .setupRequired, .tokenRequired: return .warning
        case .unknown, .notInstalled, .stopped, .tokenInvalid, .unavailable, .incompatible: return .unavailable
        }
    }
}

/// 描述 NewAPI 配置、服务控制和健康检查失败。
enum NewAPIRuntimeError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case setupRequired
    case missingInstalledConfiguration
    case missingLaunchAgent
    case invalidInstalledConfiguration(String)
    case invalidBaseURL(String)
    case nonLocalBaseURL(String)
    case incompatibleConfiguration(String)
    case serviceCommandFailed(String)
    case unavailable(String)
    case managedModelUnavailable(String)
    case managedCPAChannelConfigurationFailed(String)
    case browserOpenFailed

    /// 返回可直接展示给本机管理员的错误说明。
    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "尚未配置 NewAPI 调用 Token。请先在 NewAPI 网页创建 Token，再粘贴到 Codex Auth 设置。"
        case .invalidAPIKey: return "NewAPI 调用 Token 无效，请在 Codex Auth 设置中更新。"
        case .setupRequired: return "NewAPI 尚未初始化，请先在管理网页创建管理员。"
        case .missingInstalledConfiguration: return "尚未安装 NewAPI 运行配置。"
        case .missingLaunchAgent: return "尚未安装 NewAPI 用户级服务。"
        case .invalidInstalledConfiguration(let reason): return "NewAPI 运行配置无效：\(reason)"
        case .invalidBaseURL(let value): return "NewAPI 地址无效：\(value)"
        case .nonLocalBaseURL(let value): return "Codex Auth 只接管本机 NewAPI 地址：\(value)"
        case .incompatibleConfiguration(let reason): return "NewAPI 配置不兼容：\(reason)"
        case .serviceCommandFailed(let reason): return "NewAPI 服务控制失败：\(reason)"
        case .unavailable(let reason): return "NewAPI 当前不可用：\(reason)"
        case .managedModelUnavailable(let model): return "NewAPI 没有可用于默认分组的 \(model) 渠道。"
        case .managedCPAChannelConfigurationFailed(let reason): return "NewAPI 的 CPA 默认渠道配置失败：\(reason)"
        case .browserOpenFailed: return "无法使用系统浏览器打开 NewAPI 管理页。"
        }
    }
}

/// 保存全局路由和健康检查需要的本机 NewAPI 连接参数。
struct NewAPIConfiguration: Equatable {
    static let defaultBaseURL = "http://127.0.0.1:3000/v1"

    let baseURL: URL
    let apiKey: String
    let runtimeVersion: String
    let clientConfigurationURL: URL

    /// 校验固定回环地址，同时允许首次初始化阶段暂时缺少调用 Token。
    init(
        baseURLString: String,
        apiKey: String,
        runtimeVersion: String,
        clientConfigurationURL: URL
    ) throws {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmedURL),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.user == nil,
            url.password == nil,
            let host = url.host?.lowercased()
        else {
            throw NewAPIRuntimeError.invalidBaseURL(baseURLString)
        }
        guard ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw NewAPIRuntimeError.nonLocalBaseURL(baseURLString)
        }
        self.baseURL = url
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runtimeVersion = runtimeVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientConfigurationURL = clientConfigurationURL
    }

    /// 返回不含 `/v1` 的 NewAPI 服务根地址。
    var serviceRootURL: URL { baseURL.deletingLastPathComponent() }

    /// 返回匿名服务状态端点。
    var statusURL: URL { serviceRootURL.appendingPathComponent("api/status") }

    /// 返回首次安装向导状态端点。
    var setupURL: URL { serviceRootURL.appendingPathComponent("api/setup") }

    /// 返回 OpenAI 兼容模型端点，用于验证调用 Token。
    var modelsURL: URL { baseURL.appendingPathComponent("models") }

    /// 返回不携带登录信息的 NewAPI 原生管理入口。
    var managementPageURL: URL { serviceRootURL }

    /// 返回全局路由使用的命令认证助手路径。
    var credentialHelperURL: URL {
        clientConfigurationURL
            .deletingLastPathComponent()
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex-auth-newapi-credential")
    }
}

/// 统一 NewAPI 安装目录、固定版本和 LaunchAgent 标签。
enum NewAPIInstallationPaths {
    static let launchAgentLabel = "com.codex-auth.newapi"
    static let expectedRuntimeVersion = "v1.0.0-rc.25"

    /// 返回应用支持目录中的 NewAPI 运行根目录。
    static func runtimeRootURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Codex Auth", isDirectory: true)
            .appendingPathComponent("NewAPI", isDirectory: true)
    }

    /// 返回受保护的 NewAPI 客户端配置路径。
    static func clientConfigurationURL(fileManager: FileManager = .default) -> URL {
        runtimeRootURL(fileManager: fileManager).appendingPathComponent("client.json")
    }

    /// 返回安装器创建的用户级 LaunchAgent 路径。
    static func launchAgentURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }
}

/// 定义读取和更新受保护 NewAPI 客户端配置的最小接口。
protocol NewAPIConfigurationStoring {
    func load() throws -> NewAPIConfiguration
    func saveAPIKey(_ apiKey: String) throws
    func clearAPIKey() throws
}

/// 从安装器生成的 `0600` JSON 中读取本机地址和调用 Token。
struct InstalledNewAPIConfigurationStore: NewAPIConfigurationStoring {
    let configurationURL: URL
    let expectedRuntimeVersion: String
    let fileManager: FileManager

    init(
        configurationURL: URL = NewAPIInstallationPaths.clientConfigurationURL(),
        expectedRuntimeVersion: String = NewAPIInstallationPaths.expectedRuntimeVersion,
        fileManager: FileManager = .default
    ) {
        self.configurationURL = configurationURL
        self.expectedRuntimeVersion = expectedRuntimeVersion
        self.fileManager = fileManager
    }

    /// 解码客户端配置并拒绝非固定版本运行时。
    func load() throws -> NewAPIConfiguration {
        let document = try loadDocument()
        guard document.runtimeVersion == expectedRuntimeVersion else {
            throw NewAPIRuntimeError.incompatibleConfiguration(
                "NewAPI 版本必须是 \(expectedRuntimeVersion)，当前为 \(document.runtimeVersion.isEmpty ? "未知" : document.runtimeVersion)"
            )
        }
        return try NewAPIConfiguration(
            baseURLString: document.baseURL,
            apiKey: document.apiKey,
            runtimeVersion: document.runtimeVersion,
            clientConfigurationURL: configurationURL
        )
    }

    /// 原子更新调用 Token，并在替换后重新收紧文件权限。
    func saveAPIKey(_ apiKey: String) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw NewAPIRuntimeError.missingAPIKey }
        var document = try loadDocument()
        document.apiKey = trimmedKey
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(document)
            data.append(0x0A)
            try data.write(to: configurationURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
        } catch let error as NewAPIRuntimeError {
            throw error
        } catch {
            throw NewAPIRuntimeError.invalidInstalledConfiguration(error.localizedDescription)
        }
    }

    /// 清空调用 Token，但保留 NewAPI 地址和版本配置。
    func clearAPIKey() throws {
        var document = try loadDocument()
        document.apiKey = ""
        try write(document)
    }

    /// 原子写回配置并维持仅当前用户可读的权限。
    private func write(_ document: InstalledNewAPIConfigurationDocument) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(document)
            data.append(0x0A)
            try data.write(to: configurationURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
        } catch {
            throw NewAPIRuntimeError.invalidInstalledConfiguration(error.localizedDescription)
        }
    }

    /// 读取安装器拥有的最小配置文档，并统一映射结构错误。
    private func loadDocument() throws -> InstalledNewAPIConfigurationDocument {
        guard fileManager.fileExists(atPath: configurationURL.path) else {
            throw NewAPIRuntimeError.missingInstalledConfiguration
        }
        do {
            return try JSONDecoder().decode(
                InstalledNewAPIConfigurationDocument.self,
                from: Data(contentsOf: configurationURL)
            )
        } catch {
            throw NewAPIRuntimeError.invalidInstalledConfiguration(error.localizedDescription)
        }
    }
}

/// 对应安装器写入的最小 NewAPI 客户端配置结构。
private struct InstalledNewAPIConfigurationDocument: Codable {
    let baseURL: String
    var apiKey: String
    let runtimeVersion: String

    private enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case apiKey = "api_key"
        case runtimeVersion = "runtime_version"
    }
}

/// 定义 NewAPI 服务、安装向导和调用 Token 的本机健康检查。
protocol NewAPIHealthChecking {
    func validateService(_ configuration: NewAPIConfiguration) async throws
    func isSetupComplete(_ configuration: NewAPIConfiguration) async throws -> Bool
    func validateAPIKey(_ configuration: NewAPIConfiguration) async throws
}

/// 提供不继承系统代理设置的 NewAPI 回环网络会话。
enum NewAPILoopbackURLSession {
    /// 使用临时存储并关闭 HTTP、HTTPS、SOCKS、PAC 与自动代理发现。
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
            kCFNetworkProxiesProxyAutoConfigEnable as String: false,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: false,
        ]
        return URLSession(configuration: configuration)
    }()
}

/// 通过 NewAPI 官方状态、安装向导和模型端点完成运行时校验。
struct URLSessionNewAPIHealthChecker: NewAPIHealthChecking {
    let session: URLSession

    init(session: URLSession = NewAPILoopbackURLSession.shared) {
        self.session = session
    }

    /// 要求匿名状态端点返回成功响应。
    func validateService(_ configuration: NewAPIConfiguration) async throws {
        let data = try await fetch(configuration.statusURL)
        do {
            let response = try JSONDecoder().decode(NewAPIStatusResponse.self, from: data)
            guard response.success else { throw NewAPIRuntimeError.unavailable("状态接口报告失败") }
        } catch let error as NewAPIRuntimeError {
            throw error
        } catch {
            throw NewAPIRuntimeError.unavailable("状态响应无效")
        }
    }

    /// 返回官方安装向导是否已经创建管理员并完成初始化。
    func isSetupComplete(_ configuration: NewAPIConfiguration) async throws -> Bool {
        let data = try await fetch(configuration.setupURL)
        do {
            let response = try JSONDecoder().decode(NewAPISetupResponse.self, from: data)
            guard response.success else { throw NewAPIRuntimeError.unavailable("安装状态接口报告失败") }
            return response.data.status
        } catch let error as NewAPIRuntimeError {
            throw error
        } catch {
            throw NewAPIRuntimeError.unavailable("安装状态响应无效")
        }
    }

    /// 使用调用 Token 请求模型目录，区分无效凭据和普通服务故障。
    func validateAPIKey(_ configuration: NewAPIConfiguration) async throws {
        guard !configuration.apiKey.isEmpty else { throw NewAPIRuntimeError.missingAPIKey }
        var request = URLRequest(url: configuration.modelsURL)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NewAPIRuntimeError.unavailable("模型接口返回了非 HTTP 响应")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw NewAPIRuntimeError.invalidAPIKey
            }
            guard (200..<300).contains(http.statusCode) else {
                throw NewAPIRuntimeError.unavailable("模型接口 HTTP \(http.statusCode)")
            }
            let catalog = try NewAPIModelCatalog.decode(data)
            guard catalog.modelIDs.contains(NewAPIModelCatalog.managedModel) else {
                throw NewAPIRuntimeError.managedModelUnavailable(NewAPIModelCatalog.managedModel)
            }
        } catch let error as NewAPIRuntimeError {
            throw error
        } catch {
            throw NewAPIRuntimeError.unavailable(error.localizedDescription)
        }
    }

    /// 执行匿名回环请求并统一转换 HTTP 与网络错误。
    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NewAPIRuntimeError.unavailable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            return data
        } catch let error as NewAPIRuntimeError {
            throw error
        } catch {
            throw NewAPIRuntimeError.unavailable(error.localizedDescription)
        }
    }
}

/// 保存健康检查所需的最小 NewAPI 模型目录。
struct NewAPIModelCatalog: Equatable {
    static let managedModel = "gpt-5.6-sol"

    let modelIDs: [String]

    /// 解码 OpenAI 兼容模型列表并忽略空白标识。
    static func decode(_ data: Data) throws -> NewAPIModelCatalog {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return NewAPIModelCatalog(
            modelIDs: response.data.map(\.id).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        )
    }

    private struct Response: Decodable { let data: [Model] }
    private struct Model: Decodable { let id: String }
}

/// 定义在 NewAPI 停止期间同步应用专属 CPA 渠道的能力。
protocol NewAPICPAChannelProvisioning {
    func configure() async throws
}

/// 调用 App Bundle 内经过版本固定的配置器，不向命令参数传递任何密钥。
struct BundledNewAPICPAChannelProvisioner: NewAPICPAChannelProvisioning {
    let runner: CommandRunning
    let scriptURL: URL
    let scriptIsExecutable: (URL) -> Bool

    init(
        runner: CommandRunning = ProcessCommandRunner(),
        scriptURL: URL = Bundle.main.resourceURL?
            .appendingPathComponent("configure-newapi-cpa-channel.sh")
            ?? URL(fileURLWithPath: "/nonexistent/configure-newapi-cpa-channel.sh"),
        scriptIsExecutable: @escaping (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    ) {
        self.runner = runner
        self.scriptURL = scriptURL
        self.scriptIsExecutable = scriptIsExecutable
    }

    /// 执行无参数配置器，并把稳定错误输出映射为桌面运行时错误。
    func configure() async throws {
        guard scriptIsExecutable(scriptURL) else {
            throw NewAPIRuntimeError.managedCPAChannelConfigurationFailed("配置器缺失或不可执行")
        }
        do {
            let result = try await runner.run(executableURL: scriptURL, arguments: [])
            guard result.exitCode == 0 else {
                let stderr = String(data: result.standardError, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = stderr?.isEmpty == false ? stderr! : "配置器退出码为 \(result.exitCode)"
                throw NewAPIRuntimeError.managedCPAChannelConfigurationFailed(reason)
            }
        } catch let error as NewAPIRuntimeError {
            throw error
        } catch {
            throw NewAPIRuntimeError.managedCPAChannelConfigurationFailed(error.localizedDescription)
        }
    }
}

/// 对应 NewAPI 匿名状态响应的必要字段。
private struct NewAPIStatusResponse: Decodable {
    let success: Bool
}

/// 对应 NewAPI 安装向导状态响应的必要字段。
private struct NewAPISetupResponse: Decodable {
    let success: Bool
    let data: SetupData

    struct SetupData: Decodable { let status: Bool }
}

/// 定义 NewAPI 用户级服务所需的 launchctl 命令执行能力。
protocol NewAPIServiceCommandRunning {
    func run(arguments: [String]) async throws -> CommandResult
}

/// 使用固定系统 launchctl 路径执行 NewAPI 服务命令。
struct LaunchctlNewAPICommandRunner: NewAPIServiceCommandRunning {
    let runner: CommandRunning

    init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    /// 调用 `/bin/launchctl`，不依赖桌面进程 PATH。
    func run(arguments: [String]) async throws -> CommandResult {
        try await runner.run(executableURL: URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments)
    }
}

/// 定义 NewAPI 用户级服务的启停和状态查询接口。
protocol NewAPIServiceControlling {
    func start() async throws
    func stop() async throws
    func status() async -> NewAPIServiceStatus
}

/// 控制应用安装的 NewAPI LaunchAgent。
struct LaunchAgentNewAPIServiceController: NewAPIServiceControlling {
    let runner: NewAPIServiceCommandRunning
    let userID: uid_t
    let launchAgentURL: URL
    let fileExists: (URL) -> Bool

    init(
        runner: NewAPIServiceCommandRunning = LaunchctlNewAPICommandRunner(),
        userID: uid_t = getuid(),
        launchAgentURL: URL = NewAPIInstallationPaths.launchAgentURL(),
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.runner = runner
        self.userID = userID
        self.launchAgentURL = launchAgentURL
        self.fileExists = fileExists
    }

    /// 通过 enable 和 bootstrap 加载 RunAtLoad 服务。
    func start() async throws {
        guard fileExists(launchAgentURL) else { throw NewAPIRuntimeError.missingLaunchAgent }
        try await requireSuccess(["enable", serviceTarget])
        let bootstrap = try await runner.run(arguments: ["bootstrap", domainTarget, launchAgentURL.path])
        if bootstrap.exitCode == 5 {
            try await requireSuccess(["print", serviceTarget])
        } else if bootstrap.exitCode != 0 {
            throw serviceError(bootstrap)
        }
    }

    /// 先移出服务再禁用自动启动；未加载状态按幂等成功处理。
    func stop() async throws {
        guard fileExists(launchAgentURL) else { return }
        let bootout = try await runner.run(arguments: ["bootout", serviceTarget])
        let disable = try await runner.run(arguments: ["disable", serviceTarget])
        guard disable.exitCode == 0 else { throw serviceError(disable) }
        guard bootout.exitCode == 0 || bootout.exitCode == 3 || bootout.exitCode == 5 else {
            throw serviceError(bootout)
        }
    }

    /// 通过 launchctl print 判断服务是否已加载。
    func status() async -> NewAPIServiceStatus {
        guard fileExists(launchAgentURL) else { return .notInstalled }
        guard let result = try? await runner.run(arguments: ["print", serviceTarget]) else { return .unavailable }
        return result.exitCode == 0 ? .running : .stopped
    }

    private var domainTarget: String { "gui/\(userID)" }
    private var serviceTarget: String { "\(domainTarget)/\(NewAPIInstallationPaths.launchAgentLabel)" }

    /// 要求单条 launchctl 命令成功。
    private func requireSuccess(_ arguments: [String]) async throws {
        let result = try await runner.run(arguments: arguments)
        guard result.exitCode == 0 else { throw serviceError(result) }
    }

    /// 把 launchctl 失败输出转换为稳定错误。
    private func serviceError(_ result: CommandResult) -> NewAPIRuntimeError {
        let stderr = String(data: result.standardError, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .serviceCommandFailed(stderr?.isEmpty == false ? stderr! : "launchctl exited with \(result.exitCode)")
    }
}

/// 定义打开 NewAPI 管理网页的系统能力。
protocol NewAPIBrowserOpening {
    func open(_ url: URL) -> Bool
}

/// 使用默认浏览器打开 NewAPI 原生管理网页。
struct SystemNewAPIBrowser: NewAPIBrowserOpening {
    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

/// 定义 AppState 编排 NewAPI 生命周期所需的稳定接口。
protocol NewAPIServiceRuntimeProtocol {
    func startAndValidate() async throws -> NewAPIConfiguration
    func stop() async throws
    func status() async -> NewAPIServiceStatus
    func openManagementPage() async throws
    func saveAPIKey(_ apiKey: String) throws
    func hasSavedAPIKey() -> Bool
    func clearAPIKey() throws
}

/// 编排 NewAPI LaunchAgent、官方健康端点、Token 和管理网页入口。
struct NewAPIServiceRuntime: NewAPIServiceRuntimeProtocol {
    /// 覆盖原生 NewAPI 首次启动和 SQLite 迁移所需的短暂就绪窗口。
    static let defaultStartupRetryDelaysNanoseconds: [UInt64] = [
        100_000_000,
        250_000_000,
        500_000_000,
        1_000_000_000,
        2_000_000_000,
        4_000_000_000,
        8_000_000_000,
    ]

    let serviceController: NewAPIServiceControlling
    let configurationStore: NewAPIConfigurationStoring
    let healthChecker: NewAPIHealthChecking
    let browser: NewAPIBrowserOpening
    let credentialHelperIsExecutable: (URL) -> Bool
    let startupRetryDelaysNanoseconds: [UInt64]
    let sleep: (UInt64) async -> Void

    init(
        serviceController: NewAPIServiceControlling = LaunchAgentNewAPIServiceController(),
        configurationStore: NewAPIConfigurationStoring = InstalledNewAPIConfigurationStore(),
        healthChecker: NewAPIHealthChecking = URLSessionNewAPIHealthChecker(),
        browser: NewAPIBrowserOpening = SystemNewAPIBrowser(),
        credentialHelperIsExecutable: @escaping (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        },
        startupRetryDelaysNanoseconds: [UInt64] = NewAPIServiceRuntime.defaultStartupRetryDelaysNanoseconds,
        sleep: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.serviceController = serviceController
        self.configurationStore = configurationStore
        self.healthChecker = healthChecker
        self.browser = browser
        self.credentialHelperIsExecutable = credentialHelperIsExecutable
        self.startupRetryDelaysNanoseconds = startupRetryDelaysNanoseconds
        self.sleep = sleep
    }

    /// 启动服务，等待匿名端点就绪，再要求完成初始化并校验调用 Token。
    func startAndValidate() async throws -> NewAPIConfiguration {
        try await serviceController.start()
        let configuration = try validatedInstalledConfiguration()
        try await validateStartupReadiness(configuration)
        guard try await healthChecker.isSetupComplete(configuration) else {
            throw NewAPIRuntimeError.setupRequired
        }
        try await healthChecker.validateAPIKey(configuration)
        return configuration
    }

    /// 明确关闭 NewAPI 用户级服务，SQLite 随进程一同关闭。
    func stop() async throws {
        try await serviceController.stop()
    }

    /// 合并 launchd、安装状态、首次初始化和 Token 健康状态。
    func status() async -> NewAPIServiceStatus {
        let serviceStatus = await serviceController.status()
        guard serviceStatus == .running else { return serviceStatus }
        do {
            let configuration = try validatedInstalledConfiguration()
            try await healthChecker.validateService(configuration)
            guard try await healthChecker.isSetupComplete(configuration) else { return .setupRequired }
            guard !configuration.apiKey.isEmpty else { return .tokenRequired }
            try await healthChecker.validateAPIKey(configuration)
            return .running
        } catch NewAPIRuntimeError.invalidAPIKey {
            return .tokenInvalid
        } catch NewAPIRuntimeError.missingAPIKey {
            return .tokenRequired
        } catch NewAPIRuntimeError.incompatibleConfiguration {
            return .incompatible
        } catch {
            return .unavailable
        }
    }

    /// 确保服务已启动并可达，再打开不包含任何凭据的 NewAPI 管理网页。
    func openManagementPage() async throws {
        try await serviceController.start()
        let configuration = try validatedInstalledConfiguration()
        try await validateStartupReadiness(configuration)
        guard browser.open(configuration.managementPageURL) else {
            throw NewAPIRuntimeError.browserOpenFailed
        }
    }

    /// 保存用户从 NewAPI 网页创建的调用 Token。
    func saveAPIKey(_ apiKey: String) throws {
        try configurationStore.saveAPIKey(apiKey)
    }

    /// 判断本机配置中是否存在调用 Token，不返回真实凭据。
    func hasSavedAPIKey() -> Bool {
        (try? configurationStore.load().apiKey.isEmpty == false) ?? false
    }

    /// 清空本机保存的调用 Token。
    func clearAPIKey() throws {
        try configurationStore.clearAPIKey()
    }

    /// 检查客户端配置版本和凭据助手是否属于当前固定运行时。
    private func validatedInstalledConfiguration() throws -> NewAPIConfiguration {
        let configuration = try configurationStore.load()
        guard credentialHelperIsExecutable(configuration.credentialHelperURL) else {
            throw NewAPIRuntimeError.incompatibleConfiguration("NewAPI 凭据助手缺失或不可执行")
        }
        return configuration
    }

    /// 仅对启动阶段的瞬时不可达进行退避重试，确定性错误立即返回。
    private func validateStartupReadiness(_ configuration: NewAPIConfiguration) async throws {
        var remainingDelays = startupRetryDelaysNanoseconds
        while true {
            do {
                try await healthChecker.validateService(configuration)
                return
            } catch let error as NewAPIRuntimeError {
                guard case .unavailable = error, !remainingDelays.isEmpty else { throw error }
                await sleep(remainingDelays.removeFirst())
            }
        }
    }
}

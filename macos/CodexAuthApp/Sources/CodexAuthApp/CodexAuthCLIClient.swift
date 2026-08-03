import Foundation

struct CommandResult: Equatable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
}

protocol CommandRunning {
    func run(executableURL: URL, arguments: [String], environment: [String: String]?) async throws -> CommandResult
}

extension CommandRunning {
    /// 保持普通 CLI 调用的简洁接口，仅智能启动需要附加环境变量。
    func run(executableURL: URL, arguments: [String]) async throws -> CommandResult {
        try await run(executableURL: executableURL, arguments: arguments, environment: nil)
    }
}

protocol CodexAuthClientProtocol {
    func loadState(apiMode: CodexAuthAPIMode) async throws -> CodexAuthState
    func loadTokenUsage(mode: TokenUsageScanMode) async throws -> TokenUsageInfo
    func refresh(apiMode: CodexAuthAPIMode) async throws -> CodexAuthState
    func switchAccount(accountKey: String) async throws -> CodexAuthState
    func removeAccount(accountKey: String) async throws -> CodexAuthState
    func setAlias(accountKey: String, alias: String) async throws -> CodexAuthState
    func clearAlias(accountKey: String) async throws -> CodexAuthState
    func setSmartPoolEnabled(accountKey: String, enabled: Bool) async throws -> CodexAuthState
    func syncCPAAccount(accountKey: String, enabled: Bool) async throws
    func reconcileCPAAccounts() async throws
    func login() async throws -> CodexAuthState
    func addAPIKey(alias: String, provider: APIKeyProvider, baseURL: String, apiKey: String) async throws -> CodexAuthState
    func importAuth(path: String, alias: String?) async throws -> CodexAuthState
    func openNewCodexSession(at directoryPath: String) async throws
    func openDirectCodexSession(at directoryPath: String, account: CodexAccount) async throws
    func checkCPAConnection() async -> CPAConnectionStatus
    func pollCPAEvents() async throws -> CPAEventBatch
}

extension CodexAuthClientProtocol {
    /// 未实现 Token 扫描的测试或替代客户端返回明确错误。
    func loadTokenUsage(mode: TokenUsageScanMode) async throws -> TokenUsageInfo {
        throw CodexAuthCLIError.commandFailed("Token usage is unavailable")
    }

    /// 替代客户端未实现 CPA 检查时保持未知状态。
    func checkCPAConnection() async -> CPAConnectionStatus {
        .unknown
    }

    /// 旧测试客户端未实现智能池写入时返回明确错误。
    func setSmartPoolEnabled(accountKey: String, enabled: Bool) async throws -> CodexAuthState {
        throw CodexAuthCLIError.commandFailed("Smart pool updates are unavailable")
    }

    /// 兼容尚未实现 CPA 凭据同步的替代客户端。
    func syncCPAAccount(accountKey: String, enabled: Bool) async throws {}

    /// 兼容尚未实现 CPA 全目录对账的替代客户端。
    func reconcileCPAAccounts() async throws {}

    /// 未实现 Key 创建的替代客户端返回明确错误。
    func addAPIKey(alias: String, provider: APIKeyProvider, baseURL: String, apiKey: String) async throws -> CodexAuthState {
        throw CodexAuthCLIError.commandFailed("API Key connections are unavailable")
    }

    /// 未实现直连启动的替代客户端返回明确错误。
    func openDirectCodexSession(at directoryPath: String, account: CodexAccount) async throws {
        throw CodexAuthCLIError.commandFailed("Direct launch is unavailable")
    }

    /// 兼容尚未实现 CPA 事件轮询的替代客户端。
    func pollCPAEvents() async throws -> CPAEventBatch {
        .empty
    }
}

enum CodexAuthCLIError: LocalizedError, Equatable {
    case commandFailed(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return "命令执行失败：\(message)"
        case .invalidJSON(let message):
            return "无法解析命令输出：\(message)"
        }
    }
}

/// 管理额度刷新代理的本地偏好键、地址校验与子进程环境映射。
enum QuotaProxyConfiguration {
    static let userDefaultsKey = "quotaProxyURL"
    private static let supportedSchemes = ["http", "https", "socks5", "socks5h"]

    /// 校验用户明确填写的代理地址，并生成 curl 同时兼容大小写变量的进程环境。
    static func environment(proxyURL rawValue: String?) -> [String: String]? {
        guard let rawValue else {
            return nil
        }
        let proxyURL = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !proxyURL.isEmpty,
            let components = URLComponents(string: proxyURL),
            let scheme = components.scheme?.lowercased(),
            supportedSchemes.contains(scheme),
            components.host?.isEmpty == false
        else {
            return nil
        }
        return [
            "HTTP_PROXY": proxyURL,
            "HTTPS_PROXY": proxyURL,
            "ALL_PROXY": proxyURL,
            "http_proxy": proxyURL,
            "https_proxy": proxyURL,
            "all_proxy": proxyURL,
        ]
    }
}

struct CodexAuthCLIClient: CodexAuthClientProtocol {
    private static let ghosttyAppURL = URL(fileURLWithPath: "/Applications/Ghostty.app")

    let executableURL: URL
    let runner: CommandRunning
    let fileExists: (URL) -> Bool
    let cpaConfigurationProvider: CPAConfigurationProviding
    let cpaHealthChecker: CPAHealthChecking
    let cpaEventPoller: CPAEventPolling
    let terminalLaunchScriptWriter: TerminalLaunchScriptWriting
    let quotaProxyURLProvider: () -> String?

    /// 注入进程、CPA 和临时脚本依赖，使智能启动在测试中不访问真实服务或认证配置。
    init(
        executableURL: URL = CodexAuthCLIClient.defaultExecutableURL(),
        runner: CommandRunning = ProcessCommandRunner(),
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        cpaConfigurationProvider: CPAConfigurationProviding = InstalledCPAConfigurationProvider(),
        cpaHealthChecker: CPAHealthChecking = URLSessionCPAHealthChecker(),
        cpaEventPoller: CPAEventPolling = URLSessionCPAEventPoller(),
        terminalLaunchScriptWriter: TerminalLaunchScriptWriting = TemporaryTerminalLaunchScriptWriter(),
        quotaProxyURLProvider: @escaping () -> String? = {
            UserDefaults.standard.string(forKey: QuotaProxyConfiguration.userDefaultsKey)
        }
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.fileExists = fileExists
        self.cpaConfigurationProvider = cpaConfigurationProvider
        self.cpaHealthChecker = cpaHealthChecker
        self.cpaEventPoller = cpaEventPoller
        self.terminalLaunchScriptWriter = terminalLaunchScriptWriter
        self.quotaProxyURLProvider = quotaProxyURLProvider
    }

    func loadState(apiMode: CodexAuthAPIMode = .automatic) async throws -> CodexAuthState {
        try await runStateCommand(["gui", "state"] + apiMode.arguments)
    }

    /// 根据协调器请求选择增量缓存扫描或强制全量解析。
    func loadTokenUsage(mode: TokenUsageScanMode) async throws -> TokenUsageInfo {
        let result = try await runner.run(
            executableURL: executableURL,
            arguments: ["gui", "stats"] + mode.arguments
        )
        guard result.exitCode == 0 else {
            let stderr = String(data: result.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexAuthCLIError.commandFailed(stderr?.isEmpty == false ? stderr! : "unknown error")
        }
        do {
            return try JSONDecoder.codexAuth.decode(TokenUsageInfo.self, from: result.standardOutput)
        } catch {
            throw CodexAuthCLIError.invalidJSON(error.localizedDescription)
        }
    }

    func refresh(apiMode: CodexAuthAPIMode = .automatic) async throws -> CodexAuthState {
        try await runStateCommand(
            ["gui", "refresh"] + apiMode.arguments,
            environment: QuotaProxyConfiguration.environment(proxyURL: quotaProxyURLProvider())
        )
    }

    func switchAccount(accountKey: String) async throws -> CodexAuthState {
        try await runStateCommand(["gui", "switch", accountKey])
    }

    func removeAccount(accountKey: String) async throws -> CodexAuthState {
        try await runStateCommand(["gui", "remove", accountKey])
    }

    func setAlias(accountKey: String, alias: String) async throws -> CodexAuthState {
        try await runStateCommand(["gui", "alias", "set", accountKey, alias])
    }

    func clearAlias(accountKey: String) async throws -> CodexAuthState {
        try await runStateCommand(["gui", "alias", "clear", accountKey])
    }

    /// 持久化账号是否参与智能路由池。
    func setSmartPoolEnabled(accountKey: String, enabled: Bool) async throws -> CodexAuthState {
        try await runStateCommand(["gui", "smart-pool", accountKey, enabled ? "include" : "exclude"])
    }

    /// 将单个账号的认证副本同步到独立 CPA 目录，不修改官方 CLI 当前账号。
    func syncCPAAccount(accountKey: String, enabled: Bool) async throws {
        let configuration = try cpaConfigurationProvider.load()
        guard let authDirectoryPath = configuration.authDirectoryPath else {
            throw CPARuntimeError.missingAuthDirectory
        }
        var environment = [String: String]()
        if let managementKey = configuration.managementKey {
            environment["CODEX_AUTH_CPA_MANAGEMENT_KEY"] = managementKey
            environment["CODEX_AUTH_CPA_MANAGEMENT_URL"] = configuration.managementBaseURL
                .appendingPathComponent("codex-api-key")
                .absoluteString
        }
        try await runVoidCommand([
            "gui", "cpa-sync", accountKey, enabled ? "include" : "exclude", authDirectoryPath,
        ], environment: environment.isEmpty ? nil : environment)
    }

    /// 将 CPA 专用认证目录收敛到当前注册表智能池，不传递管理密钥或认证内容。
    func reconcileCPAAccounts() async throws {
        let configuration: CPAConfiguration
        do {
            configuration = try cpaConfigurationProvider.load()
        } catch CPARuntimeError.missingInstalledConfiguration {
            return
        }
        guard let authDirectoryPath = configuration.authDirectoryPath else {
            throw CPARuntimeError.missingAuthDirectory
        }
        try await runVoidCommand(["gui", "cpa-sync", "reconcile", authDirectoryPath])
    }

    func login() async throws -> CodexAuthState {
        try await runStateCommand(["gui", "login"])
    }

    /// 通过环境变量传递密钥，避免敏感值进入进程参数和系统进程列表。
    func addAPIKey(alias: String, provider: APIKeyProvider, baseURL: String, apiKey: String) async throws -> CodexAuthState {
        try await runStateCommand(
            ["gui", "add-key", alias, provider.rawValue, baseURL],
            environment: ["CODEX_AUTH_API_KEY": apiKey]
        )
    }

    func importAuth(path: String, alias: String?) async throws -> CodexAuthState {
        var arguments = ["gui", "import", path]
        if let alias, !alias.isEmpty {
            arguments += ["--alias", alias]
        }
        return try await runStateCommand(arguments)
    }

    /// 使用与智能启动相同的配置和端点检测 CPA，但不打开终端。
    func checkCPAConnection() async -> CPAConnectionStatus {
        do {
            let configuration = try cpaConfigurationProvider.load()
            try await cpaHealthChecker.validate(configuration)
            return .connected
        } catch CPARuntimeError.missingAPIKey {
            return .notConfigured
        } catch CPARuntimeError.missingInstalledConfiguration {
            return .notConfigured
        } catch {
            return .unavailable
        }
    }

    /// 读取并消费 CPA 的增量请求事件，用于触发本地 Token 缓存更新。
    func pollCPAEvents() async throws -> CPAEventBatch {
        let configuration = try cpaConfigurationProvider.load()
        return try await cpaEventPoller.poll(configuration)
    }

    /// 校验本机 CPA 后，以单次 provider 参数和独立环境变量启动官方 Codex CLI。
    func openNewCodexSession(at directoryPath: String) async throws {
        let configuration = try cpaConfigurationProvider.load()
        try await cpaHealthChecker.validate(configuration)
        let command = CodexSmartLaunchCommand.build(configuration: configuration)
        let environment = [CPAConfiguration.apiKeyEnvironmentName: configuration.apiKey]

        try await launchCodexSession(
            at: directoryPath,
            command: command,
            environment: environment,
            ghosttyEnvironmentVariable: CPAConfiguration.apiKeyEnvironmentName
        )
    }

    /// 使用当前直连认证启动 Codex；中转站仅对本次进程附加 provider 覆盖。
    func openDirectCodexSession(at directoryPath: String, account: CodexAccount) async throws {
        try await launchCodexSession(
            at: directoryPath,
            command: CodexDirectLaunchCommand.build(account: account),
            environment: [:],
            ghosttyEnvironmentVariable: nil
        )
    }

    /// 在 Ghostty 或 Terminal 中启动指定 Codex 命令，并按需注入单个受保护环境变量。
    private func launchCodexSession(
        at directoryPath: String,
        command: String,
        environment: [String: String],
        ghosttyEnvironmentVariable: String?
    ) async throws {

        if !fileExists(Self.ghosttyAppURL) {
            try await openNewTerminalCodexSession(
                at: directoryPath,
                command: command,
                environment: environment
            )
            return
        }

        let environmentSetup: String
        let surfaceEnvironment: String
        if let ghosttyEnvironmentVariable {
            environmentSetup = "set launchValue to do shell script \"/usr/bin/printenv \(ghosttyEnvironmentVariable)\""
            surfaceEnvironment = ", environment variables:{\"\(ghosttyEnvironmentVariable)=\" & launchValue}"
        } else {
            environmentSetup = ""
            surfaceEnvironment = ""
        }
        let script = """
        set targetPath to \(appleScriptStringLiteral(directoryPath))
        set initialCommand to \(appleScriptStringLiteral(command)) & linefeed
        \(environmentSetup)
        tell application "Ghostty"
            activate
            set surfaceConfig to new surface configuration from {initial working directory:targetPath, initial input:initialCommand\(surfaceEnvironment)}
            if (count of windows) is 0 then
                new window with configuration surfaceConfig
            else
                new tab in front window with configuration surfaceConfig
            end if
        end tell
        """
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script],
            environment: environment.isEmpty ? nil : environment
        )
        guard result.exitCode == 0 else {
            let stderr = String(data: result.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = String(data: result.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexAuthCLIError.commandFailed(stderr?.isEmpty == false ? stderr! : (stdout ?? "unknown error"))
        }
    }

    /// Terminal 不支持为新标签直接设置环境变量，因此使用 0700 自删除脚本避免密钥进入历史记录。
    private func openNewTerminalCodexSession(
        at directoryPath: String,
        command: String,
        environment: [String: String]
    ) async throws {
        let launchScript = try terminalLaunchScriptWriter.create(command: command, environment: environment)
        let script = """
        set targetPath to \(appleScriptStringLiteral(directoryPath))
        set launchScript to \(appleScriptStringLiteral(launchScript.path))
        tell application "Terminal"
            activate
            do script "cd " & quoted form of targetPath & " && " & quoted form of launchScript
        end tell
        """
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script]
        )
        guard result.exitCode == 0 else {
            let stderr = String(data: result.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = String(data: result.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexAuthCLIError.commandFailed(stderr?.isEmpty == false ? stderr! : (stdout ?? "unknown error"))
        }
    }

    private func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func runStateCommand(
        _ arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> CodexAuthState {
        let result = try await runner.run(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment
        )
        guard result.exitCode == 0 else {
            let stderr = String(data: result.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = String(data: result.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexAuthCLIError.commandFailed(stderr?.isEmpty == false ? stderr! : (stdout ?? "unknown error"))
        }
        do {
            return try JSONDecoder.codexAuth.decode(CodexAuthState.self, from: result.standardOutput)
        } catch {
            throw CodexAuthCLIError.invalidJSON(error.localizedDescription)
        }
    }

    /// 执行无 JSON 返回值的内部 CLI 命令，并统一保留后端英文错误文本。
    private func runVoidCommand(_ arguments: [String], environment: [String: String]? = nil) async throws {
        let result = try await runner.run(executableURL: executableURL, arguments: arguments, environment: environment)
        guard result.exitCode == 0 else {
            let stderr = String(data: result.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = String(data: result.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexAuthCLIError.commandFailed(stderr?.isEmpty == false ? stderr! : (stdout ?? "unknown error"))
        }
    }

    static func defaultExecutableURL() -> URL {
        CodexAuthExecutableResolver.default.resolve()
    }
}

struct CodexAuthExecutableResolver {
    let environment: [String: String]
    let bundleURL: URL?
    let pathEnvironment: String
    let fileExists: (URL) -> Bool

    static var `default`: CodexAuthExecutableResolver {
        CodexAuthExecutableResolver(
            environment: ProcessInfo.processInfo.environment,
            bundleURL: Bundle.main.executableURL,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"] ?? "",
            fileExists: { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
    }

    func resolve() -> URL {
        if let explicitPath = environment["CODEX_AUTH_CLI_PATH"], !explicitPath.isEmpty {
            return URL(fileURLWithPath: explicitPath)
        }

        if let bundled = Bundle.main.url(forResource: "codex-auth", withExtension: nil) {
            return bundled
        }

        if let repoCandidate = repositoryBuildOutputCandidate(), fileExists(repoCandidate) {
            return repoCandidate
        }

        for directory in pathEnvironment.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("codex-auth")
            if fileExists(candidate) {
                return candidate
            }
        }

        return URL(fileURLWithPath: "/usr/local/bin/codex-auth")
    }

    private func repositoryBuildOutputCandidate() -> URL? {
        guard let bundleURL else {
            return nil
        }

        var current = bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = current.appendingPathComponent("zig-out/bin/codex-auth")
            if fileExists(candidate) {
                return candidate
            }
            current.deleteLastPathComponent()
        }
        return nil
    }
}

struct ProcessCommandRunner: CommandRunning {
    /// 在后台任务中执行阻塞式进程等待，避免菜单栏 UI 的 MainActor 调用链被卡住。
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            var commandEnvironment = CommandEnvironmentBuilder.environment()
            environment?.forEach { commandEnvironment[$0.key] = $0.value }
            process.environment = commandEnvironment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            return CommandResult(
                exitCode: process.terminationStatus,
                standardOutput: stdout.fileHandleForReading.readDataToEndOfFile(),
                standardError: stderr.fileHandleForReading.readDataToEndOfFile()
            )
        }.value
    }
}

struct CommandEnvironmentBuilder {
    private static let commonExecutableDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    static func environment(from base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let existingPath = environment["PATH"] ?? ""
        var entries = existingPath.split(separator: ":").map(String.init)

        for directory in commonExecutableDirectories where !entries.contains(directory) {
            entries.append(directory)
        }

        environment["PATH"] = entries.joined(separator: ":")
        return environment
    }
}

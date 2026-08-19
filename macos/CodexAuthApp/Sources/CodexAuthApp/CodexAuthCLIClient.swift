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
    /// 执行不需要额外环境变量的普通命令。
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
    func login() async throws -> CodexAuthState
    func addAPIKey(alias: String, provider: APIKeyProvider, baseURL: String, apiKey: String) async throws -> CodexAuthState
    func importAuth(path: String, alias: String?) async throws -> CodexAuthState
    func enableCPARoute(baseURL: String, clientConfigurationPath: String) async throws -> CodexAuthState
    func disableCPARoute() async throws -> CodexAuthState
    func enableNewAPIRoute(baseURL: String, clientConfigurationPath: String) async throws -> CodexAuthState
    func disableNewAPIRoute() async throws -> CodexAuthState
}

extension CodexAuthClientProtocol {
    /// 未实现 Token 扫描的替代客户端返回明确错误。
    func loadTokenUsage(mode: TokenUsageScanMode) async throws -> TokenUsageInfo {
        throw CodexAuthCLIError.commandFailed("Token usage is unavailable")
    }

    /// 未实现 Key 创建的替代客户端返回明确错误。
    func addAPIKey(alias: String, provider: APIKeyProvider, baseURL: String, apiKey: String) async throws -> CodexAuthState {
        throw CodexAuthCLIError.commandFailed("API Key connections are unavailable")
    }

    /// 未实现 CPA 路由的替代客户端返回明确错误。
    func enableCPARoute(baseURL: String, clientConfigurationPath: String) async throws -> CodexAuthState {
        throw CodexAuthCLIError.commandFailed("CPA routing is unavailable")
    }

    /// 未实现 CPA 路由的替代客户端返回明确错误。
    func disableCPARoute() async throws -> CodexAuthState {
        throw CodexAuthCLIError.commandFailed("CPA routing is unavailable")
    }

    /// 未实现 NewAPI 路由的替代客户端返回明确错误。
    func enableNewAPIRoute(baseURL: String, clientConfigurationPath: String) async throws -> CodexAuthState {
        throw CodexAuthCLIError.commandFailed("NewAPI routing is unavailable")
    }

    /// 未实现 NewAPI 路由的替代客户端返回明确错误。
    func disableNewAPIRoute() async throws -> CodexAuthState {
        throw CodexAuthCLIError.commandFailed("NewAPI routing is unavailable")
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

    /// 校验代理地址，并生成 curl 兼容的大小写环境变量。
    static func environment(proxyURL rawValue: String?) -> [String: String]? {
        guard let rawValue else { return nil }
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
    let executableURL: URL
    let runner: CommandRunning
    let quotaProxyURLProvider: () -> String?

    /// 注入进程依赖和额度代理来源，确保测试不访问真实配置。
    init(
        executableURL: URL = CodexAuthCLIClient.defaultExecutableURL(),
        runner: CommandRunning = ProcessCommandRunner(),
        quotaProxyURLProvider: @escaping () -> String? = {
            UserDefaults.standard.string(forKey: QuotaProxyConfiguration.userDefaultsKey)
        }
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.quotaProxyURLProvider = quotaProxyURLProvider
    }

    /// 读取桌面应用所需的完整状态。
    func loadState(apiMode: CodexAuthAPIMode = .automatic) async throws -> CodexAuthState {
        try await runStateCommand(["gui", "state"] + apiMode.arguments)
    }

    /// 根据刷新协调器请求选择增量或全量 Token 扫描。
    func loadTokenUsage(mode: TokenUsageScanMode) async throws -> TokenUsageInfo {
        let result = try await runner.run(
            executableURL: executableURL,
            arguments: ["gui", "stats"] + mode.arguments
        )
        guard result.exitCode == 0 else { throw commandFailure(from: result) }
        do {
            return try JSONDecoder.codexAuth.decode(TokenUsageInfo.self, from: result.standardOutput)
        } catch {
            throw CodexAuthCLIError.invalidJSON(error.localizedDescription)
        }
    }

    /// 刷新账号额度，并只对该请求注入用户配置的网络代理。
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

    func login() async throws -> CodexAuthState {
        try await runStateCommand(["gui", "login"])
    }

    /// 通过环境变量传递密钥，避免敏感值进入进程参数。
    func addAPIKey(alias: String, provider: APIKeyProvider, baseURL: String, apiKey: String) async throws -> CodexAuthState {
        try await runStateCommand(
            ["gui", "add-key", alias, provider.rawValue, baseURL],
            environment: ["CODEX_AUTH_API_KEY": apiKey]
        )
    }

    func importAuth(path: String, alias: String?) async throws -> CodexAuthState {
        var arguments = ["gui", "import", path]
        if let alias, !alias.isEmpty { arguments += ["--alias", alias] }
        return try await runStateCommand(arguments)
    }

    /// 开启全局 CPA provider，客户端密钥仅由后端引用受保护配置文件。
    func enableCPARoute(baseURL: String, clientConfigurationPath: String) async throws -> CodexAuthState {
        try await runStateCommand(["gui", "cpa-route", "enable", baseURL, clientConfigurationPath])
    }

    /// 恢复最新备用直连连接。
    func disableCPARoute() async throws -> CodexAuthState {
        try await runStateCommand(["gui", "cpa-route", "disable"])
    }

    /// 开启全局 NewAPI provider，调用 Token 仅由后端引用受保护配置文件。
    func enableNewAPIRoute(baseURL: String, clientConfigurationPath: String) async throws -> CodexAuthState {
        try await runStateCommand(["gui", "newapi-route", "enable", baseURL, clientConfigurationPath])
    }

    /// 恢复最新备用直连连接。
    func disableNewAPIRoute() async throws -> CodexAuthState {
        try await runStateCommand(["gui", "newapi-route", "disable"])
    }

    /// 运行返回 GUI 状态 JSON 的命令并统一错误映射。
    private func runStateCommand(
        _ arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> CodexAuthState {
        let result = try await runner.run(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment
        )
        guard result.exitCode == 0 else { throw commandFailure(from: result) }
        do {
            return try JSONDecoder.codexAuth.decode(CodexAuthState.self, from: result.standardOutput)
        } catch {
            throw CodexAuthCLIError.invalidJSON(error.localizedDescription)
        }
    }

    /// 优先采用 stderr，并在缺失时回退到 stdout。
    private func commandFailure(from result: CommandResult) -> CodexAuthCLIError {
        let stderr = String(data: result.standardError, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = String(data: result.standardOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = stderr?.isEmpty == false
            ? stderr!
            : (stdout?.isEmpty == false ? stdout! : "unknown error")
        return .commandFailed(message)
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

    /// 按显式路径、仓库构建产物、PATH 和系统回退顺序查找 CLI。
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
            if fileExists(candidate) { return candidate }
        }
        return URL(fileURLWithPath: "/usr/local/bin/codex-auth")
    }

    /// 从 Swift 包构建目录向上寻找仓库 Zig 产物。
    private func repositoryBuildOutputCandidate() -> URL? {
        guard let bundleURL else { return nil }
        var current = bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = current.appendingPathComponent("zig-out/bin/codex-auth")
            if fileExists(candidate) { return candidate }
            current.deleteLastPathComponent()
        }
        return nil
    }
}

struct ProcessCommandRunner: CommandRunning {
    /// 在后台任务中等待子进程，避免阻塞菜单栏主线程。
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
    private static let commonExecutableDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// 补齐桌面 App 常缺失的 Homebrew 可执行目录。
    static func environment(from base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        var entries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in commonExecutableDirectories where !entries.contains(directory) {
            entries.append(directory)
        }
        environment["PATH"] = entries.joined(separator: ":")
        return environment
    }
}

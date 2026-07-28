import Foundation

struct CommandResult: Equatable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
}

protocol CommandRunning {
    func run(executableURL: URL, arguments: [String]) async throws -> CommandResult
}

protocol CodexAuthClientProtocol {
    func loadState(apiMode: CodexAuthAPIMode) async throws -> CodexAuthState
    func loadTokenUsage() async throws -> TokenUsageInfo
    func refresh(apiMode: CodexAuthAPIMode) async throws -> CodexAuthState
    func switchAccount(accountKey: String) async throws -> CodexAuthState
    func removeAccount(accountKey: String) async throws -> CodexAuthState
    func setAlias(accountKey: String, alias: String) async throws -> CodexAuthState
    func clearAlias(accountKey: String) async throws -> CodexAuthState
    func login() async throws -> CodexAuthState
    func importAuth(path: String, alias: String?) async throws -> CodexAuthState
    func openNewCodexSession(at directoryPath: String) async throws
}

extension CodexAuthClientProtocol {
    func loadTokenUsage() async throws -> TokenUsageInfo {
        throw CodexAuthCLIError.commandFailed("Token usage is unavailable")
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

struct CodexAuthCLIClient: CodexAuthClientProtocol {
    private static let ghosttyAppURL = URL(fileURLWithPath: "/Applications/Ghostty.app")

    let executableURL: URL
    let runner: CommandRunning
    let fileExists: (URL) -> Bool

    init(
        executableURL: URL = CodexAuthCLIClient.defaultExecutableURL(),
        runner: CommandRunning = ProcessCommandRunner(),
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.fileExists = fileExists
    }

    func loadState(apiMode: CodexAuthAPIMode = .automatic) async throws -> CodexAuthState {
        try await runStateCommand(["gui", "state"] + apiMode.arguments)
    }

    func loadTokenUsage() async throws -> TokenUsageInfo {
        let result = try await runner.run(executableURL: executableURL, arguments: ["gui", "stats"])
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
        try await runStateCommand(["gui", "refresh"] + apiMode.arguments)
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

    func importAuth(path: String, alias: String?) async throws -> CodexAuthState {
        var arguments = ["gui", "import", path]
        if let alias, !alias.isEmpty {
            arguments += ["--alias", alias]
        }
        return try await runStateCommand(arguments)
    }

    func openNewCodexSession(at directoryPath: String) async throws {
        if !fileExists(Self.ghosttyAppURL) {
            try await openNewTerminalCodexSession(at: directoryPath)
            return
        }

        let script = """
        set targetPath to \(appleScriptStringLiteral(directoryPath))
        set initialCommand to "codex resume --last" & linefeed
        tell application "Ghostty"
            activate
            set surfaceConfig to new surface configuration from {initial working directory:targetPath, initial input:initialCommand}
            if (count of windows) is 0 then
                new window with configuration surfaceConfig
            else
                new tab in front window with configuration surfaceConfig
            end if
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

    private func openNewTerminalCodexSession(at directoryPath: String) async throws {
        let script = """
        set targetPath to \(appleScriptStringLiteral(directoryPath))
        tell application "Terminal"
            activate
            do script "cd " & quoted form of targetPath & " && codex resume --last"
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

    private func runStateCommand(_ arguments: [String]) async throws -> CodexAuthState {
        let result = try await runner.run(executableURL: executableURL, arguments: arguments)
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
    func run(executableURL: URL, arguments: [String]) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = CommandEnvironmentBuilder.environment()

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

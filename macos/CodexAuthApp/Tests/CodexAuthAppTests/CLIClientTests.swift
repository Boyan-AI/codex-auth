import XCTest
@testable import CodexAuthApp

final class CLIClientTests: XCTestCase {
    func testClientBuildsStateCommand() async throws {
        let runner = RecordingCommandRunner(output: #"{"schema_version":1,"codex_home":"/tmp/codex","active_account_key":null,"generated_at":"2026-06-29T12:00:00Z","refresh":{"attempted":false,"status":"skipped","message":null},"warnings":[],"accounts":[]}"#)
        let client = CodexAuthCLIClient(executableURL: URL(fileURLWithPath: "/usr/local/bin/codex-auth"), runner: runner)

        _ = try await client.loadState(apiMode: .skipApi)

        XCTAssertEqual(runner.calls, [
            CommandCall(executable: "/usr/local/bin/codex-auth", arguments: ["gui", "state", "--skip-api"])
        ])
    }

    /// 验证额度刷新仅在用户配置有效代理后注入 curl 识别的环境变量。
    func testClientInjectsConfiguredProxyOnlyForQuotaRefresh() async throws {
        let output = #"{"schema_version":1,"codex_home":"/tmp/codex","active_account_key":null,"generated_at":"2026-06-29T12:00:00Z","refresh":{"attempted":true,"status":"ok","message":null},"warnings":[],"accounts":[]}"#
        let runner = RecordingCommandRunner(output: output)
        let client = CodexAuthCLIClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex-auth"),
            runner: runner,
            quotaProxyURLProvider: { "  http://127.0.0.1:7897  " }
        )

        _ = try await client.loadState(apiMode: .skipApi)
        _ = try await client.refresh(apiMode: .forceApi)

        XCTAssertNil(runner.calls[0].environment)
        XCTAssertEqual(
            runner.calls[1],
            CommandCall(
                executable: "/usr/local/bin/codex-auth",
                arguments: ["gui", "refresh", "--api"],
                environment: [
                    "HTTP_PROXY": "http://127.0.0.1:7897",
                    "HTTPS_PROXY": "http://127.0.0.1:7897",
                    "ALL_PROXY": "http://127.0.0.1:7897",
                    "http_proxy": "http://127.0.0.1:7897",
                    "https_proxy": "http://127.0.0.1:7897",
                    "all_proxy": "http://127.0.0.1:7897",
                ]
            )
        )
    }

    /// 验证无效代理不会被传入认证请求子进程。
    func testClientIgnoresInvalidQuotaProxy() async throws {
        let output = #"{"schema_version":1,"codex_home":"/tmp/codex","active_account_key":null,"generated_at":"2026-06-29T12:00:00Z","refresh":{"attempted":true,"status":"ok","message":null},"warnings":[],"accounts":[]}"#
        let runner = RecordingCommandRunner(output: output)
        let client = CodexAuthCLIClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex-auth"),
            runner: runner,
            quotaProxyURLProvider: { "127.0.0.1:7897" }
        )

        _ = try await client.refresh(apiMode: .forceApi)

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertNil(runner.calls.first?.environment)
    }

    /// 验证菜单全量刷新会把 `--full` 传递给 Token 扫描后端。
    func testClientBuildsFullTokenUsageCommand() async throws {
        let runner = RecordingCommandRunner(
            output: #"{"timezone":"UTC","summary":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":0},"today":null,"latest_day":null,"days":[],"quality":{"files_scanned":0,"files_with_usage":0,"repeated_snapshots":0,"segmented_sessions":0,"parse_errors":0}}"#
        )
        let client = CodexAuthCLIClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex-auth"),
            runner: runner
        )

        _ = try await client.loadTokenUsage(mode: .full)

        XCTAssertEqual(runner.calls, [
            CommandCall(executable: "/usr/local/bin/codex-auth", arguments: ["gui", "stats", "--full"])
        ])
    }

    /// 验证智能池开关只调用专用 GUI 命令，并正确映射 include 与 exclude。
    func testClientBuildsSmartPoolCommands() async throws {
        let output = #"{"schema_version":1,"codex_home":"/tmp/codex","active_account_key":null,"generated_at":"2026-06-29T12:00:00Z","refresh":{"attempted":false,"status":"skipped","message":null},"warnings":[],"accounts":[]}"#
        let runner = RecordingCommandRunner(output: output)
        let client = CodexAuthCLIClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex-auth"),
            runner: runner
        )

        _ = try await client.setSmartPoolEnabled(accountKey: "acct-1", enabled: true)
        _ = try await client.setSmartPoolEnabled(accountKey: "acct-1", enabled: false)

        XCTAssertEqual(runner.calls, [
            CommandCall(
                executable: "/usr/local/bin/codex-auth",
                arguments: ["gui", "smart-pool", "acct-1", "include"]
            ),
            CommandCall(
                executable: "/usr/local/bin/codex-auth",
                arguments: ["gui", "smart-pool", "acct-1", "exclude"]
            ),
        ])
    }

    /// 验证 CPA 成员同步使用安装配置中的独立认证目录。
    func testClientBuildsCPAAccountSyncCommands() async throws {
        let runner = RecordingCommandRunner(output: "")
        let client = CodexAuthCLIClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex-auth"),
            runner: runner,
            cpaConfigurationProvider: TestCPAConfigurationProvider()
        )

        try await client.syncCPAAccount(accountKey: "acct-1", enabled: true)
        try await client.syncCPAAccount(accountKey: "acct-1", enabled: false)

        XCTAssertEqual(runner.calls, [
            CommandCall(
                executable: "/usr/local/bin/codex-auth",
                arguments: ["gui", "cpa-sync", "acct-1", "include", "/tmp/cpa-auth"]
            ),
            CommandCall(
                executable: "/usr/local/bin/codex-auth",
                arguments: ["gui", "cpa-sync", "acct-1", "exclude", "/tmp/cpa-auth"]
            ),
        ])
    }

    /// 验证客户端把安装配置交给事件轮询器，不直接读取管理队列。
    func testClientPollsCPAEventsWithInstalledConfiguration() async throws {
        let poller = RecordingCPAEventPoller(result: CPAEventBatch(eventCount: 2, quotaExceeded: true))
        let client = CodexAuthCLIClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex-auth"),
            runner: RecordingCommandRunner(output: ""),
            cpaConfigurationProvider: TestCPAConfigurationProvider(),
            cpaEventPoller: poller
        )

        let batch = try await client.pollCPAEvents()

        XCTAssertEqual(batch, CPAEventBatch(eventCount: 2, quotaExceeded: true))
        XCTAssertEqual(poller.configurations.count, 1)
        XCTAssertEqual(poller.configurations.first?.managementKey, "test-management-key")
    }

    func testClientSurfacesFailureWithStderr() async {
        let runner = RecordingCommandRunner(exitCode: 1, output: "", errorOutput: "account not found")
        let client = CodexAuthCLIClient(executableURL: URL(fileURLWithPath: "/usr/local/bin/codex-auth"), runner: runner)

        do {
            _ = try await client.switchAccount(accountKey: "missing")
            XCTFail("Expected command failure")
        } catch let error as CodexAuthCLIError {
            XCTAssertEqual(error.localizedDescription, "命令执行失败：account not found")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResolverPrefersEnvironmentPath() {
        let resolver = CodexAuthExecutableResolver(
            environment: ["CODEX_AUTH_CLI_PATH": "/tmp/custom-codex-auth"],
            bundleURL: nil,
            pathEnvironment: "/usr/local/bin:/opt/homebrew/bin",
            fileExists: { _ in false }
        )

        XCTAssertEqual(resolver.resolve().path, "/tmp/custom-codex-auth")
    }

    func testResolverFindsExecutableFromPath() {
        let resolver = CodexAuthExecutableResolver(
            environment: [:],
            bundleURL: nil,
            pathEnvironment: "/missing:/opt/homebrew/bin",
            fileExists: { $0.path == "/opt/homebrew/bin/codex-auth" }
        )

        XCTAssertEqual(resolver.resolve().path, "/opt/homebrew/bin/codex-auth")
    }

    func testResolverFindsRepositoryBuildOutput() {
        let resolver = CodexAuthExecutableResolver(
            environment: [:],
            bundleURL: URL(fileURLWithPath: "/repo/macos/CodexAuthApp/.build/debug/CodexAuthApp"),
            pathEnvironment: "",
            fileExists: { $0.path == "/repo/zig-out/bin/codex-auth" }
        )

        XCTAssertEqual(resolver.resolve().path, "/repo/zig-out/bin/codex-auth")
    }

    func testResolverPrefersRepositoryBuildOutputBeforePath() {
        let resolver = CodexAuthExecutableResolver(
            environment: [:],
            bundleURL: URL(fileURLWithPath: "/repo/macos/CodexAuthApp/.build/debug/CodexAuthApp"),
            pathEnvironment: "/opt/homebrew/bin",
            fileExists: {
                $0.path == "/repo/zig-out/bin/codex-auth" ||
                    $0.path == "/opt/homebrew/bin/codex-auth"
            }
        )

        XCTAssertEqual(resolver.resolve().path, "/repo/zig-out/bin/codex-auth")
    }

    func testCommandEnvironmentAddsCommonCodexInstallDirectoriesToPath() {
        let environment = CommandEnvironmentBuilder.environment(
            from: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )

        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
    }

    func testCommandEnvironmentDoesNotDuplicateExistingPathEntries() {
        let environment = CommandEnvironmentBuilder.environment(
            from: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
        )

        XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/bin:/bin:/usr/local/bin")
    }

    func testClientOpensCodexSessionInGhosttyTabAtDirectory() async throws {
        let runner = RecordingCommandRunner(output: "")
        let healthChecker = SuccessfulCPAHealthChecker()
        let client = CodexAuthCLIClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex-auth"),
            runner: runner,
            fileExists: { $0.path == "/Applications/Ghostty.app" },
            cpaConfigurationProvider: TestCPAConfigurationProvider(),
            cpaHealthChecker: healthChecker
        )

        try await client.openNewCodexSession(at: "/Users/me/project")

        guard runner.calls.count == 1 else {
            XCTFail("Expected only Ghostty AppleScript, got \(runner.calls)")
            return
        }
        XCTAssertEqual(runner.calls[0].executable, "/usr/bin/osascript")
        XCTAssertEqual(runner.calls[0].arguments.count, 2)
        XCTAssertEqual(runner.calls[0].arguments[0], "-e")
        XCTAssertTrue(runner.calls[0].arguments[1].contains("tell application \"Ghostty\""))
        XCTAssertTrue(runner.calls[0].arguments[1].contains("activate"))
        XCTAssertTrue(runner.calls[0].arguments[1].contains("new tab in front window with configuration surfaceConfig"))
        XCTAssertTrue(runner.calls[0].arguments[1].contains("new window with configuration surfaceConfig"))
        XCTAssertTrue(runner.calls[0].arguments[1].contains("initial working directory:targetPath"))
        XCTAssertTrue(runner.calls[0].arguments[1].contains("model_provider"))
        XCTAssertTrue(runner.calls[0].arguments[1].contains("environment variables"))
        XCTAssertTrue(runner.calls[0].arguments[1].contains("initial input:initialCommand"))
        XCTAssertTrue(runner.calls[0].arguments[1].contains("set targetPath to \"/Users/me/project\""))
        XCTAssertFalse(runner.calls[0].arguments[1].contains("test-cpa-key"))
        XCTAssertEqual(runner.calls[0].environment, ["CODEX_AUTH_CPA_API_KEY": "test-cpa-key"])
        XCTAssertEqual(healthChecker.validatedConfigurations.count, 1)
    }

    func testClientSurfacesGhosttyAppleScriptFailure() async {
        let runner = RecordingCommandRunner(exitCode: 1, output: "", errorOutput: "open failed")
        let client = CodexAuthCLIClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex-auth"),
            runner: runner,
            fileExists: { $0.path == "/Applications/Ghostty.app" },
            cpaConfigurationProvider: TestCPAConfigurationProvider(),
            cpaHealthChecker: SuccessfulCPAHealthChecker()
        )

        do {
            try await client.openNewCodexSession(at: "/Users/me/project")
            XCTFail("Expected open failure")
        } catch let error as CodexAuthCLIError {
            XCTAssertEqual(error.localizedDescription, "命令执行失败：open failed")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].executable, "/usr/bin/osascript")
        XCTAssertEqual(runner.calls[0].arguments.first, "-e")
        XCTAssertTrue(runner.calls[0].arguments[1].contains("tell application \"Ghostty\""))
    }

    func testClientFallsBackToTerminalWhenGhosttyIsMissing() async throws {
        let runner = RecordingCommandRunner(output: "")
        let scriptWriter = RecordingTerminalLaunchScriptWriter()
        let client = CodexAuthCLIClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex-auth"),
            runner: runner,
            fileExists: { _ in false },
            cpaConfigurationProvider: TestCPAConfigurationProvider(),
            cpaHealthChecker: SuccessfulCPAHealthChecker(),
            terminalLaunchScriptWriter: scriptWriter
        )

        try await client.openNewCodexSession(at: "/Users/me/project")

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].executable, "/usr/bin/osascript")
        XCTAssertEqual(runner.calls[0].arguments.first, "-e")
        XCTAssertTrue(runner.calls[0].arguments[1].contains("tell application \"Terminal\""))
        XCTAssertTrue(runner.calls[0].arguments[1].contains("quoted form of targetPath"))
        XCTAssertTrue(runner.calls[0].arguments[1].contains("set targetPath to \"/Users/me/project\""))
        XCTAssertTrue(runner.calls[0].arguments[1].contains("/tmp/codex-auth-smart-launch.command"))
        XCTAssertFalse(runner.calls[0].arguments[1].contains("test-cpa-key"))
        XCTAssertTrue(scriptWriter.command?.contains("model_provider") == true)
        XCTAssertEqual(scriptWriter.environment, ["CODEX_AUTH_CPA_API_KEY": "test-cpa-key"])
    }
}

struct CommandCall: Equatable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]?

    /// 默认不附加环境覆盖，保持普通 CLI 命令断言简洁。
    init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

final class RecordingCommandRunner: CommandRunning {
    private(set) var calls: [CommandCall] = []
    var exitCode: Int32
    var output: String
    var errorOutput: String

    init(exitCode: Int32 = 0, output: String, errorOutput: String = "") {
        self.exitCode = exitCode
        self.output = output
        self.errorOutput = errorOutput
    }

    /// 记录完整命令和环境覆盖，验证智能启动不会把客户端密钥写进 AppleScript。
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> CommandResult {
        calls.append(CommandCall(executable: executableURL.path, arguments: arguments, environment: environment))
        return CommandResult(exitCode: exitCode, standardOutput: Data(output.utf8), standardError: Data(errorOutput.utf8))
    }
}

/// 为智能启动测试提供固定的本机 CPA 配置。
struct TestCPAConfigurationProvider: CPAConfigurationProviding {
    /// 返回不访问真实环境变量的测试配置。
    func load() throws -> CPAConfiguration {
        try CPAConfiguration(
            baseURLString: "http://127.0.0.1:8317/v1",
            apiKey: "test-cpa-key",
            managementKey: "test-management-key",
            authDirectoryPath: "/tmp/cpa-auth"
        )
    }
}

/// 记录事件轮询配置并返回固定批次，避免测试访问真实管理接口。
final class RecordingCPAEventPoller: CPAEventPolling {
    let result: CPAEventBatch
    private(set) var configurations: [CPAConfiguration] = []

    init(result: CPAEventBatch) {
        self.result = result
    }

    /// 保存配置并返回预置事件批次。
    func poll(_ configuration: CPAConfiguration) async throws -> CPAEventBatch {
        configurations.append(configuration)
        return result
    }
}

/// 记录健康检查输入并始终返回成功。
final class SuccessfulCPAHealthChecker: CPAHealthChecking {
    private(set) var validatedConfigurations: [CPAConfiguration] = []

    /// 保存待验证配置，避免单元测试发出真实网络请求。
    func validate(_ configuration: CPAConfiguration) async throws {
        validatedConfigurations.append(configuration)
    }
}

/// 捕获 Terminal 自删除脚本的输入，不在测试中创建真实文件。
final class RecordingTerminalLaunchScriptWriter: TerminalLaunchScriptWriting {
    private(set) var command: String?
    private(set) var environment: [String: String]?

    /// 返回固定临时路径并记录命令及密钥环境。
    func create(command: String, environment: [String: String]) throws -> URL {
        self.command = command
        self.environment = environment
        return URL(fileURLWithPath: "/tmp/codex-auth-smart-launch.command")
    }
}

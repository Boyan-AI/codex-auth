import Foundation
import XCTest
@testable import CodexAuthApp

final class CLIClientTests: XCTestCase {
    /// 验证桌面端只通过全局路由命令开启和关闭 CPA。
    func testClientBuildsGlobalCPARouteCommands() async throws {
        let runner = RecordingCommandRunner(output: emptyStateJSON(route: "cpa"))
        let client = makeClient(runner: runner)

        _ = try await client.enableCPARoute(
            baseURL: "http://127.0.0.1:8317/v1",
            clientConfigurationPath: "/tmp/client.json"
        )
        runner.output = emptyStateJSON(route: "direct")
        _ = try await client.disableCPARoute()

        XCTAssertEqual(runner.calls.map(\.arguments), [
            ["gui", "cpa-route", "enable", "http://127.0.0.1:8317/v1", "/tmp/client.json"],
            ["gui", "cpa-route", "disable"],
        ])
    }

    /// 验证 API Key 只通过环境变量传递，不进入命令参数。
    func testClientAddsAPIKeyWithoutSecretArgument() async throws {
        let runner = RecordingCommandRunner(output: emptyStateJSON())
        let client = makeClient(runner: runner)

        _ = try await client.addAPIKey(
            alias: "Relay",
            provider: .relay,
            baseURL: "https://relay.example.com/v1",
            apiKey: "sk-sensitive"
        )

        XCTAssertEqual(runner.calls[0].arguments, ["gui", "add-key", "Relay", "relay", "https://relay.example.com/v1"])
        XCTAssertEqual(runner.calls[0].environment, ["CODEX_AUTH_API_KEY": "sk-sensitive"])
        XCTAssertFalse(runner.calls[0].arguments.joined().contains("sk-sensitive"))
    }

    /// 验证状态命令正确映射 API 模式。
    func testClientBuildsStateCommand() async throws {
        let runner = RecordingCommandRunner(output: emptyStateJSON())
        let client = makeClient(runner: runner)

        _ = try await client.loadState(apiMode: .skipApi)

        XCTAssertEqual(runner.calls.map(\.arguments), [["gui", "state", "--skip-api"]])
    }

    /// 验证额度代理只注入刷新子进程。
    func testClientInjectsProxyOnlyForQuotaRefresh() async throws {
        let runner = RecordingCommandRunner(output: emptyStateJSON())
        let client = CodexAuthCLIClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex-auth"),
            runner: runner,
            quotaProxyURLProvider: { " http://127.0.0.1:7897 " }
        )

        _ = try await client.loadState(apiMode: .automatic)
        _ = try await client.refresh(apiMode: .forceApi)

        XCTAssertNil(runner.calls[0].environment)
        XCTAssertEqual(runner.calls[1].environment?["HTTPS_PROXY"], "http://127.0.0.1:7897")
        XCTAssertEqual(runner.calls[1].arguments, ["gui", "refresh", "--api"])
    }

    /// 验证无效代理不会进入子进程环境。
    func testClientIgnoresInvalidProxy() async throws {
        let runner = RecordingCommandRunner(output: emptyStateJSON())
        let client = CodexAuthCLIClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex-auth"),
            runner: runner,
            quotaProxyURLProvider: { "127.0.0.1:7897" }
        )

        _ = try await client.refresh(apiMode: .automatic)

        XCTAssertNil(runner.calls[0].environment)
    }

    /// 验证全量 Token 扫描传递稳定参数。
    func testClientBuildsFullTokenUsageCommand() async throws {
        let output = #"{"timezone":"UTC","summary":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":0},"today":null,"latest_day":null,"days":[],"quality":{"files_scanned":0,"files_with_usage":0,"repeated_snapshots":0,"segmented_sessions":0,"parse_errors":0}}"#
        let runner = RecordingCommandRunner(output: output)
        let client = makeClient(runner: runner)

        _ = try await client.loadTokenUsage(mode: .full)

        XCTAssertEqual(runner.calls.map(\.arguments), [["gui", "stats", "--full"]])
    }

    /// 验证后端失败优先展示 stderr。
    func testClientSurfacesCommandFailure() async {
        let runner = RecordingCommandRunner(exitCode: 1, output: "ignored", errorOutput: "account not found")
        let client = makeClient(runner: runner)

        do {
            _ = try await client.switchAccount(accountKey: "missing")
            XCTFail("Expected command failure")
        } catch {
            XCTAssertEqual(error as? CodexAuthCLIError, .commandFailed("account not found"))
        }
    }

    /// 验证显式环境路径优先于其他 CLI 候选。
    func testResolverPrefersEnvironmentPath() {
        let resolver = CodexAuthExecutableResolver(
            environment: ["CODEX_AUTH_CLI_PATH": "/tmp/custom-codex-auth"],
            bundleURL: nil,
            pathEnvironment: "/opt/homebrew/bin",
            fileExists: { _ in false }
        )

        XCTAssertEqual(resolver.resolve().path, "/tmp/custom-codex-auth")
    }

    /// 验证桌面进程 PATH 会补齐常见 Homebrew 目录。
    func testCommandEnvironmentAddsCommonExecutableDirectories() {
        let environment = CommandEnvironmentBuilder.environment(from: ["PATH": "/usr/bin"])

        XCTAssertEqual(environment["PATH"], "/usr/bin:/opt/homebrew/bin:/usr/local/bin")
    }

    private func makeClient(runner: RecordingCommandRunner) -> CodexAuthCLIClient {
        CodexAuthCLIClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex-auth"),
            runner: runner
        )
    }

    private func emptyStateJSON(route: String = "direct") -> String {
        #"{"schema_version":6,"codex_home":"/tmp/codex","global_route":"\#(route)","active_account_key":null,"generated_at":"2026-08-05T00:00:00Z","refresh":{"attempted":false,"status":"skipped","message":null},"warnings":[],"accounts":[]}"#
    }
}

/// 记录 CLI 子进程调用并返回可配置输出。
final class RecordingCommandRunner: CommandRunning {
    var exitCode: Int32
    var output: String
    var errorOutput: String
    private(set) var calls: [CommandCall] = []

    init(exitCode: Int32 = 0, output: String, errorOutput: String = "") {
        self.exitCode = exitCode
        self.output = output
        self.errorOutput = errorOutput
    }

    func run(executableURL: URL, arguments: [String], environment: [String: String]?) async throws -> CommandResult {
        calls.append(CommandCall(executable: executableURL.path, arguments: arguments, environment: environment))
        return CommandResult(
            exitCode: exitCode,
            standardOutput: Data(output.utf8),
            standardError: Data(errorOutput.utf8)
        )
    }
}

/// 保存一次 CLI 调用，便于断言参数和环境变量边界。
struct CommandCall: Equatable {
    let executable: String
    let arguments: [String]
    var environment: [String: String]? = nil
}

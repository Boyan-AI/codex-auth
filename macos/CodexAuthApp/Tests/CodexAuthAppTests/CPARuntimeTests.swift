import XCTest
@testable import CodexAuthApp

final class CPARuntimeTests: XCTestCase {
    /// 验证本机地址和模型端点的规范化结果。
    func testConfigurationAcceptsLocalCPAAddress() throws {
        let configuration = try CPAConfiguration(
            baseURLString: "http://127.0.0.1:8317/v1",
            apiKey: "local-key"
        )

        XCTAssertEqual(configuration.modelsURL.absoluteString, "http://127.0.0.1:8317/v1/models")
        XCTAssertEqual(configuration.managementBaseURL.absoluteString, "http://127.0.0.1:8317/v0/management")
    }

    /// 验证智能启动不会允许远端 CPA 地址接收账号请求。
    func testConfigurationRejectsRemoteCPAAddress() {
        XCTAssertThrowsError(
            try CPAConfiguration(baseURLString: "https://proxy.example.com/v1", apiKey: "local-key")
        ) { error in
            XCTAssertEqual(error as? CPARuntimeError, .nonLocalBaseURL("https://proxy.example.com/v1"))
        }
    }

    /// 验证缺失客户端密钥时在打开终端之前直接失败。
    func testConfigurationRejectsMissingAPIKey() {
        XCTAssertThrowsError(
            try CPAConfiguration(baseURLString: CPAConfiguration.defaultBaseURL, apiKey: "  ")
        ) { error in
            XCTAssertEqual(error as? CPARuntimeError, .missingAPIKey)
        }
    }

    /// 验证 provider 覆盖只作用于当前 CLI 命令，且命令文本不包含密钥。
    func testSmartLaunchCommandUsesInvocationOnlyProviderOverrides() throws {
        let configuration = try CPAConfiguration(
            baseURLString: "http://localhost:8317/v1",
            apiKey: "never-render-this-key"
        )

        let command = CodexSmartLaunchCommand.build(configuration: configuration)

        XCTAssertTrue(command.hasPrefix("codex -c "))
        XCTAssertTrue(command.contains(#"model_provider="codex_auth_cpa""#))
        XCTAssertTrue(command.contains(#"model_providers.codex_auth_cpa.base_url="http://localhost:8317/v1""#))
        XCTAssertTrue(command.contains(#"model_providers.codex_auth_cpa.env_key="CODEX_AUTH_CPA_API_KEY""#))
        XCTAssertTrue(command.hasSuffix("resume --last"))
        XCTAssertFalse(command.contains("never-render-this-key"))
    }

    /// 验证桌面 App 可从用户级安装文件读取客户端、管理端和认证目录配置。
    func testInstalledProviderLoadsClientConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpa-runtime-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurationURL = directory.appendingPathComponent("client.json")
        let document = #"{"base_url":"http://127.0.0.1:8317/v1","api_key":"client-key","management_key":"management-key","auth_directory":"/tmp/cpa-auth"}"#
        try Data(document.utf8).write(to: configurationURL)

        let configuration = try InstalledCPAConfigurationProvider(
            environment: [:],
            configurationURL: configurationURL
        ).load()

        XCTAssertEqual(configuration.apiKey, "client-key")
        XCTAssertEqual(configuration.managementKey, "management-key")
        XCTAssertEqual(configuration.authDirectoryPath, "/tmp/cpa-auth")
    }

    /// 验证单次客户端密钥覆盖不会丢失安装文件中的管理端和认证目录设置。
    func testInstalledProviderMergesEnvironmentOverride() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpa-runtime-override-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurationURL = directory.appendingPathComponent("client.json")
        let document = #"{"base_url":"http://127.0.0.1:8317/v1","api_key":"installed-client","management_key":"installed-management","auth_directory":"/tmp/installed-auth"}"#
        try Data(document.utf8).write(to: configurationURL)

        let configuration = try InstalledCPAConfigurationProvider(
            environment: [CPAConfiguration.apiKeyEnvironmentName: "override-client"],
            configurationURL: configurationURL
        ).load()

        XCTAssertEqual(configuration.apiKey, "override-client")
        XCTAssertEqual(configuration.managementKey, "installed-management")
        XCTAssertEqual(configuration.authDirectoryPath, "/tmp/installed-auth")
    }

    /// 验证事件队列只提取记录数量和会影响额度刷新决策的 429 状态。
    func testEventBatchDecodesQuotaExceededStatus() throws {
        let data = Data(#"[{"fail":null},{"fail":{"status_code":429}},{"fail":{"status_code":500}}]"#.utf8)

        let batch = try CPAEventBatch.decode(data)

        XCTAssertEqual(batch.eventCount, 3)
        XCTAssertTrue(batch.quotaExceeded)
    }
}

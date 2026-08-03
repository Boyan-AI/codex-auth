import XCTest
@testable import CodexAuthApp

final class CPARuntimeTests: XCTestCase {
    /// 每个测试结束后清除协议回调，避免请求桩跨测试泄漏。
    override func tearDown() {
        CPAStubURLProtocol.handler = nil
        super.tearDown()
    }

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

    /// 验证中转站直连使用单次 provider 覆盖并复用当前 auth.json，不渲染密钥。
    func testDirectLaunchCommandUsesRelayProviderOverrides() throws {
        let data = Data(#"{"account_key":"relay","display_name":"Relay","alias":null,"email":null,"account_name":"sk-test","plan":null,"auth_mode":"apikey","smart_pool_enabled":false,"provider_kind":"relay","base_url":"https://relay.example.com/v1","balance":null,"is_active":true,"usage":{"five_hour":null,"seven_day":{"status":"not_applicable","remaining_percent":null,"total":null,"used":null,"reset_at":null}},"last_usage_at":null,"last_refresh_at":null}"#.utf8)
        let account = try JSONDecoder.codexAuth.decode(CodexAccount.self, from: data)

        let command = CodexDirectLaunchCommand.build(account: account)

        XCTAssertTrue(command.contains(#"model_provider="codex_auth_direct""#))
        XCTAssertTrue(command.contains(#"model_providers.codex_auth_direct.base_url="https://relay.example.com/v1""#))
        XCTAssertTrue(command.contains("model_providers.codex_auth_direct.requires_openai_auth=true"))
        XCTAssertFalse(command.contains("env_key"))
        XCTAssertTrue(command.hasSuffix("resume --last"))
    }

    /// 验证账号和官方 Key 直连显式选择内置 provider，不继承全局自定义 provider。
    func testDirectLaunchCommandUsesOfficialProviderForOfficialConnection() {
        let account = CodexAccount.sample(accountKey: "account", alias: "账号", isActive: true)

        XCTAssertEqual(
            CodexDirectLaunchCommand.build(account: account),
            "codex -c 'model_provider=\"openai\"' resume --last"
        )
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

    /// 验证模型目录只保留非空标识，供健康检查判断 CPA 是否具备实际路由能力。
    func testModelCatalogDecodesAvailableModels() throws {
        let data = Data(#"{"object":"list","data":[{"id":"gpt-5.6-sol"},{"id":"  "}]}"#.utf8)

        let catalog = try CPAModelCatalog.decode(data)

        XCTAssertEqual(catalog.modelIDs, ["gpt-5.6-sol"])
    }

    /// 验证 CPA 虽返回 HTTP 200 但没有模型时，健康检查仍明确失败。
    func testHealthCheckerRejectsEmptyModelCatalog() async throws {
        let configuration = try CPAConfiguration(
            baseURLString: "http://127.0.0.1:8317/v1",
            apiKey: "local-key"
        )
        CPAStubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-key")
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, Data(#"{"object":"list","data":[]}"#.utf8))
        }

        let checker = URLSessionCPAHealthChecker(session: makeCPAStubSession())

        do {
            try await checker.validate(configuration)
            XCTFail("Expected an empty model catalog to fail the CPA health check")
        } catch {
            XCTAssertEqual(error as? CPARuntimeError, .unavailable("未发现可用模型"))
        }
    }

    /// 验证至少存在一个模型时，受保护模型端点可通过健康检查。
    func testHealthCheckerAcceptsAvailableModelCatalog() async throws {
        let configuration = try CPAConfiguration(
            baseURLString: "http://127.0.0.1:8317/v1",
            apiKey: "local-key"
        )
        CPAStubURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, Data(#"{"object":"list","data":[{"id":"gpt-5.6-sol"}]}"#.utf8))
        }

        let checker = URLSessionCPAHealthChecker(session: makeCPAStubSession())

        try await checker.validate(configuration)
    }

    /// 验证事件队列只提取记录数量和会影响额度刷新决策的 429 状态。
    func testEventBatchDecodesQuotaExceededStatus() throws {
        let data = Data(#"[{"fail":null},{"fail":{"status_code":429}},{"fail":{"status_code":500}}]"#.utf8)

        let batch = try CPAEventBatch.decode(data)

        XCTAssertEqual(batch.eventCount, 3)
        XCTAssertTrue(batch.quotaExceeded)
    }

    /// 创建仅由测试 URLProtocol 响应的隔离会话，不访问真实 CPA 服务。
    private func makeCPAStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CPAStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// 为 CPA 健康检查提供可控 HTTP 响应，避免单元测试依赖本机服务。
private final class CPAStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// 接管测试会话中的所有请求。
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    /// 测试不需要改写请求，直接返回原请求。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 调用测试注入的处理器并把结果交还 URLSession。
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    /// 测试响应同步完成，无需额外取消工作。
    override func stopLoading() {}
}

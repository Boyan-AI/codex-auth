import XCTest
@testable import CodexAuthApp

@MainActor
final class NewAPIRuntimeTests: XCTestCase {
    private var temporaryDirectory: URL!

    /// 为每个测试创建独立配置目录。
    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-newapi-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    /// 清理测试创建的独立配置目录和 URL 拦截器。
    override func tearDownWithError() throws {
        RecordingNewAPIURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    /// 验证本机默认地址和空 Token 可用于首次初始化状态探测。
    func testConfigurationAcceptsLoopbackAndEmptyToken() throws {
        let configuration = try makeConfiguration(apiKey: "")

        XCTAssertEqual(configuration.baseURL.absoluteString, "http://127.0.0.1:3000/v1")
        XCTAssertTrue(configuration.apiKey.isEmpty)
        XCTAssertEqual(configuration.managementPageURL.absoluteString, "http://127.0.0.1:3000/")
    }

    /// 验证远程地址不能被误当作应用拥有的本机 NewAPI。
    func testConfigurationRejectsRemoteHost() {
        XCTAssertThrowsError(
            try NewAPIConfiguration(
                baseURLString: "https://gateway.example/v1",
                apiKey: "token",
                runtimeVersion: NewAPIInstallationPaths.expectedRuntimeVersion,
                clientConfigurationURL: URL(fileURLWithPath: "/tmp/client.json")
            )
        ) { error in
            XCTAssertEqual(error as? NewAPIRuntimeError, .nonLocalBaseURL("https://gateway.example/v1"))
        }
    }

    /// 验证 Token 更新保留地址与版本，并把权限收紧为 0600。
    func testConfigurationStoreSavesTokenAtomically() throws {
        let configurationURL = temporaryDirectory.appendingPathComponent("client.json")
        try Data(
            #"{"base_url":"http://127.0.0.1:3000/v1","api_key":"","runtime_version":"v1.0.0-codex-auth.3"}"#.utf8
        ).write(to: configurationURL)
        let store = InstalledNewAPIConfigurationStore(configurationURL: configurationURL)

        try store.saveAPIKey(" sk-local-token ")

        let configuration = try store.load()
        XCTAssertEqual(configuration.apiKey, "sk-local-token")
        let attributes = try FileManager.default.attributesOfItem(atPath: configurationURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// 验证客户端配置版本不匹配时拒绝切换全局路由。
    func testConfigurationStoreRejectsUnexpectedVersion() throws {
        let configurationURL = temporaryDirectory.appendingPathComponent("client.json")
        try Data(
            #"{"base_url":"http://127.0.0.1:3000/v1","api_key":"token","runtime_version":"v0"}"#.utf8
        ).write(to: configurationURL)
        let store = InstalledNewAPIConfigurationStore(configurationURL: configurationURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard case .incompatibleConfiguration = error as? NewAPIRuntimeError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    /// 验证健康检查使用官方端点并把 Token 放入 Authorization 头。
    func testURLSessionHealthCheckerValidatesServiceSetupAndToken() async throws {
        let checker = URLSessionNewAPIHealthChecker(session: makeURLSession())
        var requestedPaths: [String] = []
        RecordingNewAPIURLProtocol.handler = { request in
            requestedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/status":
                return try Self.response(for: request, statusCode: 200, body: #"{"success":true}"#)
            case "/api/setup":
                return try Self.response(for: request, statusCode: 200, body: #"{"success":true,"data":{"status":true}}"#)
            case "/v1/models":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-local-token")
                return try Self.response(for: request, statusCode: 200, body: #"{"data":[{"id":"gpt-5.6-sol"}]}"#)
            default:
                return try Self.response(for: request, statusCode: 404, body: "{}")
            }
        }
        let configuration = try makeConfiguration()

        try await checker.validateService(configuration)
        let isSetupComplete = try await checker.isSetupComplete(configuration)
        XCTAssertTrue(isSetupComplete)
        try await checker.validateAPIKey(configuration)

        XCTAssertEqual(requestedPaths, ["/api/status", "/api/setup", "/v1/models"])
    }

    /// 验证模型目录不含受管模型时不能仅凭 HTTP 200 误报可用。
    func testURLSessionHealthCheckerRejectsMissingManagedModel() async throws {
        let checker = URLSessionNewAPIHealthChecker(session: makeURLSession())
        RecordingNewAPIURLProtocol.handler = { request in
            try Self.response(for: request, statusCode: 200, body: #"{"data":[{"id":"gpt-5"}]}"#)
        }

        do {
            try await checker.validateAPIKey(try makeConfiguration())
            XCTFail("Expected missing managed model")
        } catch {
            XCTAssertEqual(
                error as? NewAPIRuntimeError,
                .managedModelUnavailable(NewAPIModelCatalog.managedModel)
            )
        }
    }

    /// 验证打包配置器通过固定脚本路径运行，并把错误输出映射为运行时错误。
    func testBundledCPAChannelProvisionerRunsScriptAndMapsFailure() async throws {
        let runner = RecordingNewAPIProvisionerCommandRunner()
        runner.result = CommandResult(
            exitCode: 78,
            standardOutput: Data(),
            standardError: Data("schema mismatch\n".utf8)
        )
        let provisioner = BundledNewAPICPAChannelProvisioner(
            runner: runner,
            scriptURL: URL(fileURLWithPath: "/tmp/configure-newapi-cpa-channel.sh"),
            scriptIsExecutable: { _ in true }
        )

        do {
            try await provisioner.configure()
            XCTFail("Expected provisioning failure")
        } catch {
            XCTAssertEqual(
                error as? NewAPIRuntimeError,
                .managedCPAChannelConfigurationFailed("schema mismatch")
            )
        }
        XCTAssertEqual(runner.executableURLs.map(\.path), ["/tmp/configure-newapi-cpa-channel.sh"])
        XCTAssertEqual(runner.arguments, [[]])
    }

    /// 验证模型端点的认证拒绝会映射为 Token 无效。
    func testURLSessionHealthCheckerMapsUnauthorizedToken() async throws {
        let checker = URLSessionNewAPIHealthChecker(session: makeURLSession())
        RecordingNewAPIURLProtocol.handler = { request in
            try Self.response(for: request, statusCode: 401, body: #"{"error":"unauthorized"}"#)
        }

        do {
            try await checker.validateAPIKey(try makeConfiguration())
            XCTFail("Expected invalid token")
        } catch {
            XCTAssertEqual(error as? NewAPIRuntimeError, .invalidAPIKey)
        }
    }

    /// 验证 LaunchAgent 的开启、已加载兼容和关闭命令顺序。
    func testLaunchAgentControllerUsesExpectedCommands() async throws {
        let runner = RecordingNewAPIServiceCommandRunner()
        runner.exitCodes = [0, 5, 0, 0, 0]
        let controller = LaunchAgentNewAPIServiceController(
            runner: runner,
            userID: 501,
            launchAgentURL: URL(fileURLWithPath: "/tmp/com.codex-auth.newapi.plist"),
            fileExists: { _ in true }
        )

        try await controller.start()
        try await controller.stop()

        XCTAssertEqual(runner.arguments, [
            ["enable", "gui/501/com.codex-auth.newapi"],
            ["bootstrap", "gui/501", "/tmp/com.codex-auth.newapi.plist"],
            ["print", "gui/501/com.codex-auth.newapi"],
            ["bootout", "gui/501/com.codex-auth.newapi"],
            ["disable", "gui/501/com.codex-auth.newapi"],
        ])
    }

    /// 验证运行时先启动服务，再依次检查服务、初始化状态和 Token。
    func testRuntimeStartsBeforeValidatingConfiguration() async throws {
        let events = NewAPIRuntimeEventRecorder()
        let service = StubNewAPIServiceController(events: events)
        let health = StubNewAPIHealthChecker(events: events)
        let runtime = makeRuntime(service: service, health: health)

        _ = try await runtime.startAndValidate()

        XCTAssertEqual(events.values, ["service-start", "service-health", "setup", "token"])
    }

    /// 验证未初始化服务保持运行并返回明确引导错误。
    func testRuntimeReportsSetupRequiredWithoutStoppingService() async throws {
        let service = StubNewAPIServiceController()
        let health = StubNewAPIHealthChecker()
        health.setupComplete = false
        let runtime = makeRuntime(service: service, health: health)

        do {
            _ = try await runtime.startAndValidate()
            XCTFail("Expected setup requirement")
        } catch {
            XCTAssertEqual(error as? NewAPIRuntimeError, .setupRequired)
        }
        XCTAssertEqual(service.currentStatus, .running)
    }

    /// 验证运行中但未配置调用 Token 时状态可被界面单独表达。
    func testRuntimeMapsMissingTokenStatus() async throws {
        let service = StubNewAPIServiceController(status: .running)
        let health = StubNewAPIHealthChecker()
        let runtime = makeRuntime(service: service, health: health, apiKey: "")

        let status = await runtime.status()
        XCTAssertEqual(status, .tokenRequired)
    }

    /// 验证无效 Token 不会被误报为普通服务离线。
    func testRuntimeMapsInvalidTokenStatus() async throws {
        let service = StubNewAPIServiceController(status: .running)
        let health = StubNewAPIHealthChecker()
        health.tokenError = NewAPIRuntimeError.invalidAPIKey
        let runtime = makeRuntime(service: service, health: health)

        let status = await runtime.status()
        XCTAssertEqual(status, .tokenInvalid)
    }

    /// 验证管理入口只包含本机根地址，不携带调用 Token。
    func testRuntimeOpensCredentialFreeManagementURL() async throws {
        let service = StubNewAPIServiceController(status: .running)
        let health = StubNewAPIHealthChecker()
        let browser = RecordingNewAPIBrowser()
        let runtime = makeRuntime(service: service, health: health, browser: browser)

        try await runtime.openManagementPage()

        XCTAssertEqual(browser.openedURLs.map(\.absoluteString), ["http://127.0.0.1:3000/"])
    }

    /// 验证首次初始化时管理入口会先启动服务，再检查匿名端点并打开网页。
    func testRuntimeStartsStoppedServiceBeforeOpeningManagementURL() async throws {
        let events = NewAPIRuntimeEventRecorder()
        let service = StubNewAPIServiceController(events: events, status: .stopped)
        let health = StubNewAPIHealthChecker(events: events)
        let browser = RecordingNewAPIBrowser()
        let runtime = makeRuntime(service: service, health: health, browser: browser)

        try await runtime.openManagementPage()

        XCTAssertEqual(events.values, ["service-start", "service-health"])
        XCTAssertEqual(browser.openedURLs.map(\.absoluteString), ["http://127.0.0.1:3000/"])
    }

    /// 构造不访问真实安装目录的 NewAPI 配置。
    private func makeConfiguration(apiKey: String = "sk-local-token") throws -> NewAPIConfiguration {
        try NewAPIConfiguration(
            baseURLString: NewAPIConfiguration.defaultBaseURL,
            apiKey: apiKey,
            runtimeVersion: NewAPIInstallationPaths.expectedRuntimeVersion,
            clientConfigurationURL: temporaryDirectory.appendingPathComponent("client.json")
        )
    }

    /// 构造使用测试替身的 NewAPI 运行时。
    private func makeRuntime(
        service: StubNewAPIServiceController,
        health: StubNewAPIHealthChecker,
        browser: RecordingNewAPIBrowser = RecordingNewAPIBrowser(),
        apiKey: String = "sk-local-token"
    ) -> NewAPIServiceRuntime {
        NewAPIServiceRuntime(
            serviceController: service,
            configurationStore: StubNewAPIConfigurationStore(configuration: try! makeConfiguration(apiKey: apiKey)),
            healthChecker: health,
            browser: browser,
            credentialHelperIsExecutable: { _ in true },
            startupRetryDelaysNanoseconds: [],
            sleep: { _ in }
        )
    }

    /// 构造仅使用内存 URLProtocol 的网络会话。
    private func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingNewAPIURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// 构造 URLProtocol 测试所需的 HTTP 响应。
    private static func response(
        for request: URLRequest,
        statusCode: Int,
        body: String
    ) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
        return (response, Data(body.utf8))
    }
}

/// 记录 NewAPI 运行时跨替身的调用顺序。
private final class NewAPIRuntimeEventRecorder {
    var values: [String] = []
}

/// 记录 launchctl 参数并返回可配置退出码。
private final class RecordingNewAPIServiceCommandRunner: NewAPIServiceCommandRunning {
    var arguments: [[String]] = []
    var exitCodes: [Int32] = []

    /// 返回下一个预设退出码。
    func run(arguments: [String]) async throws -> CommandResult {
        self.arguments.append(arguments)
        let exitCode = exitCodes.isEmpty ? 0 : exitCodes.removeFirst()
        return CommandResult(exitCode: exitCode, standardOutput: Data(), standardError: Data())
    }
}

/// 记录专属渠道配置脚本调用并返回固定结果。
private final class RecordingNewAPIProvisionerCommandRunner: CommandRunning {
    var executableURLs: [URL] = []
    var arguments: [[String]] = []
    var result = CommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())

    /// 返回预设命令结果。
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> CommandResult {
        executableURLs.append(executableURL)
        self.arguments.append(arguments)
        return result
    }
}

/// 提供固定配置并记录 Token 更新。
private final class StubNewAPIConfigurationStore: NewAPIConfigurationStoring {
    var configuration: NewAPIConfiguration

    init(configuration: NewAPIConfiguration) {
        self.configuration = configuration
    }

    /// 返回当前内存配置。
    func load() throws -> NewAPIConfiguration { configuration }

    /// 在内存中替换 Token。
    func saveAPIKey(_ apiKey: String) throws {
        configuration = try NewAPIConfiguration(
            baseURLString: configuration.baseURL.absoluteString,
            apiKey: apiKey,
            runtimeVersion: configuration.runtimeVersion,
            clientConfigurationURL: configuration.clientConfigurationURL
        )
    }

    func clearAPIKey() throws {
        try saveAPIKey("")
    }
}

/// 记录服务启停并提供可配置状态。
private final class StubNewAPIServiceController: NewAPIServiceControlling {
    let events: NewAPIRuntimeEventRecorder?
    var currentStatus: NewAPIServiceStatus

    init(events: NewAPIRuntimeEventRecorder? = nil, status: NewAPIServiceStatus = .stopped) {
        self.events = events
        self.currentStatus = status
    }

    /// 记录启动并切换为运行中。
    func start() async throws {
        events?.values.append("service-start")
        currentStatus = .running
    }

    /// 记录关闭并切换为已停止。
    func stop() async throws {
        events?.values.append("service-stop")
        currentStatus = .stopped
    }

    /// 返回当前内存状态。
    func status() async -> NewAPIServiceStatus { currentStatus }
}

/// 提供可配置的服务、安装向导和 Token 健康结果。
private final class StubNewAPIHealthChecker: NewAPIHealthChecking {
    let events: NewAPIRuntimeEventRecorder?
    var setupComplete = true
    var tokenError: Error?

    init(events: NewAPIRuntimeEventRecorder? = nil) {
        self.events = events
    }

    /// 记录匿名服务健康检查。
    func validateService(_ configuration: NewAPIConfiguration) async throws {
        events?.values.append("service-health")
    }

    /// 记录并返回安装向导状态。
    func isSetupComplete(_ configuration: NewAPIConfiguration) async throws -> Bool {
        events?.values.append("setup")
        return setupComplete
    }

    /// 记录 Token 检查并抛出预设错误。
    func validateAPIKey(_ configuration: NewAPIConfiguration) async throws {
        events?.values.append("token")
        if let tokenError { throw tokenError }
        guard !configuration.apiKey.isEmpty else { throw NewAPIRuntimeError.missingAPIKey }
    }
}

/// 记录交给默认浏览器的 NewAPI 地址。
private final class RecordingNewAPIBrowser: NewAPIBrowserOpening {
    var openedURLs: [URL] = []

    /// 保存打开请求并报告成功。
    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

/// 在内存中拦截 NewAPI HTTP 请求。
private final class RecordingNewAPIURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// 拦截测试会话的全部请求。
    override class func canInit(with request: URLRequest) -> Bool { true }

    /// 保留原始请求。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// 执行测试处理器并回传响应。
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: NewAPIRuntimeError.unavailable("missing handler"))
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

    /// 内存响应没有可取消的持续工作。
    override func stopLoading() {}
}

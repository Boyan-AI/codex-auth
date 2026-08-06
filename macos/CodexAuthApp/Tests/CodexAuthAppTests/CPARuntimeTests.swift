import CryptoKit
import CFNetwork
import Foundation
import XCTest
@testable import CodexAuthApp

final class CPARuntimeTests: XCTestCase {
    /// 验证默认 CPA 网络客户端不会继承任何系统代理来源。
    func testDefaultNetworkClientsDisableEveryProxySource() throws {
        let sessions = [
            URLSessionCPAHealthChecker().session,
            URLSessionCPAManagementInspector().session,
        ]
        let disabledProxyKeys = [
            kCFNetworkProxiesHTTPEnable as String,
            kCFNetworkProxiesHTTPSEnable as String,
            kCFNetworkProxiesSOCKSEnable as String,
            kCFNetworkProxiesProxyAutoConfigEnable as String,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String,
        ]

        for session in sessions {
            XCTAssertFalse(session === URLSession.shared)
            let proxyConfiguration = try XCTUnwrap(session.configuration.connectionProxyDictionary)
            for key in disabledProxyKeys {
                XCTAssertEqual((proxyConfiguration[key] as? NSNumber)?.boolValue, false, key)
            }
        }
    }

    /// 验证 CPA 仅接受本机地址，并生成固定管理页 URL。
    func testConfigurationAcceptsLoopbackAddress() throws {
        let configuration = try makeConfiguration()

        XCTAssertEqual(configuration.modelsURL.absoluteString, "http://127.0.0.1:8317/v1/models")
        XCTAssertEqual(configuration.managementPageURL.absoluteString, "http://127.0.0.1:8317/management.html")
        XCTAssertEqual(configuration.credentialHelperURL.path, "/tmp/bin/codex-auth-cpa-credential")
    }

    /// 验证远端地址不会接收全局 Codex 请求。
    func testConfigurationRejectsRemoteAddress() {
        XCTAssertThrowsError(
            try CPAConfiguration(
                baseURLString: "https://proxy.example.com/v1",
                apiKey: "client-key",
                clientConfigurationURL: URL(fileURLWithPath: "/tmp/client.json")
            )
        ) { error in
            XCTAssertEqual(error as? CPARuntimeError, .nonLocalBaseURL("https://proxy.example.com/v1"))
        }
    }

    /// 验证安装配置必须提供访问 Management API 的独立密钥。
    func testInstalledConfigurationRequiresManagementKey() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let configurationURL = directoryURL.appendingPathComponent("client.json")
        try Data(#"{"base_url":"http://127.0.0.1:8317/v1","api_key":"client-key"}"#.utf8)
            .write(to: configurationURL)

        XCTAssertThrowsError(
            try InstalledCPAConfigurationProvider(configurationURL: configurationURL).load()
        )
    }

    /// 验证全局路由只能指向安装器拥有的固定本机端口。
    func testContractRequiresFixedLocalServiceAddress() async throws {
        let configuration = try CPAConfiguration(
            baseURLString: "http://127.0.0.1:9000/v1",
            apiKey: "client-key",
            managementKey: "management-key",
            clientConfigurationURL: URL(fileURLWithPath: "/tmp/client.json")
        )

        do {
            try await InstalledCPAConfigurationContractChecker().validate(configuration)
            XCTFail("Expected incompatible service address")
        } catch CPARuntimeError.incompatibleConfiguration {
            // 预期路径。
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// 验证运行时契约不接受缺少管理密钥的手工构造配置。
    func testContractRequiresManagementKey() async throws {
        let configuration = try makeConfiguration(managementKey: "")

        do {
            try await InstalledCPAConfigurationContractChecker().validate(configuration)
            XCTFail("Expected missing management key")
        } catch let error as CPARuntimeError {
            XCTAssertEqual(error, .missingManagementKey)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// 验证固定版本、客户端 Key、安全 YAML 和面板摘要组成可开启契约。
    func testContractAcceptsPinnedManagementSnapshot() async throws {
        let checker = makeContractChecker(snapshot: makeManagementSnapshot())

        try await checker.validate(makeConfiguration())
    }

    /// 验证缺失或不可执行的凭据助手会在切换全局路由前失败关闭。
    func testContractRejectsMissingCredentialHelper() async throws {
        let checker = InstalledCPAConfigurationContractChecker(
            inspector: FixedCPAManagementInspector(snapshot: makeManagementSnapshot()),
            expectedVersion: "7.2.116",
            expectedPanelSHA256: "panel-sha",
            credentialHelperIsExecutable: { _ in false }
        )

        await assertIncompatible(checker: checker)
    }

    /// 验证非固定 CPA 版本不能承载全局路由。
    func testContractRejectsUnexpectedRuntimeVersion() async throws {
        let checker = makeContractChecker(snapshot: makeManagementSnapshot(version: "7.2.117"))

        await assertIncompatible(checker: checker)
    }

    /// 验证 Management API 中必须仍包含应用客户端 Key。
    func testContractRejectsMissingClientKey() async throws {
        let checker = makeContractChecker(snapshot: makeManagementSnapshot(apiKeys: ["other-key"]))

        await assertIncompatible(checker: checker)
    }

    /// 验证非回环监听、错误端口和不安全面板开关均会失败关闭。
    func testContractRejectsUnsafeManagedConfigurationFields() async throws {
        let unsafeDocuments = [
            validManagedConfiguration.replacingOccurrences(of: #"host: "127.0.0.1""#, with: #"host: "0.0.0.0""#),
            validManagedConfiguration.replacingOccurrences(of: "port: 8317", with: "port: 8318"),
            validManagedConfiguration.replacingOccurrences(of: "allow-remote: false", with: "allow-remote: true"),
            validManagedConfiguration.replacingOccurrences(of: "disable-control-panel: false", with: "disable-control-panel: true"),
            validManagedConfiguration.replacingOccurrences(of: "disable-auto-update-panel: true", with: "disable-auto-update-panel: false"),
        ]

        for document in unsafeDocuments {
            let checker = makeContractChecker(snapshot: makeManagementSnapshot(rawConfiguration: document))
            await assertIncompatible(checker: checker)
        }
    }

    /// 验证缺少或重复应用拥有字段的 YAML 不会被含糊接受。
    func testContractRejectsAmbiguousManagedConfiguration() async throws {
        let missingField = validManagedConfiguration.replacingOccurrences(
            of: "  disable-auto-update-panel: true\n",
            with: ""
        )
        let duplicateField = validManagedConfiguration + "\n" + #"host: "127.0.0.1""# + "\n"

        for document in [missingField, duplicateField] {
            let checker = makeContractChecker(snapshot: makeManagementSnapshot(rawConfiguration: document))
            await assertIncompatible(checker: checker)
        }
    }

    /// 验证服务实际返回的管理面板必须匹配固定资产摘要。
    func testContractRejectsUnexpectedManagementPanel() async throws {
        let checker = makeContractChecker(snapshot: makeManagementSnapshot(panelSHA256: "other-sha"))

        await assertIncompatible(checker: checker)
    }

    /// 验证管理检查器只访问固定端点，且不把 Management Key 发送给面板资产。
    func testManagementInspectorBuildsAuthenticatedSnapshotWithoutLeakingKey() async throws {
        let protocolType = RecordingCPAURLProtocol.self
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [protocolType]
        let session = URLSession(configuration: sessionConfiguration)
        defer {
            session.invalidateAndCancel()
            protocolType.handler = nil
        }
        let lock = NSLock()
        var requests: [URLRequest] = []
        protocolType.handler = { request in
            lock.lock()
            requests.append(request)
            lock.unlock()
            let path = try XCTUnwrap(request.url?.path)
            switch path {
            case "/v0/management/config":
                return try Self.response(
                    for: request,
                    headers: ["X-CPA-VERSION": "7.2.116"],
                    body: #"{"api-keys":["client-key"]}"#
                )
            case "/v0/management/config.yaml":
                return try Self.response(for: request, body: self.validManagedConfiguration)
            case "/management.html":
                return try Self.response(for: request, body: "management-panel")
            default:
                throw CPARuntimeError.unavailable("unexpected path \(path)")
            }
        }

        let snapshot = try await URLSessionCPAManagementInspector(session: session)
            .inspect(makeConfiguration())

        XCTAssertEqual(snapshot.version, "7.2.116")
        XCTAssertEqual(snapshot.apiKeys, ["client-key"])
        XCTAssertEqual(snapshot.rawConfiguration, validManagedConfiguration)
        XCTAssertEqual(
            snapshot.managementPanelSHA256,
            SHA256.hash(data: Data("management-panel".utf8)).map { String(format: "%02x", $0) }.joined()
        )
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/v0/management/config",
            "/v0/management/config.yaml",
            "/management.html",
        ])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Management-Key"), "management-key")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Management-Key"), "management-key")
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "X-Management-Key"))
    }

    /// 验证尚未添加上游账号时，有效空模型目录仍表示服务与客户端 Key 可用。
    func testHealthCheckerAcceptsEmptyModelCatalog() async throws {
        let protocolType = RecordingCPAURLProtocol.self
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [protocolType]
        let session = URLSession(configuration: sessionConfiguration)
        defer {
            session.invalidateAndCancel()
            protocolType.handler = nil
        }
        protocolType.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer client-key")
            return try Self.response(for: request, body: #"{"data":[]}"#)
        }

        try await URLSessionCPAHealthChecker(session: session).validate(makeConfiguration())
    }

    /// 验证用户级服务按 enable、bootstrap、kickstart 的固定顺序启动。
    func testLaunchAgentStartsInRequiredOrder() async throws {
        let runner = RecordingCPAServiceCommandRunner()
        let controller = makeServiceController(runner: runner)

        try await controller.start()

        XCTAssertEqual(runner.arguments, [
            ["enable", "gui/501/com.codex-auth.cpa"],
            ["bootstrap", "gui/501", "/tmp/com.codex-auth.cpa.plist"],
            ["kickstart", "-k", "gui/501/com.codex-auth.cpa"],
        ])
    }

    /// 验证 bootstrap 返回 5 时必须确认服务确已加载，不能吞掉普通 I/O 故障。
    func testLaunchAgentVerifiesBootstrapAlreadyLoadedResult() async {
        let runner = RecordingCPAServiceCommandRunner()
        runner.exitCodes = [0, 5, 1]
        let controller = makeServiceController(runner: runner)

        do {
            try await controller.start()
            XCTFail("Expected bootstrap verification failure")
        } catch {
            XCTAssertEqual(runner.arguments, [
                ["enable", "gui/501/com.codex-auth.cpa"],
                ["bootstrap", "gui/501", "/tmp/com.codex-auth.cpa.plist"],
                ["print", "gui/501/com.codex-auth.cpa"],
            ])
        }
    }

    /// 验证关闭服务先 bootout，再 disable。
    func testLaunchAgentStopsInRequiredOrder() async throws {
        let runner = RecordingCPAServiceCommandRunner()
        let controller = makeServiceController(runner: runner)

        try await controller.stop()

        XCTAssertEqual(runner.arguments, [
            ["bootout", "gui/501/com.codex-auth.cpa"],
            ["disable", "gui/501/com.codex-auth.cpa"],
        ])
    }

    /// 验证缺少 LaunchAgent 时不执行任何启动命令。
    func testLaunchAgentReportsNotInstalled() async {
        let runner = RecordingCPAServiceCommandRunner()
        let controller = LaunchAgentCPAServiceController(
            runner: runner,
            userID: 501,
            launchAgentURL: URL(fileURLWithPath: "/tmp/missing.plist"),
            fileExists: { _ in false }
        )

        do {
            try await controller.start()
            XCTFail("Expected missing launch agent")
        } catch {
            XCTAssertEqual(error as? CPARuntimeError, .missingLaunchAgent)
            XCTAssertTrue(runner.arguments.isEmpty)
        }
        let status = await controller.status()
        XCTAssertEqual(status, .notInstalled)
    }

    /// 验证运行时不抢先停服，由 AppState 在恢复直连后统一完成回滚。
    func testRuntimeLeavesRollbackOrderingToAppState() async {
        let service = StubCPAServiceController()
        let runtime = CPAServiceRuntime(
            serviceController: service,
            configurationProvider: FixedCPAConfigurationProvider(configuration: try! makeConfiguration()),
            healthChecker: FailingCPAHealthChecker(),
            contractChecker: AcceptingCPAContractChecker(),
            browser: RecordingCPABrowser(),
            startupRetryDelaysNanoseconds: [],
            sleep: { _ in }
        )

        do {
            _ = try await runtime.startAndValidate()
            XCTFail("Expected health check failure")
        } catch {
            XCTAssertEqual(service.calls, ["start"])
        }
    }

    /// 验证 CPA 首次端口连接失败时会等待就绪，而不是立即触发全局路由回滚。
    func testRuntimeRetriesUnavailableStartupUntilCPAIsReady() async throws {
        let healthChecker = EventuallySuccessfulCPAHealthChecker(failuresBeforeSuccess: 2)
        var delays: [UInt64] = []
        let runtime = CPAServiceRuntime(
            serviceController: StubCPAServiceController(),
            configurationProvider: FixedCPAConfigurationProvider(configuration: try makeConfiguration()),
            healthChecker: healthChecker,
            contractChecker: AcceptingCPAContractChecker(),
            browser: RecordingCPABrowser(),
            startupRetryDelaysNanoseconds: [0, 0],
            sleep: { delays.append($0) }
        )

        _ = try await runtime.startAndValidate()

        XCTAssertEqual(healthChecker.attempts, 3)
        XCTAssertEqual(delays, [0, 0])
    }

    /// 验证启动时先锁定固定服务契约，再发送客户端 Key 做模型健康检查。
    func testRuntimeValidatesContractBeforeClientKeyHealthCheck() async {
        let recorder = RuntimeValidationRecorder()
        let runtime = CPAServiceRuntime(
            serviceController: StubCPAServiceController(),
            configurationProvider: FixedCPAConfigurationProvider(configuration: try! makeConfiguration()),
            healthChecker: RecordingCPAHealthChecker(recorder: recorder),
            contractChecker: RecordingCPAContractChecker(recorder: recorder, rejects: true),
            browser: RecordingCPABrowser()
        )

        do {
            _ = try await runtime.startAndValidate()
            XCTFail("Expected contract validation failure")
        } catch {
            XCTAssertEqual(recorder.events, ["contract"])
        }
    }

    /// 验证打开管理页前不会向尚未通过契约检查的回环端点发送客户端 Key。
    func testRuntimeValidatesContractBeforeManagementPageHealthCheck() async {
        let recorder = RuntimeValidationRecorder()
        let browser = RecordingCPABrowser()
        let runtime = CPAServiceRuntime(
            serviceController: StubCPAServiceController(),
            configurationProvider: FixedCPAConfigurationProvider(configuration: try! makeConfiguration()),
            healthChecker: RecordingCPAHealthChecker(recorder: recorder),
            contractChecker: RecordingCPAContractChecker(recorder: recorder, rejects: true),
            browser: browser
        )

        do {
            try await runtime.openManagementPage()
            XCTFail("Expected contract validation failure")
        } catch {
            XCTAssertEqual(recorder.events, ["contract"])
            XCTAssertTrue(browser.openedURLs.isEmpty)
        }
    }

    /// 验证管理页只在健康检查通过后打开，且 URL 不携带任何密钥。
    func testRuntimeOpensManagementPageWithoutSecretInURL() async throws {
        let browser = RecordingCPABrowser()
        let runtime = CPAServiceRuntime(
            serviceController: StubCPAServiceController(),
            configurationProvider: FixedCPAConfigurationProvider(configuration: try makeConfiguration()),
            healthChecker: SuccessfulCPAHealthChecker(),
            contractChecker: AcceptingCPAContractChecker(),
            browser: browser
        )

        try await runtime.openManagementPage()

        XCTAssertEqual(browser.openedURLs, [URL(string: "http://127.0.0.1:8317/management.html")!])
        XCTAssertFalse(browser.openedURLs[0].absoluteString.contains("client-key"))
    }

    /// 验证管理密钥只在用户显式复制时写入剪贴板。
    func testRuntimeCopiesManagementKeyOnlyOnExplicitAction() throws {
        let clipboard = RecordingCPAClipboard()
        let runtime = CPAServiceRuntime(
            serviceController: StubCPAServiceController(),
            configurationProvider: FixedCPAConfigurationProvider(configuration: try makeConfiguration()),
            healthChecker: SuccessfulCPAHealthChecker(),
            contractChecker: AcceptingCPAContractChecker(),
            browser: RecordingCPABrowser(),
            clipboard: clipboard
        )

        XCTAssertTrue(clipboard.values.isEmpty)
        try runtime.copyManagementKey()

        XCTAssertEqual(clipboard.values, ["management-key"])
    }

    /// 验证 launchd 已加载但模型端点失败时，状态映射为不可用。
    func testRuntimeMapsUnhealthyLoadedServiceToUnavailable() async throws {
        let service = StubCPAServiceController()
        service.currentStatus = .running
        let runtime = CPAServiceRuntime(
            serviceController: service,
            configurationProvider: FixedCPAConfigurationProvider(configuration: try makeConfiguration()),
            healthChecker: FailingCPAHealthChecker(),
            contractChecker: AcceptingCPAContractChecker(),
            browser: RecordingCPABrowser()
        )

        let status = await runtime.status()

        XCTAssertEqual(status, .unavailable)
    }

    /// 验证配置契约失败时状态映射为不兼容。
    func testRuntimeMapsInvalidContractToIncompatible() async throws {
        let service = StubCPAServiceController()
        service.currentStatus = .running
        let runtime = CPAServiceRuntime(
            serviceController: service,
            configurationProvider: FixedCPAConfigurationProvider(configuration: try makeConfiguration()),
            healthChecker: SuccessfulCPAHealthChecker(),
            contractChecker: RejectingCPAContractChecker(),
            browser: RecordingCPABrowser()
        )

        let status = await runtime.status()

        XCTAssertEqual(status, .incompatible)
    }

    /// 验证模型目录会过滤空标识。
    func testModelCatalogFiltersEmptyIdentifiers() throws {
        let catalog = try CPAModelCatalog.decode(Data(#"{"data":[{"id":"gpt-5"},{"id":" "}]}"#.utf8))

        XCTAssertEqual(catalog.modelIDs, ["gpt-5"])
    }

    /// 构造不访问真实安装目录的本机 CPA 配置。
    private func makeConfiguration(managementKey: String = "management-key") throws -> CPAConfiguration {
        try CPAConfiguration(
            baseURLString: CPAConfiguration.defaultBaseURL,
            apiKey: "client-key",
            managementKey: managementKey,
            clientConfigurationURL: URL(fileURLWithPath: "/tmp/client.json")
        )
    }

    /// 构造包含可注入管理快照的契约检查器。
    private func makeContractChecker(snapshot: CPAManagementSnapshot) -> InstalledCPAConfigurationContractChecker {
        InstalledCPAConfigurationContractChecker(
            inspector: FixedCPAManagementInspector(snapshot: snapshot),
            expectedVersion: "7.2.116",
            expectedPanelSHA256: "panel-sha",
            credentialHelperIsExecutable: { _ in true }
        )
    }

    /// 构造可定向改写单个契约字段的管理快照。
    private func makeManagementSnapshot(
        version: String = "7.2.116",
        apiKeys: [String] = ["client-key"],
        rawConfiguration: String? = nil,
        panelSHA256: String = "panel-sha"
    ) -> CPAManagementSnapshot {
        CPAManagementSnapshot(
            version: version,
            apiKeys: apiKeys,
            rawConfiguration: rawConfiguration ?? validManagedConfiguration,
            managementPanelSHA256: panelSHA256
        )
    }

    /// 断言给定快照会被契约检查器判定为不兼容。
    private func assertIncompatible(checker: InstalledCPAConfigurationContractChecker) async {
        do {
            try await checker.validate(try makeConfiguration())
            XCTFail("Expected incompatible CPA configuration")
        } catch CPARuntimeError.incompatibleConfiguration {
            // 预期路径。
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// 返回安装器生成形式的最小安全 CPA 配置。
    private var validManagedConfiguration: String {
        """
        host: "127.0.0.1"
        port: 8317

        remote-management:
          allow-remote: false
          secret-key: "$2a$10$hashed-management-key"
          disable-control-panel: false
          disable-auto-update-panel: true

        auth-dir: "/tmp/cpa-auth"
        api-keys:
          - "client-key"
        routing:
          strategy: "round-robin"
        """
    }

    /// 构造 URLProtocol 测试所需的成功 HTTP 响应。
    private static func response(
        for request: URLRequest,
        headers: [String: String] = [:],
        body: String
    ) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)
        )
        return (response, Data(body.utf8))
    }

    /// 构造使用固定用户 ID 和文件路径的 LaunchAgent 控制器。
    private func makeServiceController(runner: RecordingCPAServiceCommandRunner) -> LaunchAgentCPAServiceController {
        LaunchAgentCPAServiceController(
            runner: runner,
            userID: 501,
            launchAgentURL: URL(fileURLWithPath: "/tmp/com.codex-auth.cpa.plist"),
            fileExists: { _ in true }
        )
    }
}

/// 记录 launchctl 参数并返回可配置结果。
private final class RecordingCPAServiceCommandRunner: CPAServiceCommandRunning {
    var arguments: [[String]] = []
    var exitCodes: [Int32] = []

    func run(arguments: [String]) async throws -> CommandResult {
        self.arguments.append(arguments)
        let exitCode = exitCodes.isEmpty ? 0 : exitCodes.removeFirst()
        return CommandResult(exitCode: exitCode, standardOutput: Data(), standardError: Data())
    }
}

/// 记录服务启停调用，避免测试访问真实 launchd。
private final class StubCPAServiceController: CPAServiceControlling {
    var calls: [String] = []
    var currentStatus: CPAServiceStatus = .stopped

    func start() async throws {
        calls.append("start")
        currentStatus = .running
    }

    func stop() async throws {
        calls.append("stop")
        currentStatus = .stopped
    }

    func status() async -> CPAServiceStatus { currentStatus }
}

/// 为运行时测试提供固定配置。
private struct FixedCPAConfigurationProvider: CPAConfigurationProviding {
    let configuration: CPAConfiguration
    func load() throws -> CPAConfiguration { configuration }
}

/// 健康检查成功替身。
private struct SuccessfulCPAHealthChecker: CPAHealthChecking {
    func validate(_ configuration: CPAConfiguration) async throws {}
}

/// 健康检查失败替身。
private struct FailingCPAHealthChecker: CPAHealthChecking {
    func validate(_ configuration: CPAConfiguration) async throws {
        throw CPARuntimeError.unavailable("test")
    }
}

/// 前几次模拟端口拒绝连接，随后返回健康，用于覆盖启动就绪竞态。
private final class EventuallySuccessfulCPAHealthChecker: CPAHealthChecking {
    private let failuresBeforeSuccess: Int
    private(set) var attempts = 0

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func validate(_ configuration: CPAConfiguration) async throws {
        attempts += 1
        if attempts <= failuresBeforeSuccess {
            throw CPARuntimeError.unavailable("not ready")
        }
    }
}

/// 记录运行时安全校验顺序，避免测试依赖真实网络。
private final class RuntimeValidationRecorder {
    var events: [String] = []
}

/// 记录客户端 Key 健康检查是否被调用。
private struct RecordingCPAHealthChecker: CPAHealthChecking {
    let recorder: RuntimeValidationRecorder

    func validate(_ configuration: CPAConfiguration) async throws {
        recorder.events.append("health")
    }
}

/// 配置契约成功替身。
private struct AcceptingCPAContractChecker: CPAConfigurationContractChecking {
    func validate(_ configuration: CPAConfiguration) async throws {}
}

/// 配置契约失败替身。
private struct RejectingCPAContractChecker: CPAConfigurationContractChecking {
    func validate(_ configuration: CPAConfiguration) async throws {
        throw CPARuntimeError.incompatibleConfiguration("test")
    }
}

/// 记录配置契约检查，并可在记录后模拟拒绝。
private struct RecordingCPAContractChecker: CPAConfigurationContractChecking {
    let recorder: RuntimeValidationRecorder
    let rejects: Bool

    func validate(_ configuration: CPAConfiguration) async throws {
        recorder.events.append("contract")
        if rejects {
            throw CPARuntimeError.incompatibleConfiguration("test")
        }
    }
}

/// 为配置契约测试返回固定管理快照。
private struct FixedCPAManagementInspector: CPAManagementInspecting {
    let snapshot: CPAManagementSnapshot

    func inspect(_ configuration: CPAConfiguration) async throws -> CPAManagementSnapshot {
        snapshot
    }
}

/// 在内存中记录 CPA HTTP 请求并返回测试定义响应。
private final class RecordingCPAURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// 拦截测试 URLSession 发出的所有请求。
    override class func canInit(with request: URLRequest) -> Bool { true }

    /// 保留原请求，不做额外规范化。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// 执行测试处理器并把响应交给 URLSession。
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: CPARuntimeError.unavailable("missing URL handler"))
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

    /// 内存响应无持续任务，取消时无需额外操作。
    override func stopLoading() {}
}

/// 记录交给系统浏览器的 URL。
private final class RecordingCPABrowser: CPABrowserOpening {
    var openedURLs: [URL] = []

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

/// 记录用户显式复制到系统剪贴板的文本。
private final class RecordingCPAClipboard: CPAClipboardWriting {
    var values: [String] = []

    func write(_ value: String) -> Bool {
        values.append(value)
        return true
    }
}

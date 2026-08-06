import AppKit
import CFNetwork
import CryptoKit
import Darwin
import Foundation

/// 表示桌面端可展示的 CPA 用户级服务状态。
enum CPAServiceStatus: Equatable {
    case unknown
    case notInstalled
    case stopped
    case starting
    case running
    case unavailable
    case incompatible

    /// 返回菜单和管理窗口共用的短状态文案。
    var label: String {
        switch self {
        case .unknown: return "CPA 检查中"
        case .notInstalled: return "CPA 未安装"
        case .stopped: return "CPA 已关闭"
        case .starting: return "CPA 启动中"
        case .running: return "CPA 已开启"
        case .unavailable: return "CPA 不可用"
        case .incompatible: return "CPA 配置不兼容"
        }
    }
}

/// 描述 CPA 配置、服务控制或健康检查失败。
enum CPARuntimeError: LocalizedError, Equatable {
    case missingAPIKey
    case missingManagementKey
    case missingInstalledConfiguration
    case missingLaunchAgent
    case invalidInstalledConfiguration(String)
    case invalidBaseURL(String)
    case nonLocalBaseURL(String)
    case incompatibleConfiguration(String)
    case serviceCommandFailed(String)
    case unavailable(String)
    case browserOpenFailed
    case clipboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "尚未配置 CPA 客户端 Key。"
        case .missingManagementKey: return "尚未配置 CPA 管理密钥。"
        case .missingInstalledConfiguration: return "尚未安装 CPA 运行配置。"
        case .missingLaunchAgent: return "尚未安装 CPA 用户级服务。"
        case .invalidInstalledConfiguration(let reason): return "CPA 运行配置无效：\(reason)"
        case .invalidBaseURL(let value): return "CPA 地址无效：\(value)"
        case .nonLocalBaseURL(let value): return "CPA 必须使用本机地址：\(value)"
        case .incompatibleConfiguration(let reason): return "CPA 配置不兼容：\(reason)"
        case .serviceCommandFailed(let reason): return "CPA 服务控制失败：\(reason)"
        case .unavailable(let reason): return "CPA 当前不可用：\(reason)"
        case .browserOpenFailed: return "无法使用系统浏览器打开 CPA 管理页。"
        case .clipboardWriteFailed: return "无法复制 CPA 管理密钥。"
        }
    }
}

/// 保存全局路由和健康检查需要的本机 CPA 连接参数。
struct CPAConfiguration: Equatable {
    static let defaultBaseURL = "http://127.0.0.1:8317/v1"

    let baseURL: URL
    let apiKey: String
    let managementKey: String
    let clientConfigurationURL: URL

    /// 校验地址和客户端 Key，并保留配置契约所需的独立管理密钥。
    init(
        baseURLString: String,
        apiKey: String,
        managementKey: String = "",
        clientConfigurationURL: URL
    ) throws {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw CPARuntimeError.missingAPIKey }
        guard
            let url = URL(string: trimmedURL),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.user == nil,
            url.password == nil,
            let host = url.host?.lowercased()
        else {
            throw CPARuntimeError.invalidBaseURL(baseURLString)
        }
        guard ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw CPARuntimeError.nonLocalBaseURL(baseURLString)
        }
        self.baseURL = url
        self.apiKey = trimmedKey
        self.managementKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientConfigurationURL = clientConfigurationURL
    }

    /// 返回 OpenAI 兼容模型端点，用于验证服务和客户端 Key。
    var modelsURL: URL { baseURL.appendingPathComponent("models") }

    /// 返回 CPA 原生管理页地址，不附加任何密钥或查询参数。
    var managementPageURL: URL {
        baseURL.deletingLastPathComponent().appendingPathComponent("management.html")
    }

    /// 返回安装器部署的命令认证助手路径，供全局路由切换前验证。
    var credentialHelperURL: URL {
        clientConfigurationURL
            .deletingLastPathComponent()
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex-auth-cpa-credential")
    }
}

/// 统一用户级 CPA 安装目录和 LaunchAgent 标签。
enum CPAInstallationPaths {
    static let launchAgentLabel = "com.codex-auth.cpa"

    /// 返回应用支持目录中的客户端配置文件路径。
    static func clientConfigurationURL(fileManager: FileManager = .default) -> URL {
        applicationSupportURL(fileManager: fileManager)
            .appendingPathComponent("CPA", isDirectory: true)
            .appendingPathComponent("client.json")
    }

    /// 返回安装器创建的用户级 LaunchAgent 文件路径。
    static func launchAgentURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    /// 返回 Codex Auth 的用户级应用支持目录。
    private static func applicationSupportURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Codex Auth", isDirectory: true)
    }
}

protocol CPAConfigurationProviding {
    func load() throws -> CPAConfiguration
}

/// 从安装器生成的 0600 客户端配置读取本机地址和客户端 Key。
struct InstalledCPAConfigurationProvider: CPAConfigurationProviding {
    let configurationURL: URL

    init(configurationURL: URL = CPAInstallationPaths.clientConfigurationURL()) {
        self.configurationURL = configurationURL
    }

    /// 解码客户端配置，额外字段由原生管理面板继续独立拥有。
    func load() throws -> CPAConfiguration {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            throw CPARuntimeError.missingInstalledConfiguration
        }
        do {
            let document = try JSONDecoder().decode(
                InstalledCPAConfigurationDocument.self,
                from: Data(contentsOf: configurationURL)
            )
            guard !document.managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CPARuntimeError.missingManagementKey
            }
            return try CPAConfiguration(
                baseURLString: document.baseURL,
                apiKey: document.apiKey,
                managementKey: document.managementKey,
                clientConfigurationURL: configurationURL
            )
        } catch let error as CPARuntimeError {
            throw error
        } catch {
            throw CPARuntimeError.invalidInstalledConfiguration(error.localizedDescription)
        }
    }
}

/// 对应安装器写入的最小客户端配置结构。
private struct InstalledCPAConfigurationDocument: Decodable {
    let baseURL: String
    let apiKey: String
    let managementKey: String

    private enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case apiKey = "api_key"
        case managementKey = "management_key"
    }
}

protocol CPAHealthChecking {
    func validate(_ configuration: CPAConfiguration) async throws
}

/// 提供只访问固定 CPA 回环端点且不继承系统代理的网络会话。
enum CPALoopbackURLSession {
    /// 使用临时存储，并显式关闭系统代理、PAC 与自动发现。
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

/// 通过受保护的模型端点同时验证 CPA 可达性和客户端 Key。
struct URLSessionCPAHealthChecker: CPAHealthChecking {
    let session: URLSession

    /// 默认使用不会把客户端 Key 交给系统代理的回环会话。
    init(session: URLSession = CPALoopbackURLSession.shared) {
        self.session = session
    }

    /// 将网络错误和非成功状态统一转换为可展示错误。
    func validate(_ configuration: CPAConfiguration) async throws {
        var request = URLRequest(url: configuration.modelsURL)
        request.timeoutInterval = 3
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw CPARuntimeError.unavailable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            _ = try CPAModelCatalog.decode(data)
        } catch let error as CPARuntimeError {
            throw error
        } catch {
            throw CPARuntimeError.unavailable(error.localizedDescription)
        }
    }
}

/// 保存健康检查所需的最小模型目录。
struct CPAModelCatalog: Equatable {
    let modelIDs: [String]

    /// 解码 OpenAI 兼容模型列表并忽略空白标识。
    static func decode(_ data: Data) throws -> CPAModelCatalog {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return CPAModelCatalog(modelIDs: response.data.map(\.id).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    private struct Response: Decodable { let data: [Model] }
    private struct Model: Decodable { let id: String }
}

protocol CPAConfigurationContractChecking {
    func validate(_ configuration: CPAConfiguration) async throws
}

/// 保存已认证 Management API 和本地面板资产的最小检查结果。
struct CPAManagementSnapshot: Equatable {
    let version: String
    let apiKeys: [String]
    let rawConfiguration: String
    let managementPanelSHA256: String
}

protocol CPAManagementInspecting {
    func inspect(_ configuration: CPAConfiguration) async throws -> CPAManagementSnapshot
}

/// 通过固定本机端点读取 CPA 版本、客户端 Key、原始配置和面板摘要。
struct URLSessionCPAManagementInspector: CPAManagementInspecting {
    let session: URLSession

    /// 默认使用不会把 Management Key 交给系统代理的回环会话。
    init(session: URLSession = CPALoopbackURLSession.shared) {
        self.session = session
    }

    /// 管理密钥只发送给管理 API，不附加到静态面板请求。
    func inspect(_ configuration: CPAConfiguration) async throws -> CPAManagementSnapshot {
        let serviceRoot = configuration.baseURL.deletingLastPathComponent()
        let managementConfigURL = serviceRoot
            .appendingPathComponent("v0")
            .appendingPathComponent("management")
            .appendingPathComponent("config")
        let rawConfigURL = managementConfigURL.deletingLastPathComponent().appendingPathComponent("config.yaml")

        let (configurationData, configurationResponse) = try await fetch(
            managementConfigURL,
            managementKey: configuration.managementKey
        )
        let responseDocument: CPAManagementConfigurationResponse
        do {
            responseDocument = try JSONDecoder().decode(
                CPAManagementConfigurationResponse.self,
                from: configurationData
            )
        } catch {
            throw CPARuntimeError.incompatibleConfiguration("Management API 配置响应无效")
        }

        let (rawConfigurationData, _) = try await fetch(
            rawConfigURL,
            managementKey: configuration.managementKey
        )
        guard let rawConfiguration = String(data: rawConfigurationData, encoding: .utf8) else {
            throw CPARuntimeError.incompatibleConfiguration("CPA config.yaml 不是有效 UTF-8")
        }

        let (managementPanel, _) = try await fetch(configuration.managementPageURL, managementKey: nil)
        let panelDigest = SHA256.hash(data: managementPanel)
            .map { String(format: "%02x", $0) }
            .joined()
        let version = configurationResponse.value(forHTTPHeaderField: "X-CPA-VERSION")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return CPAManagementSnapshot(
            version: version,
            apiKeys: responseDocument.apiKeys,
            rawConfiguration: rawConfiguration,
            managementPanelSHA256: panelDigest
        )
    }

    /// 执行有超时的本机请求，并将网络故障与契约 HTTP 错误分开。
    private func fetch(_ url: URL, managementKey: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let managementKey {
            request.setValue(managementKey, forHTTPHeaderField: "X-Management-Key")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CPARuntimeError.unavailable("CPA 返回了非 HTTP 响应")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw CPARuntimeError.incompatibleConfiguration(
                    "CPA 契约端点返回 HTTP \(httpResponse.statusCode)"
                )
            }
            return (data, httpResponse)
        } catch let error as CPARuntimeError {
            throw error
        } catch {
            throw CPARuntimeError.unavailable(error.localizedDescription)
        }
    }
}

/// 对应上游 JSON 配置中未隐藏的客户端 Key 列表。
private struct CPAManagementConfigurationResponse: Decodable {
    let apiKeys: [String]

    private enum CodingKeys: String, CodingKey {
        case apiKeys = "api-keys"
    }
}

/// 只解码应用拥有的 CPA YAML 标量，不解释或改写用户的 Provider 数据。
private struct CPAOwnedConfigurationContract: Equatable {
    let host: String
    let port: Int
    let allowRemote: Bool
    let disableControlPanel: Bool
    let disableAutoUpdatePanel: Bool

    /// 要求五个字段均以唯一标准映射出现，不支持的 YAML 写法直接拒绝。
    static func decode(_ source: String) throws -> CPAOwnedConfigurationContract {
        let lines = try meaningfulLines(in: source)
        let hostValue = try uniqueValue(named: "host", in: lines, indentation: 0).value
        let portValue = try uniqueValue(named: "port", in: lines, indentation: 0).value
        let remoteManagement = try uniqueValue(named: "remote-management", in: lines, indentation: 0)
        guard remoteManagement.value.isEmpty else {
            throw incompatible("remote-management 必须使用块映射")
        }

        let remoteLines = childLines(after: remoteManagement.index, in: lines)
        guard let childIndentation = remoteLines.map(\.indentation).min(), childIndentation > 0 else {
            throw incompatible("remote-management 缺少配置字段")
        }
        let allowRemoteValue = try uniqueValue(
            named: "allow-remote",
            in: remoteLines,
            indentation: childIndentation
        ).value
        let disableControlPanelValue = try uniqueValue(
            named: "disable-control-panel",
            in: remoteLines,
            indentation: childIndentation
        ).value
        let disableAutoUpdatePanelValue = try uniqueValue(
            named: "disable-auto-update-panel",
            in: remoteLines,
            indentation: childIndentation
        ).value

        guard let port = Int(portValue) else {
            throw incompatible("port 必须是整数")
        }
        return CPAOwnedConfigurationContract(
            host: try plainString(hostValue, field: "host"),
            port: port,
            allowRemote: try boolean(allowRemoteValue, field: "allow-remote"),
            disableControlPanel: try boolean(disableControlPanelValue, field: "disable-control-panel"),
            disableAutoUpdatePanel: try boolean(
                disableAutoUpdatePanelValue,
                field: "disable-auto-update-panel"
            )
        )
    }

    /// 把 YAML 拆为带缩进的非空、非注释行，并拒绝 Tab 缩进和多文档。
    private static func meaningfulLines(in source: String) throws -> [YAMLLine] {
        var lines: [YAMLLine] = []
        var sawDocumentStart = false
        for (offset, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            guard !line.contains("\t") else {
                throw incompatible("第 \(offset + 1) 行使用了不支持的 Tab 缩进")
            }
            let indentation = line.prefix { $0 == " " }.count
            let content = String(line.dropFirst(indentation))
                .trimmingCharacters(in: .whitespaces)
            if content.isEmpty || content.hasPrefix("#") { continue }
            if content == "---" {
                guard !sawDocumentStart && lines.isEmpty else {
                    throw incompatible("config.yaml 不能包含多个 YAML 文档")
                }
                sawDocumentStart = true
                continue
            }
            if content == "..." { continue }
            lines.append(YAMLLine(number: offset + 1, indentation: indentation, content: content))
        }
        return lines
    }

    /// 返回指定缩进下唯一标量字段的值和位置。
    private static func uniqueValue(
        named name: String,
        in lines: [YAMLLine],
        indentation: Int
    ) throws -> (value: String, index: Int) {
        let matches = lines.enumerated().compactMap { index, line -> (String, Int)? in
            guard line.indentation == indentation, let mapping = mapping(in: line), mapping.key == name else {
                return nil
            }
            return (mapping.value, index)
        }
        guard matches.count == 1, let match = matches.first else {
            throw incompatible("字段 \(name) 必须且只能出现一次")
        }
        return match
    }

    /// 取得顶层映射之后、下一个顶层字段之前的子行。
    private static func childLines(after index: Int, in lines: [YAMLLine]) -> [YAMLLine] {
        guard index + 1 < lines.count else { return [] }
        var result: [YAMLLine] = []
        for line in lines[(index + 1)...] {
            if line.indentation == 0 { break }
            result.append(line)
        }
        return result
    }

    /// 从单行标准映射中分离键和去除行尾注释的值。
    private static func mapping(in line: YAMLLine) -> (key: String, value: String)? {
        guard let separator = line.content.firstIndex(of: ":") else { return nil }
        let key = String(line.content[..<separator]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let rawValue = String(line.content[line.content.index(after: separator)...])
        return (key, scalarBeforeComment(rawValue))
    }

    /// 在保留引号内 `#` 的前提下移除 YAML 行尾注释。
    private static func scalarBeforeComment(_ source: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in source {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            if quote == "\"", character == "\\" {
                result.append(character)
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                result.append(character)
                continue
            }
            if character == "#", quote == nil { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 解码不包含转义的简单 YAML 字符串，其他形式保持失败关闭。
    private static func plainString(_ source: String, field: String) throws -> String {
        guard !source.isEmpty else { throw incompatible("字段 \(field) 不能为空") }
        if source.hasPrefix("\"") || source.hasPrefix("'") {
            guard source.count >= 2, source.first == source.last else {
                throw incompatible("字段 \(field) 引号不完整")
            }
            let value = String(source.dropFirst().dropLast())
            guard !value.contains("\\"), !value.contains("\"") && !value.contains("'") else {
                throw incompatible("字段 \(field) 使用了不支持的转义")
            }
            return value
        }
        guard !source.contains("\"") && !source.contains("'") else {
            throw incompatible("字段 \(field) 引号不完整")
        }
        return source
    }

    /// 只接受 YAML 标准布尔文本，避免隐式值产生歧义。
    private static func boolean(_ source: String, field: String) throws -> Bool {
        switch source.lowercased() {
        case "true": return true
        case "false": return false
        default: throw incompatible("字段 \(field) 必须是 true 或 false")
        }
    }

    /// 生成不兼容配置错误，供解码各阶段统一返回。
    private static func incompatible(_ reason: String) -> CPARuntimeError {
        .incompatibleConfiguration(reason)
    }

    /// 保留解析所需的行号、缩进和去除前导空格的内容。
    private struct YAMLLine {
        let number: Int
        let indentation: Int
        let content: String
    }
}

/// 校验应用拥有的本机地址、密钥和 CPA 管理配置契约。
struct InstalledCPAConfigurationContractChecker: CPAConfigurationContractChecking {
    static let pinnedVersion = "7.2.116"
    static let pinnedManagementPanelSHA256 = "1d885552cc2d12b98613f31f2bc326e321c81dcbb792afb1e0b0066ecb74028e"

    let inspector: CPAManagementInspecting
    let expectedVersion: String
    let expectedPanelSHA256: String
    let credentialHelperIsExecutable: (URL) -> Bool

    init(
        inspector: CPAManagementInspecting = URLSessionCPAManagementInspector(),
        expectedVersion: String = pinnedVersion,
        expectedPanelSHA256: String = pinnedManagementPanelSHA256,
        credentialHelperIsExecutable: @escaping (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    ) {
        self.inspector = inspector
        self.expectedVersion = expectedVersion
        self.expectedPanelSHA256 = expectedPanelSHA256
        self.credentialHelperIsExecutable = credentialHelperIsExecutable
    }

    /// 要求固定回环服务和受保护客户端配置，避免全局路由指向其他端点。
    func validate(_ configuration: CPAConfiguration) async throws {
        guard configuration.clientConfigurationURL.path.hasPrefix("/") else {
            throw CPARuntimeError.incompatibleConfiguration("客户端配置路径必须是绝对路径")
        }
        guard
            configuration.baseURL.scheme?.lowercased() == "http",
            configuration.baseURL.host?.lowercased() == "127.0.0.1",
            configuration.baseURL.port == 8317,
            configuration.baseURL.path == "/v1",
            configuration.baseURL.query == nil,
            configuration.baseURL.fragment == nil
        else {
            throw CPARuntimeError.incompatibleConfiguration("CPA 服务地址必须是 http://127.0.0.1:8317/v1")
        }
        guard !configuration.managementKey.isEmpty else {
            throw CPARuntimeError.missingManagementKey
        }
        guard credentialHelperIsExecutable(configuration.credentialHelperURL) else {
            throw CPARuntimeError.incompatibleConfiguration("CPA 凭据助手缺失或不可执行")
        }

        let snapshot = try await inspector.inspect(configuration)
        guard snapshot.version == expectedVersion else {
            throw CPARuntimeError.incompatibleConfiguration(
                "CPA 版本必须是 \(expectedVersion)，当前为 \(snapshot.version.isEmpty ? "未知" : snapshot.version)"
            )
        }
        guard snapshot.apiKeys.contains(configuration.apiKey) else {
            throw CPARuntimeError.incompatibleConfiguration("客户端 Key 不存在于 CPA api-keys")
        }

        let ownedConfiguration = try CPAOwnedConfigurationContract.decode(snapshot.rawConfiguration)
        guard ownedConfiguration.host == "127.0.0.1" else {
            throw CPARuntimeError.incompatibleConfiguration("CPA host 必须是 127.0.0.1")
        }
        guard ownedConfiguration.port == 8317 else {
            throw CPARuntimeError.incompatibleConfiguration("CPA port 必须是 8317")
        }
        guard !ownedConfiguration.allowRemote else {
            throw CPARuntimeError.incompatibleConfiguration("CPA 远程管理必须关闭")
        }
        guard !ownedConfiguration.disableControlPanel else {
            throw CPARuntimeError.incompatibleConfiguration("CPA 管理面板必须开启")
        }
        guard ownedConfiguration.disableAutoUpdatePanel else {
            throw CPARuntimeError.incompatibleConfiguration("CPA 管理面板自动更新必须关闭")
        }
        guard snapshot.managementPanelSHA256.lowercased() == expectedPanelSHA256.lowercased() else {
            throw CPARuntimeError.incompatibleConfiguration("CPA 管理面板版本不匹配")
        }
    }
}

protocol CPAServiceCommandRunning {
    func run(arguments: [String]) async throws -> CommandResult
}

/// 使用系统 launchctl 执行用户级服务命令。
struct LaunchctlCommandRunner: CPAServiceCommandRunning {
    let runner: CommandRunning

    init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    /// 调用固定的系统 launchctl，不依赖桌面进程 PATH。
    func run(arguments: [String]) async throws -> CommandResult {
        try await runner.run(executableURL: URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments)
    }
}

protocol CPAServiceControlling {
    func start() async throws
    func stop() async throws
    func status() async -> CPAServiceStatus
}

/// 控制应用安装的用户级 CPA LaunchAgent，应用退出不会停止服务。
struct LaunchAgentCPAServiceController: CPAServiceControlling {
    let runner: CPAServiceCommandRunning
    let userID: uid_t
    let launchAgentURL: URL
    let fileExists: (URL) -> Bool

    init(
        runner: CPAServiceCommandRunning = LaunchctlCommandRunner(),
        userID: uid_t = getuid(),
        launchAgentURL: URL = CPAInstallationPaths.launchAgentURL(),
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.runner = runner
        self.userID = userID
        self.launchAgentURL = launchAgentURL
        self.fileExists = fileExists
    }

    /// 按 enable、bootstrap、kickstart 顺序启动服务，并核实 bootstrap 的已加载返回值。
    func start() async throws {
        guard fileExists(launchAgentURL) else { throw CPARuntimeError.missingLaunchAgent }
        try await requireSuccess(["enable", serviceTarget])
        let bootstrap = try await runner.run(arguments: ["bootstrap", domainTarget, launchAgentURL.path])
        if bootstrap.exitCode == 5 {
            try await requireSuccess(["print", serviceTarget])
        } else if bootstrap.exitCode != 0 {
            throw serviceError(bootstrap)
        }
        try await requireSuccess(["kickstart", "-k", serviceTarget])
    }

    /// 先移出服务再禁用自动启动；服务未加载时仍继续执行 disable。
    func stop() async throws {
        let bootout = try await runner.run(arguments: ["bootout", serviceTarget])
        let disable = try await runner.run(arguments: ["disable", serviceTarget])
        guard disable.exitCode == 0 else { throw serviceError(disable) }
        guard bootout.exitCode == 0 || bootout.exitCode == 3 || bootout.exitCode == 5 else {
            throw serviceError(bootout)
        }
    }

    /// 通过 launchctl print 判断服务是否已加载。
    func status() async -> CPAServiceStatus {
        guard fileExists(launchAgentURL) else { return .notInstalled }
        guard let result = try? await runner.run(arguments: ["print", serviceTarget]) else { return .unavailable }
        return result.exitCode == 0 ? .running : .stopped
    }

    private var domainTarget: String { "gui/\(userID)" }
    private var serviceTarget: String { "\(domainTarget)/\(CPAInstallationPaths.launchAgentLabel)" }

    /// 要求单个 launchctl 命令成功。
    private func requireSuccess(_ arguments: [String]) async throws {
        let result = try await runner.run(arguments: arguments)
        guard result.exitCode == 0 else { throw serviceError(result) }
    }

    /// 把 launchctl 输出转换为稳定的运行时错误。
    private func serviceError(_ result: CommandResult) -> CPARuntimeError {
        let stderr = String(data: result.standardError, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .serviceCommandFailed(stderr?.isEmpty == false ? stderr! : "launchctl exited with \(result.exitCode)")
    }
}

protocol CPABrowserOpening {
    func open(_ url: URL) -> Bool
}

/// 使用系统默认浏览器打开 CPA 原生管理页。
struct SystemCPABrowser: CPABrowserOpening {
    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

protocol CPAClipboardWriting {
    func write(_ value: String) -> Bool
}

/// 通过系统剪贴板传递用户显式请求的 CPA 管理密钥。
struct SystemCPAClipboard: CPAClipboardWriting {
    /// 清理旧内容后只写入一个普通文本值。
    func write(_ value: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
    }
}

protocol CPAServiceRuntimeProtocol {
    func startAndValidate() async throws -> CPAConfiguration
    func stop() async throws
    func status() async -> CPAServiceStatus
    func openManagementPage() async throws
    func copyManagementKey() throws
}

/// 编排服务生命周期、健康检查、配置契约和系统浏览器入口。
struct CPAServiceRuntime: CPAServiceRuntimeProtocol {
    let serviceController: CPAServiceControlling
    let configurationProvider: CPAConfigurationProviding
    let healthChecker: CPAHealthChecking
    let contractChecker: CPAConfigurationContractChecking
    let browser: CPABrowserOpening
    let clipboard: CPAClipboardWriting

    init(
        serviceController: CPAServiceControlling = LaunchAgentCPAServiceController(),
        configurationProvider: CPAConfigurationProviding = InstalledCPAConfigurationProvider(),
        healthChecker: CPAHealthChecking = URLSessionCPAHealthChecker(),
        contractChecker: CPAConfigurationContractChecking = InstalledCPAConfigurationContractChecker(),
        browser: CPABrowserOpening = SystemCPABrowser(),
        clipboard: CPAClipboardWriting = SystemCPAClipboard()
    ) {
        self.serviceController = serviceController
        self.configurationProvider = configurationProvider
        self.healthChecker = healthChecker
        self.contractChecker = contractChecker
        self.browser = browser
        self.clipboard = clipboard
    }

    /// 启动服务后先锁定配置契约，再用客户端 Key 检查模型端点；回滚由 AppState 编排。
    func startAndValidate() async throws -> CPAConfiguration {
        try await serviceController.start()
        let configuration = try configurationProvider.load()
        try await contractChecker.validate(configuration)
        try await healthChecker.validate(configuration)
        return configuration
    }

    /// 明确关闭用户级 CPA 服务。
    func stop() async throws {
        try await serviceController.stop()
    }

    /// 返回 launchd 层可观测的服务状态。
    func status() async -> CPAServiceStatus {
        let serviceStatus = await serviceController.status()
        guard serviceStatus == .running else { return serviceStatus }
        do {
            let configuration = try configurationProvider.load()
            do {
                try await contractChecker.validate(configuration)
            } catch CPARuntimeError.incompatibleConfiguration {
                return .incompatible
            }
            try await healthChecker.validate(configuration)
            return .running
        } catch CPARuntimeError.incompatibleConfiguration {
            return .incompatible
        } catch {
            return .unavailable
        }
    }

    /// 仅在服务健康且配置兼容时打开不含密钥的原生管理页。
    func openManagementPage() async throws {
        let configuration = try configurationProvider.load()
        try await contractChecker.validate(configuration)
        try await healthChecker.validate(configuration)
        guard browser.open(configuration.managementPageURL) else {
            throw CPARuntimeError.browserOpenFailed
        }
    }

    /// 只在用户触发复制命令时读取并写入管理密钥。
    func copyManagementKey() throws {
        let configuration = try configurationProvider.load()
        guard clipboard.write(configuration.managementKey) else {
            throw CPARuntimeError.clipboardWriteFailed
        }
    }
}

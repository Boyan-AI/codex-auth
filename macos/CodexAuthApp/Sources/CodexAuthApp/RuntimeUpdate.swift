import Foundation

/// 受项目兼容清单约束的运行时组件版本。
struct RuntimeComponentVersion: Codable, Equatable {
    let version: String
    let assetURL: String
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case version
        case assetURL = "asset_url"
        case sha256
    }
}

/// 描述 NewAPI、CPA 和 CPAMP 的完整兼容集合。
struct RuntimeUpdateManifest: Codable, Equatable {
    let schemaVersion: Int
    let manifestVersion: String
    let releaseURL: String
    let components: [String: RuntimeComponentVersion]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case manifestVersion = "manifest_version"
        case releaseURL = "release_url"
        case components
    }

    /// 当前 App 内置的兼容版本，避免网络不可用时阻断现有服务。
    static let bundled: RuntimeUpdateManifest = {
        RuntimeUpdateManifest(
            schemaVersion: 1,
            manifestVersion: "2026-09-02.1",
            releaseURL: "https://github.com/Boyan-AI/codex-auth/releases/latest",
            components: [
                "newapi": RuntimeComponentVersion(version: "v1.0.0-codex-auth.2", assetURL: "", sha256: "6e82062d0bba9911e33febbb22ec00d47069a6cd81f55bc23ea37f56333f0de1"),
                "cpa": RuntimeComponentVersion(version: "7.2.120", assetURL: "", sha256: "01ebcb3a683560c91f532fb124ac30edcc68945859e3ddf4880e09f1979ffdee"),
                "cpamp": RuntimeComponentVersion(version: "1.11.11-codex-auth.1", assetURL: "", sha256: "b84b6f92819a097b0b3e25a351440a87f239854264b3c06f9fce6c222a315795")
            ]
        )
    }()

    /// 只接受完整的三组件兼容集合。
    func validated() throws -> RuntimeUpdateManifest {
        guard schemaVersion == 1, components.keys.contains("newapi"), components.keys.contains("cpa"), components.keys.contains("cpamp") else {
            throw RuntimeUpdateError.invalidManifest
        }
        for component in components.values {
            guard component.sha256.count == 64, component.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw RuntimeUpdateError.invalidManifest
            }
            if !component.assetURL.isEmpty, !(component.assetURL.hasPrefix("https://")) {
                throw RuntimeUpdateError.invalidManifest
            }
        }
        return self
    }

    /// 判断远程清单是否确实包含尚未安装的新兼容集合。
    func isNewer(than current: RuntimeUpdateManifest) -> Bool {
        manifestVersion.compare(current.manifestVersion, options: .numeric) == .orderedDescending
    }

    /// 没有完整下载地址的清单只能用于记录当前版本，不能展示一键升级。
    var isInstallable: Bool {
        components.values.allSatisfy { !$0.assetURL.isEmpty }
    }
}

enum RuntimeUpdateError: LocalizedError, Equatable {
    case invalidManifest
    case unavailable
    case upgradeUnavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "Runtime update manifest is invalid."
        case .unavailable: return "Runtime update check is unavailable."
        case .upgradeUnavailable: return "No verified runtime upgrade is available."
        case .failed(let reason): return "Runtime upgrade failed: \(reason)"
        }
    }
}

protocol RuntimeUpdateChecking {
    func check() async throws -> RuntimeUpdateManifest
}

/// 从项目 Release 清单读取更新，网络失败时由调用方保留现有状态。
struct URLSessionRuntimeUpdateChecker: RuntimeUpdateChecking {
    let url: URL
    let session: URLSession

    init(url: URL = URL(string: "https://raw.githubusercontent.com/Boyan-AI/codex-auth/main/runtime-update-manifest.json")!, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    func check() async throws -> RuntimeUpdateManifest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw RuntimeUpdateError.unavailable }
        do { return try JSONDecoder().decode(RuntimeUpdateManifest.self, from: data).validated() }
        catch let error as RuntimeUpdateError { throw error }
        catch { throw RuntimeUpdateError.invalidManifest }
    }
}

protocol RuntimeUpgradeExecuting {
    func upgrade(to manifest: RuntimeUpdateManifest) async throws
}

/// 调用 App Bundle 内的受控升级脚本，不把凭据放入参数。
struct BundledRuntimeUpgradeExecutor: RuntimeUpgradeExecuting {
    let runner: CommandRunning
    let scriptURL: URL

    init(runner: CommandRunning = ProcessCommandRunner(), scriptURL: URL = Bundle.main.resourceURL?.appendingPathComponent("runtime-update.sh") ?? URL(fileURLWithPath: "/nonexistent/runtime-update.sh")) {
        self.runner = runner
        self.scriptURL = scriptURL
    }

    func upgrade(to manifest: RuntimeUpdateManifest) async throws {
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else { throw RuntimeUpdateError.upgradeUnavailable }
        let data = try JSONEncoder().encode(manifest)
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-auth-runtime-manifest-\(UUID().uuidString).json")
        try data.write(to: manifestURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: manifestURL) }
        let result = try await runner.run(executableURL: scriptURL, arguments: [manifestURL.path])
        guard result.exitCode == 0 else {
            let reason = String(data: result.standardError, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw RuntimeUpdateError.failed(reason)
        }
    }
}

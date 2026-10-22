import XCTest
@testable import CodexAuthApp

/// 验证桌面端内置版本契约和运行时更新清单的有效性。
final class RuntimeUpdateTests: XCTestCase {
    /// 确保内置版本、校验值和未发布资产状态保持一致。
    func testBundledManifestIsCompleteAndValid() throws {
        let manifest = try RuntimeUpdateManifest.bundled.validated()
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(Set(manifest.components.keys), ["newapi", "cpa", "cpamp"])
        XCTAssertEqual(manifest.manifestVersion, "2026-10-22.1")
        XCTAssertEqual(manifest.components["newapi"]?.version, "v1.0.0-codex-auth.6")
        XCTAssertEqual(manifest.components["newapi"]?.sha256, "438a8f5a838f585c50bdfd5eb193c332b219dc369557f14fcf4b9aa6aed663d0")
        XCTAssertFalse(manifest.isInstallable)
    }

    func testManifestRejectsNonHTTPSAsset() {
        let component = RuntimeComponentVersion(version: "2", assetURL: "http://example.com/a", sha256: String(repeating: "a", count: 64))
        let manifest = RuntimeUpdateManifest(schemaVersion: 1, manifestVersion: "2", releaseURL: "https://example.com", components: ["newapi": component, "cpa": component, "cpamp": component])
        XCTAssertThrowsError(try manifest.validated())
    }

    /// 验证同日递增的清单版本可以识别为更新。
    func testManifestOrderingUsesNumericVersion() {
        XCTAssertTrue(RuntimeUpdateManifest(schemaVersion: 1, manifestVersion: "2026-10-22.2", releaseURL: "https://example.com", components: [:]).isNewer(than: RuntimeUpdateManifest.bundled))
        XCTAssertFalse(RuntimeUpdateManifest.bundled.isNewer(than: RuntimeUpdateManifest.bundled))
    }
}

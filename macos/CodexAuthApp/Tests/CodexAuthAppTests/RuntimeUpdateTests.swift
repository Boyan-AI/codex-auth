import XCTest
@testable import CodexAuthApp

final class RuntimeUpdateTests: XCTestCase {
    func testBundledManifestIsCompleteAndValid() throws {
        let manifest = try RuntimeUpdateManifest.bundled.validated()
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(Set(manifest.components.keys), ["newapi", "cpa", "cpamp"])
        XCTAssertEqual(manifest.manifestVersion, "2026-09-15.1")
        XCTAssertEqual(manifest.components["newapi"]?.version, "v1.0.0-codex-auth.4")
        XCTAssertEqual(manifest.components["newapi"]?.sha256, "9cec840a68ca248bfaaff56d4bb35d8eed3d3e105fad558973e254e61687a301")
        XCTAssertFalse(manifest.isInstallable)
    }

    func testManifestRejectsNonHTTPSAsset() {
        let component = RuntimeComponentVersion(version: "2", assetURL: "http://example.com/a", sha256: String(repeating: "a", count: 64))
        let manifest = RuntimeUpdateManifest(schemaVersion: 1, manifestVersion: "2", releaseURL: "https://example.com", components: ["newapi": component, "cpa": component, "cpamp": component])
        XCTAssertThrowsError(try manifest.validated())
    }

    func testManifestOrderingUsesNumericVersion() {
        XCTAssertTrue(RuntimeUpdateManifest(schemaVersion: 1, manifestVersion: "2026-09-15.2", releaseURL: "https://example.com", components: [:]).isNewer(than: RuntimeUpdateManifest.bundled))
        XCTAssertFalse(RuntimeUpdateManifest.bundled.isNewer(than: RuntimeUpdateManifest.bundled))
    }
}

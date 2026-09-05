import XCTest
@testable import CodexAuthApp

final class RuntimeUpdateTests: XCTestCase {
    func testBundledManifestIsCompleteAndValid() throws {
        let manifest = try RuntimeUpdateManifest.bundled.validated()
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(Set(manifest.components.keys), ["newapi", "cpa", "cpamp"])
        XCTAssertEqual(manifest.components["newapi"]?.version, "v1.0.0-codex-auth.3")
        XCTAssertEqual(manifest.components["newapi"]?.sha256, "ee93d63d1b6d6dce257d1c9ce2f3564fb58d97bf963502019c6cbc4fa7993fb6")
        XCTAssertFalse(manifest.isInstallable)
    }

    func testManifestRejectsNonHTTPSAsset() {
        let component = RuntimeComponentVersion(version: "2", assetURL: "http://example.com/a", sha256: String(repeating: "a", count: 64))
        let manifest = RuntimeUpdateManifest(schemaVersion: 1, manifestVersion: "2", releaseURL: "https://example.com", components: ["newapi": component, "cpa": component, "cpamp": component])
        XCTAssertThrowsError(try manifest.validated())
    }

    func testManifestOrderingUsesNumericVersion() {
        XCTAssertTrue(RuntimeUpdateManifest(schemaVersion: 1, manifestVersion: "2026-09-02.2", releaseURL: "https://example.com", components: [:]).isNewer(than: RuntimeUpdateManifest.bundled))
        XCTAssertFalse(RuntimeUpdateManifest.bundled.isNewer(than: RuntimeUpdateManifest.bundled))
    }
}

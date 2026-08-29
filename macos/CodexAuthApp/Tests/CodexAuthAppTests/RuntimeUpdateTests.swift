import XCTest
@testable import CodexAuthApp

final class RuntimeUpdateTests: XCTestCase {
    func testBundledManifestIsCompleteAndValid() throws {
        let manifest = try RuntimeUpdateManifest.bundled.validated()
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(Set(manifest.components.keys), ["newapi", "cpa", "cpamp"])
        XCTAssertEqual(manifest.components["newapi"]?.version, "v1.0.0-codex-auth.1")
        XCTAssertEqual(manifest.components["newapi"]?.sha256, "e8d473931c71532aeb135cf0d5e958c67e5041ee539bd8bef92d0cd2ab0eec6b")
        XCTAssertFalse(manifest.isInstallable)
    }

    func testManifestRejectsNonHTTPSAsset() {
        let component = RuntimeComponentVersion(version: "2", assetURL: "http://example.com/a", sha256: String(repeating: "a", count: 64))
        let manifest = RuntimeUpdateManifest(schemaVersion: 1, manifestVersion: "2", releaseURL: "https://example.com", components: ["newapi": component, "cpa": component, "cpamp": component])
        XCTAssertThrowsError(try manifest.validated())
    }

    func testManifestOrderingUsesNumericVersion() {
        XCTAssertTrue(RuntimeUpdateManifest(schemaVersion: 1, manifestVersion: "2026-08-30.1", releaseURL: "https://example.com", components: [:]).isNewer(than: RuntimeUpdateManifest.bundled))
        XCTAssertFalse(RuntimeUpdateManifest.bundled.isNewer(than: RuntimeUpdateManifest.bundled))
    }
}

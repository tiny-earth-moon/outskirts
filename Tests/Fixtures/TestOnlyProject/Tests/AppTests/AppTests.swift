@testable import App
import XCTest

final class AppTests: XCTestCase {
    func testScreens() {
        XCTAssertEqual(SnapshotOnlyView().render(), TestFixtures.expectedBadge)
        XCTAssertEqual(SharedFormatter().format(), "shared")
        Settings().usedOnlyByTests()
        AppScreen().prepareForTest()
        CrashReporter().flushOnRelease()
        XCTAssertEqual(EventsClient(endpoint: "test").endpoint, "test")
        XCTAssertEqual(PaletteSource.secondary, "secondary")
        ChainEntry().start()
        let describing: Describing = Report()
        XCTAssertEqual(describing.describeForTests(), "report")
        LegacyExporter().export()
        for pairing in PairingCatalog.all {
            XCTAssertGreaterThan(pairing.level.minimum, 0)
            XCTAssertFalse(pairing.surface.shades.isEmpty)
            XCTAssertFalse(pairing.tokens.isEmpty)
        }
    }

    func testProbe() {
        #if os(macOS)
        XCTAssertTrue(PlatformProbe.isSupported())
        #else
        XCTAssertTrue(PlatformProbe.isSupported())
        #endif
    }

    func testSharedProbe() {
        #if os(macOS)
        XCTAssertTrue(SharedProbe.isAvailable())
        DeviceGate.resetForPlatform()
        #else
        XCTAssertTrue(SharedProbe.isAvailable())
        DeviceGate.resetForPlatform()
        #endif
    }
}

enum TestFixtures {
    static let expectedBadge = "badge"
}

extension AppScreen {
    func prepareForTest() {}
}

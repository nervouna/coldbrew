import AppKit
import XCTest
@testable import Maccy

final class ForkConfigurationTests: XCTestCase {
  func testHostUsesColdbrewIdentity() {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "io.damao.coldbrew")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "Coldbrew")
    XCTAssertEqual(NSPasteboard.PasteboardType.fromMaccy.rawValue, Bundle.main.bundleIdentifier)

    let supportPath = URL.applicationSupportDirectory.pathComponents
    XCTAssertTrue(supportPath.contains("io.damao.coldbrew"))
    XCTAssertFalse(supportPath.contains("org.p0deje.Maccy"))
  }

  func testUpdateActionsStayDisabledUntilAFeedIsConfigured() {
    XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL"))

    let updater = SoftwareUpdater()
    XCTAssertFalse(updater.isAvailable)
    XCTAssertFalse(updater.automaticallyChecksForUpdates)

    updater.automaticallyChecksForUpdates = true
    updater.checkForUpdates()

    XCTAssertFalse(updater.isAvailable)
    XCTAssertFalse(updater.automaticallyChecksForUpdates)
  }
}

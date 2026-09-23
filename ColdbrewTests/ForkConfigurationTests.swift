import AppKit
import XCTest
@testable import Coldbrew

@MainActor
final class ForkConfigurationTests: XCTestCase {
  func testHostUsesColdbrewIdentity() {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "io.damao.coldbrew")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "Coldbrew")
    XCTAssertEqual(NSPasteboard.PasteboardType.fromColdbrew.rawValue, Bundle.main.bundleIdentifier)

    XCTAssertEqual(Storage.storeURL.lastPathComponent, "Storage.sqlite")
    XCTAssertEqual(Storage.storeURL.deletingLastPathComponent().lastPathComponent, "Coldbrew")
    XCTAssertFalse(Storage.storeURL.path().contains("org.p0deje.Maccy"))
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

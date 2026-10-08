import XCTest
@testable import LocalFlow

final class AppIdentityTests: XCTestCase {
    func testLocalBuildUsesSeparateWritablePaths() {
        let local = AppIdentity(bundleIdentifier: AppIdentity.localID)
        let production = AppIdentity(bundleIdentifier: AppIdentity.productionID)
        XCTAssertTrue(local.isLocal)
        XCTAssertEqual(local.name, "Flo Local")
        XCTAssertEqual(production.name, "Flo")
        XCTAssertEqual(local.bundleIdentifier, "app.talix.localflow.local")
        XCTAssertEqual(production.bundleIdentifier, "app.talix.localflow")
        XCTAssertEqual(local.historyDirectory, "LocalFlow Local/History")
        XCTAssertEqual(local.logFilename, "LocalFlow-Local-diag.log")
        XCTAssertNotEqual(local.historyDirectory, production.historyDirectory)
        XCTAssertNotEqual(local.logFilename, production.logFilename)
    }

    func testProductionAndUnbundledToolsKeepExistingPaths() {
        for identifier in [AppIdentity.productionID, nil] {
            let identity = AppIdentity(bundleIdentifier: identifier)
            XCTAssertFalse(identity.isLocal)
            XCTAssertEqual(identity.historyDirectory, "LocalFlow/History")
            XCTAssertEqual(identity.logFilename, "LocalFlow-diag.log")
        }
    }
}

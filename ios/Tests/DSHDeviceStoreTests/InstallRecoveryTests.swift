import XCTest
@testable import DSHDeviceStore

final class InstallRecoveryTests: XCTestCase {
    func testOffersRecoveryOnlyOnAFreshInstallWithRecords() {
        XCTAssertTrue(InstallRecovery.shouldOfferRecovery(firstLaunchAfterInstall: true, recordCount: 2))
        XCTAssertFalse(InstallRecovery.shouldOfferRecovery(firstLaunchAfterInstall: true, recordCount: 0))
        XCTAssertFalse(InstallRecovery.shouldOfferRecovery(firstLaunchAfterInstall: false, recordCount: 2))
        XCTAssertFalse(InstallRecovery.shouldOfferRecovery(firstLaunchAfterInstall: false, recordCount: 0))
    }
}

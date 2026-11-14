import XCTest
@testable import DSHDeviceStore

private func healthRecord(
    expires: TimeInterval = 1_735_689_600,
    instanceId: String = String(repeating: "a", count: 64)
) -> DeviceRecord {
    DeviceRecord(
        displayName: "Desk",
        origin: "https://192.168.1.5:3443",
        instanceId: instanceId,
        deviceId: String(repeating: "b", count: 32),
        deviceToken: String(repeating: "C", count: 43),
        deviceExpiresAt: Date(timeIntervalSince1970: expires),
        certificateAuthority: Data([0x30, 0x82, 0x01])
    )
}

final class DeviceHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_735_000_000)

    func testHealthyRecordHasNoIssues() {
        let value = healthRecord()
        XCTAssertEqual(DeviceHealth.issues(record: value, now: now, caFingerprint: value.instanceId), [])
    }

    func testExpiredCredentialIsReported() {
        let value = healthRecord(expires: 1_734_000_000)
        XCTAssertEqual(DeviceHealth.issues(record: value, now: now, caFingerprint: value.instanceId), [.expired])
    }

    func testUnreadableCertificateStopsFurtherChecks() {
        let value = healthRecord()
        XCTAssertEqual(DeviceHealth.issues(record: value, now: now, caFingerprint: nil), [.certificateUnreadable])
    }

    func testFingerprintMismatchIsReported() {
        let value = healthRecord()
        let actual = String(repeating: "c", count: 64)
        XCTAssertEqual(
            DeviceHealth.issues(record: value, now: now, caFingerprint: actual),
            [.certificateMismatch(expected: value.instanceId, actual: actual)]
        )
    }

    func testExpiryAndMismatchTogether() {
        let value = healthRecord(expires: 1_734_000_000)
        let actual = String(repeating: "c", count: 64)
        XCTAssertEqual(
            DeviceHealth.issues(record: value, now: now, caFingerprint: actual),
            [.expired, .certificateMismatch(expected: value.instanceId, actual: actual)]
        )
    }
}

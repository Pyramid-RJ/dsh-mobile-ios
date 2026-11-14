import XCTest
@testable import DSHDiscovery

private func announcement(
    name: String = "Desk Mac",
    origin: String = "https://192.168.1.5:3443",
    port: Int = 3443,
    protocolValue: Int = 1,
    instanceId: String = String(repeating: "a", count: 64)
) -> [String: Any] {
    [
        "deviceName": name,
        "origin": origin,
        "port": port,
        "protocol": protocolValue,
        "instanceId": instanceId,
    ]
}

private func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

final class DiscoveryAnnouncementTests: XCTestCase {
    func testParsesTheContractShape() throws {
        let parsed = try DiscoveryAnnouncement.parse(json(announcement()))
        XCTAssertEqual(parsed.deviceName, "Desk Mac")
        XCTAssertEqual(parsed.origin, "https://192.168.1.5:3443")
        XCTAssertEqual(parsed.port, 3443)
        XCTAssertEqual(parsed.instanceId, String(repeating: "a", count: 64))
    }

    func testRejectsExtraOrMissingKeys() {
        var extra = announcement()
        extra["token"] = "nope"
        XCTAssertThrowsError(try DiscoveryAnnouncement.parse(json(extra))) { error in
            XCTAssertEqual(error as? DiscoveryAnnouncement.Rejection, .keySetMismatch(["deviceName", "instanceId", "origin", "port", "protocol", "token"]))
        }

        var missing = announcement()
        missing.removeValue(forKey: "port")
        XCTAssertThrowsError(try DiscoveryAnnouncement.parse(json(missing)))
    }

    func testRejectsOtherProtocolVersions() {
        XCTAssertThrowsError(try DiscoveryAnnouncement.parse(json(announcement(protocolValue: 2)))) { error in
            XCTAssertEqual(error as? DiscoveryAnnouncement.Rejection, .unsupportedProtocol(2))
        }
    }

    func testRejectsMalformedInstanceId() {
        for value in ["", "abc", String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            XCTAssertThrowsError(try DiscoveryAnnouncement.parse(json(announcement(instanceId: value))), value)
        }
    }

    func testRejectsOriginThatDoesNotMatchTheSourceHost() {
        XCTAssertThrowsError(
            try DiscoveryAnnouncement.parse(json(announcement()), host: "10.0.0.2")
        ) { error in
            XCTAssertEqual(
                error as? DiscoveryAnnouncement.Rejection,
                .originHostMismatch(expected: "10.0.0.2", actual: "192.168.1.5")
            )
        }
        XCTAssertNoThrow(try DiscoveryAnnouncement.parse(json(announcement()), host: "192.168.1.5"))
    }

    func testParsesTXTRecordForm() throws {
        let txt = [
            "deviceName": "Office",
            "origin": "https://10.0.0.2:3443",
            "port": "3443",
            "protocol": "1",
            "instanceId": String(repeating: "b", count: 64),
        ]
        let parsed = try DiscoveryAnnouncement.parse(txt: txt)
        XCTAssertEqual(parsed.deviceName, "Office")
        XCTAssertEqual(parsed.port, 3443)
    }

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try DiscoveryAnnouncement.parse(Data("hello".utf8))) { error in
            XCTAssertEqual(error as? DiscoveryAnnouncement.Rejection, .notAnObject)
        }
    }
}

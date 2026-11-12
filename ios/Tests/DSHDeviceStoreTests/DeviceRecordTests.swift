import XCTest
@testable import DSHDeviceStore

private func sampleRecord(
    origin: String = "https://192.168.1.5:3443",
    instanceId: String = String(repeating: "a", count: 64),
    name: String = "Desk Mac",
    createdAt: TimeInterval = 1_700_000_000
) -> DeviceRecord {
    DeviceRecord(
        displayName: name,
        origin: origin,
        instanceId: instanceId,
        deviceId: String(repeating: "b", count: 32),
        deviceToken: String(repeating: "C", count: 43),
        deviceExpiresAt: Date(timeIntervalSince1970: 1_735_689_600),
        certificateAuthority: Data([0x30, 0x82, 0x01]),
        createdAt: Date(timeIntervalSince1970: createdAt)
    )
}

final class DeviceRecordCodingTests: XCTestCase {
    func testRoundTrips() throws {
        var book = DeviceRecordBook()
        book.upsert(sampleRecord())
        book.upsert(sampleRecord(origin: "https://10.0.0.2:3443", name: "Office"))

        let decoded = try DeviceRecordCoding.decode(try DeviceRecordCoding.encode(book))
        XCTAssertEqual(decoded, book)
        XCTAssertEqual(decoded.records.count, 2)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try DeviceRecordCoding.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? DeviceStoreError, .corrupted)
        }
    }

    func testRejectsUnknownVersion() {
        let payload = Data("{\"version\":99,\"records\":[]}".utf8)
        XCTAssertThrowsError(try DeviceRecordCoding.decode(payload)) { error in
            XCTAssertEqual(error as? DeviceStoreError, .corrupted)
        }
    }
}

final class DeviceRecordBookTests: XCTestCase {
    func testUpsertKeepsPositionAndIdentityOnRepair() {
        var book = DeviceRecordBook()
        let first = sampleRecord()
        book.upsert(first)
        book.upsert(sampleRecord(origin: "https://10.0.0.2:3443", name: "Office"))
        XCTAssertEqual(book.records.count, 2)

        book.upsert(sampleRecord(name: "Desk Mac (renamed)"))
        XCTAssertEqual(book.records.count, 2)
        XCTAssertEqual(book.records[1].id, first.id)
        XCTAssertEqual(book.records[1].displayName, "Desk Mac (renamed)")
    }

    func testDifferentInstanceOnSameOriginCreatesSecondEntry() {
        var book = DeviceRecordBook()
        book.upsert(sampleRecord())
        book.upsert(sampleRecord(instanceId: String(repeating: "d", count: 64), name: "Reinstalled"))
        XCTAssertEqual(book.records.count, 2)
    }

    func testRemoveRenameMoveAndMark() {
        var book = DeviceRecordBook()
        let first = sampleRecord()
        book.upsert(first)
        book.upsert(sampleRecord(origin: "https://10.0.0.2:3443", name: "Office"))

        book.rename(id: first.id, to: "Desk")
        XCTAssertEqual(book.records.first { $0.id == first.id }?.displayName, "Desk")

        book.moveToFront(id: first.id)
        XCTAssertEqual(book.records.first?.id, first.id)

        book.markConnected(id: first.id, at: Date(timeIntervalSince1970: 1_700_000_500))
        XCTAssertEqual(book.records.first?.lastConnectedAt, Date(timeIntervalSince1970: 1_700_000_500))

        book.remove(id: first.id)
        XCTAssertNil(book.records.first { $0.id == first.id })
        XCTAssertEqual(book.records.count, 1)
    }

    func testExpiryUsesDeviceExpiresAt() {
        let record = sampleRecord()
        XCTAssertFalse(record.isExpired(now: Date(timeIntervalSince1970: 1_735_000_000)))
        XCTAssertTrue(record.isExpired(now: Date(timeIntervalSince1970: 1_736_000_000)))
    }
}

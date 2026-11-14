import XCTest
@testable import DSHBridge

/// L1 coverage for what the camera/file path can promise without a device:
/// every failure maps to a code the page understands, and the reply that
/// carries it keeps the documented shape (docs/03 section 5.2).
///
/// The picker itself (permission prompt, capture, 300 s deadline) is L3 only:
/// it needs a real camera and a person (docs/06 section 10).
final class BridgeFailureCodeMappingTests: XCTestCase {
    private struct Case {
        let code: BridgeFailureCode
        let message: String
    }

    private let cases: [Case] = [
        Case(code: .cancelled, message: "cancelled"),
        Case(code: .payloadTooLarge, message: "file is 9000000 bytes; the limit is 8388608"),
        Case(code: .failed, message: "the picked file could not be read"),
        Case(code: .unavailable, message: "not available on this device"),
        Case(code: .permissionDenied, message: "camera access is off"),
        Case(code: .timeout, message: "no photo was taken before the request timed out"),
    ]

    func testEveryFailureCodeSurvivesTheReply() throws {
        for item in cases {
            let reply = BridgeReply.failure(requestId: "r1", code: item.code, message: item.message)
            let data = try XCTUnwrap(reply.json().data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["ok"] as? Bool, false, item.code.rawValue)
            XCTAssertEqual(object["code"] as? String, item.code.rawValue)
            XCTAssertEqual(object["message"] as? String, item.message)
            XCTAssertNil(object["value"], "a failure must not carry a value")
        }
    }

    func testCameraCodesAreInTheDocumentedSet() {
        let documented: Set<String> = [
            "bad_message", "unsupported", "unavailable", "cancelled",
            "timeout", "payload_too_large", "permission_denied", "failed",
        ]
        for item in cases {
            XCTAssertTrue(documented.contains(item.code.rawValue), item.code.rawValue)
        }
    }

    /// A failed capture must release its pending slot, otherwise a few retries
    /// would exhaust the 16-request limit.
    func testFailedCaptureReleasesPendingSlot() {
        let tracker = BridgePendingTracker(limit: 1)
        XCTAssertTrue(tracker.begin("camera-1"))
        tracker.finish("camera-1")
        XCTAssertTrue(tracker.begin("camera-2"))
    }
}

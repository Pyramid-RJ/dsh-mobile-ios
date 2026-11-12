import XCTest
@testable import DSHBridge

final class BridgeRequestTests: XCTestCase {
    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    func testParsesMinimalRequest() throws {
        let text = json(["version": 1, "requestId": "r1", "action": "auth.renew"])
        let request = try BridgeRequest.parse(text)
        XCTAssertEqual(request.requestId, "r1")
        XCTAssertEqual(request.action, "auth.renew")
        XCTAssertTrue(request.input.isEmpty)
    }

    func testParsesInputObject() throws {
        let text = json(["version": 1, "requestId": "r2", "action": "clipboard.write", "input": ["text": "hi"]])
        let request = try BridgeRequest.parse(text)
        XCTAssertEqual(request.input["text"] as? String, "hi")
    }

    func testRejectsWrongVersion() {
        XCTAssertThrowsError(try BridgeRequest.parse(json(["version": 2, "requestId": "r", "action": "a"]))) { error in
            XCTAssertEqual(error as? BridgeError, .unsupportedVersion(2))
        }
    }

    func testRejectsMissingRequestId() {
        XCTAssertThrowsError(try BridgeRequest.parse(json(["version": 1, "action": "a"]))) { error in
            XCTAssertEqual(error as? BridgeError, .missingRequestId)
        }
    }

    func testRejectsLongRequestId() {
        let long = String(repeating: "r", count: BridgeLimits.maxRequestIdLength + 1)
        XCTAssertThrowsError(try BridgeRequest.parse(json(["version": 1, "requestId": long, "action": "a"])))
    }

    func testRejectsNonObjectInput() {
        XCTAssertThrowsError(try BridgeRequest.parse(json(["version": 1, "requestId": "r", "action": "a", "input": "nope"]))) { error in
            XCTAssertEqual(error as? BridgeError, .inputNotAnObject)
        }
    }

    func testRejectsOversizedMessage() {
        let huge = String(repeating: "x", count: BridgeLimits.maxInboundBytes + 16)
        XCTAssertThrowsError(try BridgeRequest.parse(huge)) { error in
            guard case .tooLarge = (error as? BridgeError) else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
    }
}

final class BridgeReplyTests: XCTestCase {
    private func decode(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testSuccessCarriesValue() throws {
        let reply = BridgeReply.success(requestId: "r1", value: ["renewed": true])
        let object = try decode(reply.json())
        XCTAssertEqual(object["requestId"] as? String, "r1")
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual((object["value"] as? [String: Any])?["renewed"] as? Bool, true)
    }

    func testFailureCarriesCode() throws {
        let reply = BridgeReply.failure(requestId: "r2", code: .cancelled, message: "aborted")
        let object = try decode(reply.json())
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["code"] as? String, "cancelled")
        XCTAssertEqual(object["message"] as? String, "aborted")
    }

    func testOversizedReplyDegrades() throws {
        let reply = BridgeReply.success(requestId: "r3", value: String(repeating: "y", count: 512))
        let object = try decode(reply.json(limit: 100))
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["code"] as? String, "payload_too_large")
    }
}

final class BridgePendingTrackerTests: XCTestCase {
    func testRejectsDuplicateAndOverLimit() {
        let tracker = BridgePendingTracker(limit: 2)
        XCTAssertTrue(tracker.begin("a"))
        XCTAssertFalse(tracker.begin("a"))
        XCTAssertTrue(tracker.begin("b"))
        XCTAssertFalse(tracker.begin("c"))
        tracker.finish("a")
        XCTAssertTrue(tracker.begin("c"))
        XCTAssertEqual(tracker.count, 2)
    }
}

final class BridgeCapabilitiesTests: XCTestCase {
    func testOnlyImplementedActionsAreAdvertised() {
        let capabilities = BridgeCapabilities(implemented: [.authRenew, .clipboardWrite])
        XCTAssertEqual(capabilities.values, ["auth.renew", "clipboard.write"])
        XCTAssertTrue(capabilities.includes(.authRenew))
        XCTAssertFalse(capabilities.includes(.filesPick))
    }
}

import XCTest
@testable import DSHBridge

final class DisplayScalePolicyTests: XCTestCase {
    func testAcceptsIntegerInRange() {
        XCTAssertEqual(DisplayScalePolicy.percent(from: ["percent": 100]), 100)
        XCTAssertEqual(DisplayScalePolicy.percent(from: ["percent": 80]), 80)
        XCTAssertEqual(DisplayScalePolicy.percent(from: ["percent": 125]), 125)
    }

    func testRejectsOutOfRange() {
        XCTAssertNil(DisplayScalePolicy.percent(from: ["percent": 79]))
        XCTAssertNil(DisplayScalePolicy.percent(from: ["percent": 126]))
    }

    func testRejectsFractionalValue() {
        XCTAssertNil(DisplayScalePolicy.percent(from: ["percent": 87.5]))
    }

    func testRejectsMissingOrWrongType() {
        XCTAssertNil(DisplayScalePolicy.percent(from: [:]))
        XCTAssertNil(DisplayScalePolicy.percent(from: ["percent": true]))
    }

    func testViewportWidthFormula() {
        // 390pt wide screen at 100% stays 390; at 125% it shrinks.
        XCTAssertEqual(DisplayScalePolicy.viewportWidth(nativeWidth: 1170, density: 3, percent: 100), 390)
        XCTAssertEqual(DisplayScalePolicy.viewportWidth(nativeWidth: 1170, density: 3, percent: 125), 312)
        XCTAssertEqual(DisplayScalePolicy.viewportWidth(nativeWidth: 1170, density: 3, percent: 80), 488)
    }

    func testReplyShape() {
        let reply = DisplayScalePolicy.reply(percent: 110)
        XCTAssertEqual(reply["percent"] as? Int, 110)
        XCTAssertEqual(reply["minPercent"] as? Int, 80)
        XCTAssertEqual(reply["maxPercent"] as? Int, 125)
    }
}

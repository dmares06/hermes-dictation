import CoreGraphics
import XCTest
@testable import WhisperDictCore

final class KeyboardHitTestingTests: XCTestCase {
    private let frames: [KeyboardKey: CGRect] = [
        .character("q"): CGRect(x: 0, y: 0, width: 30, height: 42),
        .character("w"): CGRect(x: 35, y: 0, width: 30, height: 42),
        .space: CGRect(x: 0, y: 50, width: 65, height: 42),
    ]

    func testATouchInsideAKeyIsThatKey() {
        XCTAssertEqual(KeyboardHitTesting.key(at: CGPoint(x: 40, y: 20), in: frames), .character("w"))
    }

    func testATouchInTheGapGoesToTheNearerKey() {
        XCTAssertEqual(KeyboardHitTesting.key(at: CGPoint(x: 31, y: 20), in: frames), .character("q"))
        XCTAssertEqual(KeyboardHitTesting.key(at: CGPoint(x: 34, y: 20), in: frames), .character("w"))
    }

    func testATouchBetweenRowsGoesToTheNearerRow() {
        XCTAssertEqual(KeyboardHitTesting.key(at: CGPoint(x: 10, y: 47), in: frames), .space)
        XCTAssertEqual(KeyboardHitTesting.key(at: CGPoint(x: 10, y: 44), in: frames), .character("q"))
    }

    func testATouchFarFromAnyKeyIsNothing() {
        XCTAssertNil(KeyboardHitTesting.key(at: CGPoint(x: 200, y: 20), in: frames))
        XCTAssertNil(KeyboardHitTesting.key(at: CGPoint(x: 10, y: 200), in: frames))
    }
}

import XCTest
@testable import SharedMessageSetupScreen

/// The forms of the editor header's "is editing" line, longest first, the count form always last.
final class SharedMessageEditorStatusTests: XCTestCase {
    func testNobodyEditingYieldsNothing() {
        XCTAssertEqual(sharedMessageEditingStatusShapes(names: [], count: 0), [])
    }

    func testOnePerson() {
        XCTAssertEqual(sharedMessageEditingStatusShapes(names: ["Ron"], count: 1), [.one("Ron"), .count(1)])
    }

    func testTwoPeopleAreNamedTogether() {
        XCTAssertEqual(sharedMessageEditingStatusShapes(names: ["Milli", "Tom"], count: 2), [.two("Milli", "Tom"), .count(2)])
    }

    func testThreeOrMoreNameTheFirstAndCountTheRest() {
        XCTAssertEqual(sharedMessageEditingStatusShapes(names: ["Milli", "Tom", "Ron"], count: 3), [.oneAndOthers("Milli", 2), .count(3)])
    }

    func testAPersonNotLoadedYetIsCountedButNotNamed() {
        // Two editing, one name known: "Milli and 1 other", never "Milli and Tom".
        XCTAssertEqual(sharedMessageEditingStatusShapes(names: ["Milli"], count: 2), [.oneAndOthers("Milli", 1), .count(2)])
        // Nobody loaded: the count alone.
        XCTAssertEqual(sharedMessageEditingStatusShapes(names: [], count: 12), [.count(12)])
    }

    func testEmptyNamesAreSkipped() {
        XCTAssertEqual(sharedMessageEditingStatusShapes(names: ["", "Tom"], count: 2), [.oneAndOthers("Tom", 1), .count(2)])
    }
}

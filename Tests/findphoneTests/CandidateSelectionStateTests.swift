import XCTest
@testable import findphone

final class CandidateSelectionStateTests: XCTestCase {
    func testInitialState() {
        let state = CandidateSelectionState()
        XCTAssertNil(state.currentIdentity())
        XCTAssertNil(state.currentIndex(oneBased: true))
        XCTAssertEqual(state.selectedIndex, 0)
    }

    func testSingleCandidate() {
        var state = CandidateSelectionState(initialCandidates: ["a"])
        XCTAssertEqual(state.currentIdentity(), "a")
        XCTAssertEqual(state.currentIndex(oneBased: true), 1)

        state.moveUp()
        XCTAssertEqual(state.currentIdentity(), "a")

        state.moveDown()
        XCTAssertEqual(state.currentIdentity(), "a")
    }

    func testMovementAndReplace() {
        var state = CandidateSelectionState(initialCandidates: ["a", "b", "c"])
        XCTAssertEqual(state.currentIndex(oneBased: true), 1)

        state.moveDown()
        XCTAssertEqual(state.currentIdentity(), "b")

        state.moveDown()
        XCTAssertEqual(state.currentIdentity(), "c")

        state.moveDown()
        XCTAssertEqual(state.currentIdentity(), "a")

        state.moveUp()
        XCTAssertEqual(state.currentIdentity(), "c")

        state.replaceCandidates(["x", "y", "z"])
        XCTAssertEqual(state.currentIdentity(), "z")
    }

    func testSelectionAndClear() {
        var state = CandidateSelectionState(initialCandidates: ["a", "b", "c"], selectedIndex: 1)
        XCTAssertEqual(state.currentIdentity(), "b")

        state.lockCurrent()
        XCTAssertEqual(state.lockedIdentity, "b")

        state.replaceCandidates(["c", "a", "b"])
        XCTAssertEqual(state.currentIdentity(), "b")
        XCTAssertEqual(state.currentIdentity(), state.lockedIdentity)

        state.clearLock()
        XCTAssertNil(state.lockedIdentity)
    }

    func testPreservesLockedIdentityAcrossCandidatesChange() {
        var state = CandidateSelectionState(initialCandidates: ["a", "b", "c"])
        state.lockCurrent()
        XCTAssertEqual(state.lockedIdentity, "a")

        state.replaceCandidates(["c", "a", "b"])
        XCTAssertEqual(state.currentIdentity(), "a")
    }
}

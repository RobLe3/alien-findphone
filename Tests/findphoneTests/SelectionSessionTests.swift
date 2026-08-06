import XCTest
@testable import findphone

final class ManualSelectionSessionTests: XCTestCase {
    private final class SequencedInputReader {
        private let values: [String?]
        private var index = 0
        private let lock = NSLock()
        private(set) var readCalls = 0

        init(_ values: [String?]) {
            self.values = values
        }

        func readLine() -> String? {
            lock.lock()
            defer { lock.unlock() }
            defer { readCalls += 1 }

            guard index < values.count else { return nil }
            let next = values[index]
            index += 1
            return next
        }
    }

    private struct SnapshotState {
        var candidates: [Advertiser]

        init(candidates: [Advertiser]) {
            self.candidates = candidates
        }

        func snapshot() -> ([Advertiser], Date) {
            (candidates, Date())
        }
    }

    private func candidate(
        _ identity: String,
        name: String? = "Device",
        peak: Int = -80,
        smoothed: Double = -80,
        types: Set<UInt8> = [],
        last: Date = Date()
    ) -> Advertiser {
        Advertiser(identity: identity, name: name, peak: peak, smoothed: smoothed, types: types, last: last)
    }

    func testStartRequestsSingleInputRead() {
        let state = SnapshotState(candidates: [candidate("id-1")])
        let reader = SequencedInputReader(["q"])
        let completion = expectation(description: "session complete")

        let session = ManualSelectionSession(
            snapshotProvider: state.snapshot,
            redact: false,
            onCompletion: { _ in
                completion.fulfill()
            },
            readInput: { reader.readLine() },
            inputQueue: DispatchQueue(label: "findphone.selection.session.tests.1")
        )

        session.start(inputEnabled: false)
        wait(for: [completion], timeout: 1.0)

        XCTAssertEqual(reader.readCalls, 1)
    }

    func testStartingTwiceDoesNotQueueSecondInputReader() {
        let state = SnapshotState(candidates: [candidate("id-1"), candidate("id-2")])
        let reader = SequencedInputReader(["q", "2"])
        let completion = expectation(description: "session complete")

        let session = ManualSelectionSession(
            snapshotProvider: state.snapshot,
            redact: false,
            onCompletion: { _ in
                completion.fulfill()
            },
            readInput: { reader.readLine() },
            inputQueue: DispatchQueue(label: "findphone.selection.session.tests.2")
        )

        session.start(inputEnabled: false)
        session.start(inputEnabled: false)
        wait(for: [completion], timeout: 1.0)

        XCTAssertEqual(reader.readCalls, 1)
    }

    func testInvalidInputSchedulesExactlyOneAdditionalRead() {
        let state = SnapshotState(candidates: [candidate("id-1"), candidate("id-2")])
        let reader = SequencedInputReader(["abc", "2"])
        let completion = expectation(description: "session complete")
        var selectedIdentity: String?

        let session = ManualSelectionSession(
            snapshotProvider: state.snapshot,
            redact: false,
            onCompletion: { selected in
                selectedIdentity = selected
                completion.fulfill()
            },
            readInput: { reader.readLine() },
            inputQueue: DispatchQueue(label: "findphone.selection.session.tests.3")
        )

        session.start(inputEnabled: false)
        wait(for: [completion], timeout: 1.0)

        XCTAssertEqual(selectedIdentity, "id-2")
        XCTAssertEqual(reader.readCalls, 2)
    }

    func testValidSelectionCompletesExactlyOnce() {
        let state = SnapshotState(candidates: [candidate("id-1"), candidate("id-2")])
        let reader = SequencedInputReader(["2", "1"])
        let completion = expectation(description: "session complete")

        var completionCount = 0
        let session = ManualSelectionSession(
            snapshotProvider: state.snapshot,
            redact: false,
            onCompletion: { selected in
                completionCount += 1
                XCTAssertEqual(selected, "id-2")
                completion.fulfill()
            },
            readInput: { reader.readLine() },
            inputQueue: DispatchQueue(label: "findphone.selection.session.tests.4")
        )

        session.start(inputEnabled: false)

        wait(for: [completion], timeout: 1.0)

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(reader.readCalls, 1)
    }

    func testQuitCompletesOnceAndStopsReading() {
        let state = SnapshotState(candidates: [candidate("id-1"), candidate("id-2")])
        let reader = SequencedInputReader(["q", "1"])
        let completion = expectation(description: "session complete")

        var completionCount = 0
        let session = ManualSelectionSession(
            snapshotProvider: state.snapshot,
            redact: false,
            onCompletion: { selected in
                completionCount += 1
                XCTAssertNil(selected)
                completion.fulfill()
            },
            readInput: { reader.readLine() },
            inputQueue: DispatchQueue(label: "findphone.selection.session.tests.5")
        )

        session.start(inputEnabled: false)

        wait(for: [completion], timeout: 1.0)

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(reader.readCalls, 1)
    }

    func testEOFCompletesOnceAndStopsReading() {
        let state = SnapshotState(candidates: [candidate("id-1")])
        let reader = SequencedInputReader([nil, "q"])
        let completion = expectation(description: "session complete")

        var completionCount = 0
        let session = ManualSelectionSession(
            snapshotProvider: state.snapshot,
            redact: false,
            onCompletion: { selected in
                completionCount += 1
                XCTAssertNil(selected)
                completion.fulfill()
            },
            readInput: { reader.readLine() },
            inputQueue: DispatchQueue(label: "findphone.selection.session.tests.6")
        )

        session.start(inputEnabled: false)

        wait(for: [completion], timeout: 1.0)

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(reader.readCalls, 1)
    }

    func testEmptyCandidateStateCanTransitionToCandidates() {
        var state = SnapshotState(candidates: [])
        let reader = SequencedInputReader(["q"])
        let completion = expectation(description: "session complete")

        let session = ManualSelectionSession(
            snapshotProvider: state.snapshot,
            redact: false,
            onCompletion: { _ in completion.fulfill() },
            readInput: { reader.readLine() },
            inputQueue: DispatchQueue(label: "findphone.selection.session.tests.7")
        )

        session.start(inputEnabled: false)
        session.refreshAndRender()

        state.candidates = [candidate("id-1")]
        session.refreshAndRender()

        wait(for: [completion], timeout: 1.0)
        XCTAssertEqual(reader.readCalls, 1)
    }

    func testDuplicateDisplayNamesResolveByStableIndexOrder() {
        let state = SnapshotState(candidates: [
            candidate("id-a", name: "Watch"),
            candidate("id-b", name: "Watch"),
            candidate("id-c", name: "Watch")
        ])
        let reader = SequencedInputReader(["3"])
        let completion = expectation(description: "session complete")

        let session = ManualSelectionSession(
            snapshotProvider: state.snapshot,
            redact: false,
            onCompletion: { selected in
                XCTAssertEqual(selected, "id-c")
                completion.fulfill()
            },
            readInput: { reader.readLine() },
            inputQueue: DispatchQueue(label: "findphone.selection.session.tests.8")
        )

        session.start(inputEnabled: false)
        wait(for: [completion], timeout: 1.0)

        XCTAssertEqual(reader.readCalls, 1)
    }

    func testSnapshotUsedForResolutionEvenAfterLiveCandidatesChange() {
        var state = SnapshotState(candidates: [candidate("id-a"), candidate("id-b")])
        let reader = SequencedInputReader(["2"])
        let completion = expectation(description: "session complete")

        let session = ManualSelectionSession(
            snapshotProvider: state.snapshot,
            redact: false,
            onCompletion: { selected in
                XCTAssertEqual(selected, "id-b")
                completion.fulfill()
            },
            readInput: { reader.readLine() },
            inputQueue: DispatchQueue(label: "findphone.selection.session.tests.9")
        )

        session.start(inputEnabled: false)

        state.candidates = [candidate("id-b"), candidate("id-a")]

        wait(for: [completion], timeout: 1.0)

        XCTAssertEqual(reader.readCalls, 1)
    }

    func testCompletionPreventsQueuedInputFromCompletingAgain() {
        let state = SnapshotState(candidates: [candidate("id-1"), candidate("id-2")])
        let reader = SequencedInputReader(["2", "1", nil])
        let completion = expectation(description: "session complete")

        var completionCount = 0
        let session = ManualSelectionSession(
            snapshotProvider: state.snapshot,
            redact: false,
            onCompletion: { selected in
                XCTAssertEqual(selected, "id-2")
                completionCount += 1
                completion.fulfill()
            },
            readInput: { reader.readLine() },
            inputQueue: DispatchQueue(label: "findphone.selection.session.tests.10")
        )

        session.start(inputEnabled: false)

        wait(for: [completion], timeout: 1.0)

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(reader.readCalls, 1)
    }
}

import Foundation

typealias SelectionInputReader = () -> String?

final class ManualSelectionSession {
    private let readInput: SelectionInputReader
    private let snapshotProvider: () -> ([Advertiser], Date)
    private let redact: Bool
    private let onCompletion: (String?) -> Void
    private let inputQueue: DispatchQueue
    private let renderInterval: TimeInterval

    private var isActive = true
    private var selectedCandidates: [Advertiser] = []
    private var refreshTimer: Timer?
    private var isInputPending = false

    init(
        tracker: Tracker,
        redact: Bool,
        onCompletion: @escaping (String?) -> Void,
        readInput: @escaping SelectionInputReader = { readLine(strippingNewline: true) },
        inputQueue: DispatchQueue = DispatchQueue(label: "findphone.selection.input"),
        renderInterval: TimeInterval = 1.0
    ) {
        self.snapshotProvider = {
            let snapshot = tracker.snapshot()
            return (snapshot.candidates, snapshot.at)
        }
        self.redact = redact
        self.onCompletion = onCompletion
        self.readInput = readInput
        self.inputQueue = inputQueue
        self.renderInterval = renderInterval
    }

    /// Test-only initializer.
    init(
        snapshotProvider: @escaping () -> ([Advertiser], Date),
        redact: Bool,
        onCompletion: @escaping (String?) -> Void,
        readInput: @escaping SelectionInputReader = { readLine(strippingNewline: true) },
        inputQueue: DispatchQueue = DispatchQueue(label: "findphone.selection.input"),
        renderInterval: TimeInterval = 1.0
    ) {
        self.snapshotProvider = snapshotProvider
        self.redact = redact
        self.onCompletion = onCompletion
        self.readInput = readInput
        self.inputQueue = inputQueue
        self.renderInterval = renderInterval
    }

    func start(inputEnabled: Bool = true) {
        guard isActive else { return }
        requestInput()
        refreshAndRender()
        guard inputEnabled else { return }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: renderInterval, repeats: true) { [weak self] _ in
            self?.refreshAndRender()
        }
    }

    func requestInput() {
        guard isActive, !isInputPending else { return }
        isInputPending = true

        inputQueue.async { [weak self] in
            guard let self else { return }
            let rawInput = self.readInput()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isInputPending = false
                self.handle(input: rawInput)
            }
        }
    }

    func refreshAndRender() {
        guard isActive else { return }

        let (candidates, snapshotAt) = snapshotProvider()
        selectedCandidates = candidates

        if selectedCandidates.isEmpty {
            print("Nearby Apple handhelds — no candidates yet")
            print("Waiting for nearby devices... (or press q to quit)")
            return
        }

        print("Nearby Apple handhelds — select one to track:\n")
        for (index, candidate) in selectedCandidates.enumerated() {
            let live = Int(candidate.smoothed.rounded())
            let stale = snapshotAt.timeIntervalSince(candidate.last) > 3 ? " (stale)" : ""
            let name = redact ? candidate.kind : candidate.label
            let line = String(format: "%2d. %@ %4d dBm  peak %4d", index + 1, bar(live), live, candidate.peak)
            print("\(line)  \(name)\(stale)")
        }

        print("Select a device number, or q to quit: ", terminator: "")
    }

    private func handle(input: String?) {
        guard isActive else { return }

        guard let rawInput = input else {
            complete(with: nil)
            return
        }

        let outcome = CandidateSelectionResolver.resolve(rawInput: rawInput, candidates: selectedCandidates)
        switch outcome {
        case .quit:
            complete(with: nil)
        case .invalid:
            print("Invalid selection. Enter 1 through \(selectedCandidates.count), or q to quit.")
            requestInput()
        case let .selectedIdentity(identity):
            complete(with: identity)
        }
    }

    private func complete(with identity: String?) {
        guard isActive else { return }
        isActive = false
        isInputPending = false
        refreshTimer?.invalidate()
        onCompletion(identity)
    }
}

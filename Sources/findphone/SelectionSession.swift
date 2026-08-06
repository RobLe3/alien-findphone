import Foundation

final class ManualSelectionSession {
    private let tracker: Tracker
    private let redact: Bool
    private let onCompletion: (String?) -> Void

    private var isActive = true
    private var selectedCandidates: [Advertiser] = []
    private var refreshTimer: Timer?

    init(tracker: Tracker, redact: Bool, onCompletion: @escaping (String?) -> Void) {
        self.tracker = tracker
        self.redact = redact
        self.onCompletion = onCompletion
    }

    func start() {
        startInputReader()
        refreshAndRender()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshAndRender()
        }
    }

    private func startInputReader() {
        DispatchQueue(label: "findphone.selection.input").async { [weak self] in
            while true {
                if let raw = readLine(strippingNewline: true) {
                    DispatchQueue.main.async {
                        self?.handle(input: raw)
                    }
                } else {
                    DispatchQueue.main.async {
                        self?.complete(with: nil)
                    }
                    return
                }
            }
        }
    }

    private func handle(input: String) {
        guard isActive else { return }

        let outcome = CandidateSelectionResolver.resolve(rawInput: input, candidates: selectedCandidates)
        switch outcome {
        case .quit:
            complete(with: nil)
        case .invalid:
            print("Invalid selection. Enter 1 through \(selectedCandidates.count), or q to quit.")
        case let .selectedIdentity(identity):
            complete(with: identity)
        }
    }

    private func refreshAndRender() {
        guard isActive else { return }

        let snapshot = tracker.snapshot()
        selectedCandidates = snapshot.candidates

        if selectedCandidates.isEmpty {
            print("Nearby Apple handhelds — no candidates yet")
            print("Waiting for nearby devices... (or press q to quit)")
            return
        }

        print("Nearby Apple handhelds — select one to track:\n")
        for (index, candidate) in selectedCandidates.enumerated() {
            let live = Int(candidate.smoothed.rounded())
            let stale = snapshot.at.timeIntervalSince(candidate.last) > 3 ? " (stale)" : ""
            let name = redact ? candidate.kind : candidate.label
            let line = String(format: "%2d. %@ %4d dBm  peak %4d", index + 1, bar(live), live, candidate.peak)
            print("\(line)  \(name)\(stale)")
        }

        print("Select a device number, or q to quit: ", terminator: "")
    }

    private func complete(with identity: String?) {
        guard isActive else { return }
        isActive = false
        refreshTimer?.invalidate()
        onCompletion(identity)
    }
}

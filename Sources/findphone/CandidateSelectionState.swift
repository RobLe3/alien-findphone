import Foundation

struct CandidateSelectionState {
    private(set) var candidates: [String]
    private(set) var selectedIndex: Int
    private(set) var lockedIdentity: String?

    init(initialCandidates: [String] = [], selectedIndex: Int = 0) {
        self.candidates = initialCandidates
        self.selectedIndex = initialCandidates.isEmpty ? 0 : min(selectedIndex, initialCandidates.count - 1)
        self.lockedIdentity = nil
    }

    mutating func replaceCandidates(_ identities: [String], selectedIdentity: String? = nil) {
        candidates = identities
        let anchor = selectedIdentity ?? lockedIdentity
        if let anchor,
           let explicitIndex = identities.firstIndex(of: anchor) {
            selectedIndex = explicitIndex
        } else if candidates.isEmpty {
            selectedIndex = 0
            lockedIdentity = nil
        } else {
            selectedIndex = min(selectedIndex, candidates.count - 1)
        }
    }

    mutating func moveUp() {
        guard !candidates.isEmpty else { return }
        selectedIndex = (selectedIndex + candidates.count - 1) % candidates.count
    }

    mutating func moveDown() {
        guard !candidates.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % candidates.count
    }

    mutating func clearLock() {
        lockedIdentity = nil
    }

    mutating func lockCurrent() {
        lockedIdentity = currentIdentity()
    }

    func currentIdentity() -> String? {
        guard !candidates.isEmpty else { return nil }
        guard selectedIndex >= 0 && selectedIndex < candidates.count else { return nil }
        return candidates[selectedIndex]
    }

    func currentIndex(oneBased: Bool) -> Int? {
        guard !candidates.isEmpty else { return nil }
        return oneBased ? selectedIndex + 1 : selectedIndex
    }
}

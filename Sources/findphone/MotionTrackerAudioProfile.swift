import Foundation
import AVFoundation

struct MotionTrackerAudioProfile {
    let bpm: Double = 84.72
    let firstBeatOffsetSeconds: Double = 0.058
    let beatsPerPhrase: Int = 2

    let idleLoopBeatRange: Range<Int> = 0..<14
    let transitionBeatRange: Range<Int> = 14..<15
    let trackingStartBeat: Int = 15
    let fallbackIdlePairIndex: Int = 0

    let attackTau: TimeInterval = 0.20
    let releaseTau: TimeInterval = 0.80
    let proximityHysteresis: Double = 0.04

    let freshTargetWindow: TimeInterval = 2.0
    let fadingTargetWindow: TimeInterval = 5.0

    let proximityFarRSSI: Double = -95.0
    let proximityNearRSSI: Double = -55.0

    var beatDuration: TimeInterval { 60.0 / bpm }

    func trackingRange(totalBeats: Int) -> Range<Int> {
        let start = max(trackingStartBeat, 0)
        if start >= totalBeats {
            return 0..<min(totalBeats, max(1, start))
        }
        return start..<totalBeats
    }

    func clampPairIndex(_ value: Int, pairCount: Int) -> Int {
        guard pairCount > 0 else { return 0 }
        return max(0, min(pairCount - 1, value))
    }
}

struct TargetAudioState {
    let identifier: String?
    let rssi: Int?
    let confidence: Double
    let lastSeen: Date?
    let isLocked: Bool
}

enum BeatAccent: Int {
    case strong
    case weak
    case unknown
}

struct BeatCell {
    let index: Int
    let startFrame: AVAudioFramePosition
    let frameLength: AVAudioFrameCount
    let accent: BeatAccent
    let sourceProgress: Double
    let buffer: AVAudioPCMBuffer
}

struct BeatPair {
    let pairIndex: Int
    let first: BeatCell
    let second: BeatCell
    let sourceProgress: Double
}

struct AudioBeatDiagnostics: Equatable {
    let requestedPair: Int
    let currentPair: Int
    let scheduledBeat: Int
    let queuedBeats: Int
    let underrunCount: Int
    let scheduledBeatCount: Int
    let completedBeatCount: Int
    let filteredProximity: Double
    let sourcePairCount: Int
    let engineRestarts: Int
}

final class AudioProximityFilter {
    private let attackTau: TimeInterval
    private let releaseTau: TimeInterval
    private var lastUpdated: Date?

    private(set) var filtered: Double

    init(initial: Double = 0.0, attackTau: TimeInterval, releaseTau: TimeInterval) {
        self.filtered = initial
        self.attackTau = max(0.001, attackTau)
        self.releaseTau = max(0.001, releaseTau)
    }

    func reset(to value: Double = 0.0) {
        filtered = max(0.0, min(1.0, value))
        lastUpdated = nil
    }

    func update(raw: Double, now: Date) -> Double {
        let clamped = max(0.0, min(1.0, raw))
        guard let previous = lastUpdated else {
            lastUpdated = now
            filtered = clamped
            return filtered
        }
        let dt = max(0.0, now.timeIntervalSince(previous))
        lastUpdated = now

        let tau = clamped > filtered ? attackTau : releaseTau
        let alpha = 1.0 - exp(-dt / tau)
        filtered += alpha * (clamped - filtered)
        filtered = max(0.0, min(1.0, filtered))
        return filtered
    }
}

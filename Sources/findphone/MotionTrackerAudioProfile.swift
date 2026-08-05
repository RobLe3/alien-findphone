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

    let desiredToneLevelCount: Int = 8
    let minimumToneLevelCount: Int = 5
    let maximumToneLevelCount: Int = 12
    let duplicateToneCents: Double = 24.0

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

    func clampToneLevel(_ value: Int, levelCount: Int) -> Int {
        guard levelCount > 0 else { return 0 }
        return max(0, min(levelCount - 1, value))
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

struct ToneAnalysis {
    let frequencyHz: Double
    let confidence: Double
    let rms: Double
    let peakAmplitude: Double
}

struct TrackerToneLevel {
    let level: Int
    let sourcePairIndex: Int
    let pair: BeatPair
    let dominantFrequencyHz: Double
    let pitchConfidence: Double
    let normalizationGain: Float
}

struct TrackerToneBank {
    let levels: [TrackerToneLevel]

    var count: Int { levels.count }

    func level(at index: Int) -> TrackerToneLevel {
        let safe = max(0, min(levels.count - 1, index))
        return levels[safe]
    }
}

final class ToneLevelSelector {
    private let levelCount: Int
    private let hysteresis: Double

    private(set) var selectedLevel: Int

    init(levelCount: Int, initialLevel: Int = 0, hysteresis: Double = 0.04) {
        self.levelCount = max(1, levelCount)
        self.hysteresis = max(0.0, hysteresis)
        self.selectedLevel = max(0, min(self.levelCount - 1, initialLevel))
    }

    func reset(to level: Int) {
        selectedLevel = max(0, min(levelCount - 1, level))
    }

    func update(proximity: Double) -> Int {
        guard levelCount > 1 else {
            selectedLevel = 0
            return 0
        }

        let value = max(0.0, min(1.0, proximity))
        let divisor = Double(levelCount - 1)
        let half = hysteresis * 0.5

        while selectedLevel < levelCount - 1 {
            let upward = (Double(selectedLevel) + 0.5) / divisor
            if value >= upward + half {
                selectedLevel += 1
                continue
            }
            break
        }

        while selectedLevel > 0 {
            let downward = (Double(selectedLevel) - 0.5) / divisor
            if value <= downward - half {
                selectedLevel -= 1
                continue
            }
            break
        }

        return selectedLevel
    }
}

struct AudioBeatDiagnostics: Equatable {
    let requestedToneLevel: Int
    let currentToneLevel: Int
    let scheduledBeat: Int
    let queuedBeats: Int
    let underrunCount: Int
    let scheduledBeatCount: Int
    let completedBeatCount: Int
    let filteredProximity: Double
    let targetToneFrequencyHz: Int
    let tonePairIndex: Int
    let engineRestarts: Int
}

final class AudioProximityFilter {
    private let attackTau: TimeInterval
    private let releaseTau: TimeInterval
    private var lastUpdated: Date?

    private(set) var filtered: Double

    init(initial: Double = 0.0, attackTau: TimeInterval, releaseTau: TimeInterval) {
        self.filtered = max(0.0, min(1.0, initial))
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

func centsBetween(_ lower: Double, _ upper: Double) -> Double {
    guard lower > 0 && upper > 0 else { return 0 }
    return 1200.0 * log2(upper / lower)
}

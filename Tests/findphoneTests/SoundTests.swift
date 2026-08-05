#if canImport(Darwin) && canImport(XCTest)
import Foundation
import Darwin
import XCTest
import AVFoundation

@testable import findphone

final class SoundTests: XCTestCase {
    func testBundledTrackerAudioIsDiscoverable() {
        let url = Bundle.module.url(forResource: "alien_original_motion_tracker", withExtension: "m4a")
        XCTAssertNotNil(url)
    }

    func testAudioSourceResolutionIsComparable() {
        XCTAssertEqual(AudioSourceResolution.bundled, .bundled)
        XCTAssertEqual(AudioSourceResolution.fallbackSystem, .fallbackSystem)
        XCTAssertEqual(AudioSourceResolution.explicitPath("/tmp/a.m4a"), .explicitPath("/tmp/a.m4a"))
        XCTAssertEqual(AudioSourceResolution.overrideEnv("/tmp/a.m4a"), .overrideEnv("/tmp/a.m4a"))
    }

    func testBundledTrackerAudioCanBeOpenedAndMatchesMetadata() throws {
        guard let url = Bundle.module.url(forResource: "alien_original_motion_tracker", withExtension: "m4a") else {
            XCTFail("missing bundled audio")
            return
        }

        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.processingFormat.sampleRate, 40_000)
        XCTAssertLessThan(file.processingFormat.sampleRate, 50_000)
        XCTAssertEqual(file.processingFormat.sampleRate, 44_100, accuracy: 1.0)
        XCTAssertEqual(file.processingFormat.channelCount, 2)

        let duration = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertEqual(duration, 85.2, accuracy: 0.2)
    }

    func testBeatDurationUsesReferenceTempo() {
        let profile = MotionTrackerAudioProfile()
        XCTAssertEqual(profile.bpm, 84.72, accuracy: 0.01)
        XCTAssertEqual(profile.beatDuration, 60.0 / 84.72, accuracy: 0.0005)
    }

    func testSourceFrameHelperUsesAbsoluteBeatFrameExpression() {
        let profile = MotionTrackerAudioProfile()
        let exact = 60.0 / profile.bpm * 44_100
        let first = Clicker.sourceFrame(forBeat: 0, sampleRate: 44_100, profile: profile, exactFramesPerBeat: exact)
        let tenth = Clicker.sourceFrame(forBeat: 10, sampleRate: 44_100, profile: profile, exactFramesPerBeat: exact)
        let expectedFirst = Int((profile.firstBeatOffsetSeconds * 44_100).rounded())
        XCTAssertEqual(first, expectedFirst)
        XCTAssertGreaterThan(tenth, first)
    }

    func testBeatGridBoundariesAreContiguousAndBounded() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )!
        let frameCount: AVAudioFrameCount = 40000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("create buffer")
            return
        }
        buffer.frameLength = frameCount

        let profile = MotionTrackerAudioProfile()
        let exactFramesPerBeat = 60.0 / profile.bpm * format.sampleRate
        let cells = Clicker.buildBeatCells(from: buffer, profile: profile, exactFramesPerBeat: exactFramesPerBeat)
        XCTAssertFalse(cells.isEmpty)

        for idx in 0..<cells.count {
            let cell = cells[idx]
            let expectedStart = Clicker.sourceFrame(
                forBeat: cell.index,
                sampleRate: format.sampleRate,
                profile: profile,
                exactFramesPerBeat: exactFramesPerBeat
            )
            XCTAssertEqual(cell.startFrame, AVAudioFramePosition(expectedStart))
            XCTAssertGreaterThan(cell.frameLength, 0)
            XCTAssertGreaterThanOrEqual(cell.startFrame, 0)
            XCTAssertLessThanOrEqual(
                cell.startFrame + AVAudioFramePosition(cell.frameLength),
                AVAudioFramePosition(buffer.frameLength)
            )
            if idx > 0 {
                let previous = cells[idx - 1]
                XCTAssertEqual(cell.index, previous.index + 1)
                XCTAssertGreaterThan(cell.startFrame, previous.startFrame)
                XCTAssertEqual(previous.startFrame + AVAudioFramePosition(previous.frameLength), cell.startFrame)
            }
        }

        let finalEnd = cells.last!.startFrame + AVAudioFramePosition(cells.last!.frameLength)
        let expectedFrames = Int((Double(cells.count) * exactFramesPerBeat).rounded())
        let drift = abs(expectedFrames - Int(finalEnd - cells.first!.startFrame))
        XCTAssertLessThanOrEqual(drift, 1)
    }

    func testBeatPairIntegrityPreservesSourceOrder() throws {
        guard let (buffer, profile) = try loadedTrackerBuffer() else {
            return
        }

        let pairGrid = Clicker.buildBeatPairs(from: buffer, profile: profile)
        let allPairs = pairGrid.idle + pairGrid.tracking
        XCTAssertFalse(allPairs.isEmpty)

        for pair in allPairs {
            XCTAssertEqual(pair.second.index, pair.first.index + 1)
            XCTAssertEqual(
                pair.first.startFrame + AVAudioFramePosition(pair.first.frameLength),
                pair.second.startFrame
            )
            XCTAssertLessThan(pair.first.sourceProgress, pair.second.sourceProgress)
            XCTAssertGreaterThan(pair.first.frameLength, 0)
            XCTAssertGreaterThan(pair.second.frameLength, 0)
            XCTAssertNotEqual(pair.first.accent, .unknown)
            XCTAssertNotEqual(pair.second.accent, .unknown)
            XCTAssertNotEqual(pair.first.accent, pair.second.accent)
        }

        if let lastIdlePair = pairGrid.idle.last {
            XCTAssertLessThanOrEqual(lastIdlePair.first.index, 13)
            XCTAssertEqual(lastIdlePair.second.index, lastIdlePair.first.index + 1)
        }

        XCTAssertEqual(pairGrid.tracking.first?.first.index, profile.trackingStartBeat)
        if pairGrid.tracking.count > 1 {
            XCTAssertEqual(pairGrid.tracking[1].first.index, profile.trackingStartBeat + 2)
        }
    }

    func testToneBankIsMonotonicAndDeduplicated() throws {
        guard let (buffer, profile) = try loadedTrackerBuffer() else { return }

        let cells = Clicker.buildBeatCells(
            from: buffer,
            profile: profile,
            exactFramesPerBeat: 60.0 / profile.bpm * buffer.format.sampleRate
        )
        let pairs = Clicker.buildBeatPairs(from: cells, profile: profile).tracking
        guard let bank = Clicker.buildToneBank(from: pairs, profile: profile) else {
            XCTFail("failed to build tone bank")
            return
        }

        XCTAssertGreaterThanOrEqual(bank.count, 5)

        for idx in 1..<bank.count {
            let previous = bank.levels[idx - 1]
            let current = bank.levels[idx]
            XCTAssertLessThan(previous.dominantFrequencyHz, current.dominantFrequencyHz)
        }

        let pairIndices = bank.levels.map(\.sourcePairIndex)
        XCTAssertEqual(pairIndices.count, Set(pairIndices).count)
    }

    func testToneBankHasUsefulPitchSpan() throws {
        guard let (buffer, profile) = try loadedTrackerBuffer() else { return }

        let cells = Clicker.buildBeatCells(
            from: buffer,
            profile: profile,
            exactFramesPerBeat: 60.0 / profile.bpm * buffer.format.sampleRate
        )
        let pairs = Clicker.buildBeatPairs(from: cells, profile: profile).tracking
        guard let bank = Clicker.buildToneBank(from: pairs, profile: profile) else {
            XCTFail("failed to build tone bank")
            return
        }

        let minFrequency = bank.levels.map(\.dominantFrequencyHz).min() ?? 0
        let maxFrequency = bank.levels.map(\.dominantFrequencyHz).max() ?? 0

        let pitchSpanCents = 1200.0 * log2(maxFrequency / minFrequency)
        XCTAssertGreaterThan(pitchSpanCents, 250)
    }

    func testToneSelectorHoldsLevelForSteadySignal() {
        let selector = ToneLevelSelector(levelCount: 8, initialLevel: 3, hysteresis: 0.04)
        var now = Date()
        let filter = AudioProximityFilter(initial: 0.0, attackTau: 0.20, releaseTau: 0.80)

        var last: Int?
        for _ in 0..<120 {
            let filtered = filter.update(raw: 0.55, now: now)
            let current = selector.update(proximity: filtered)
            if let prior = last {
                XCTAssertEqual(current, prior)
            }
            last = current
            now = now.addingTimeInterval(0.25)
        }
    }

    func testToneSelectorCanJumpAcrossLevelsInOneUpdate() {
        let selector = ToneLevelSelector(levelCount: 8, initialLevel: 1, hysteresis: 0.04)
        _ = selector.update(proximity: 0.2)
        let fastJump = selector.update(proximity: 0.95)
        XCTAssertGreaterThan(fastJump, 4)

        let down = selector.update(proximity: 0.05)
        XCTAssertLessThan(down, 2)
    }

    func testProximityMappingIsMonotonicAcrossRange() {
        let profile = MotionTrackerAudioProfile()
        let levelCount = 10
        let nearLevel = selectorValue(levelCount: levelCount, rssi: -55, profile: profile)
        let midLevel = selectorValue(levelCount: levelCount, rssi: -75, profile: profile)
        let farLevel = selectorValue(levelCount: levelCount, rssi: -95, profile: profile)

        XCTAssertLessThanOrEqual(farLevel, midLevel)
        XCTAssertLessThanOrEqual(midLevel, nearLevel)

        XCTAssertEqual(
            selectorValue(levelCount: levelCount, rssi: -75, profile: profile),
            selectorValue(levelCount: levelCount, rssi: -75, profile: profile)
        )
    }

    func testTrackToneSelectionUpdatesOnlyFromProximityBoundaries() {
        let selector = ToneLevelSelector(levelCount: 8, initialLevel: 4, hysteresis: 0.04)

        let holdLevel = selector.update(proximity: 0.50)
        XCTAssertEqual(selector.update(proximity: 0.50 + 0.01), holdLevel)
        XCTAssertEqual(selector.update(proximity: 0.52), holdLevel)

        let near = selector.update(proximity: 0.95)
        XCTAssertGreaterThan(near, holdLevel)

        let stillNear = selector.update(proximity: 0.95)
        XCTAssertEqual(stillNear, near)

        let far = selector.update(proximity: 0.10)
        XCTAssertLessThan(far, near)
    }

    func testProximityFilterAttackIsFasterThanRelease() {
        let filterAttack = AudioProximityFilter(initial: 0.2, attackTau: 0.20, releaseTau: 0.80)
        let t0 = Date()
        _ = filterAttack.update(raw: 0.2, now: t0)
        let afterAttack = filterAttack.update(raw: 0.9, now: t0.addingTimeInterval(0.2))

        let filterRelease = AudioProximityFilter(initial: 0.9, attackTau: 0.20, releaseTau: 0.80)
        _ = filterRelease.update(raw: 0.9, now: t0)
        let afterRelease = filterRelease.update(raw: 0.2, now: t0.addingTimeInterval(0.2))

        XCTAssertGreaterThan(afterAttack - 0.2, 0.2)
        XCTAssertLessThan(afterRelease, 0.9)

        let attackStep = afterAttack - 0.2
        let releaseStep = 0.9 - afterRelease
        XCTAssertGreaterThan(attackStep, releaseStep)
    }

    func testResolveAudioURLRespectsExplicitInvalidPath() {
        let invalidPath = "/tmp/there-is-no-tracker-file-please-do-not-create-this-file.m4a"
        let resolved = Clicker.resolveAudioURL(explicitPath: invalidPath)
        XCTAssertNil(resolved)
    }

    func testResolveAudioURLFallsBackToBundle() {
        let resolved = Clicker.resolveAudioURL(explicitPath: nil)
        XCTAssertNotNil(resolved)
        if let resolved {
            XCTAssertEqual(resolved.resolution, .bundled)
            XCTAssertNotNil(resolved.url.path)
        }
    }

    func testInvalidOverridePathReturnsNil() {
        let originalOverride = ProcessInfo.processInfo.environment["ALIEN_FINDPHONE_AUDIO_FILE"]
        defer {
            if let originalOverride {
                setenv("ALIEN_FINDPHONE_AUDIO_FILE", originalOverride, 1)
            } else {
                unsetenv("ALIEN_FINDPHONE_AUDIO_FILE")
            }
        }

        setenv("ALIEN_FINDPHONE_AUDIO_FILE", "/tmp/no-such-file-please-do-not-create.m4a", 1)
        let resolved = Clicker.resolveAudioURL(explicitPath: nil)
        XCTAssertNil(resolved)

        setenv("ALIEN_FINDPHONE_AUDIO_FILE", "", 1)
        let fallback = Clicker.resolveAudioURL(explicitPath: nil)
        XCTAssertNotNil(fallback)
    }

    func testDecodeAudioFileConvertsToPCM() throws {
        guard let url = Bundle.module.url(forResource: "alien_original_motion_tracker", withExtension: "m4a") else {
            XCTFail("missing bundled audio")
            return
        }

        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let buffer = Clicker.decodeAudioFile(at: url, decodeTo: outputFormat)
        XCTAssertNotNil(buffer)
        if let buffer {
            XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32)
            XCTAssertEqual(buffer.format.channelCount, 2)
            XCTAssertEqual(buffer.format.sampleRate, outputFormat.sampleRate, accuracy: 1.0)
            XCTAssertGreaterThan(buffer.frameLength, 0)
        }
    }

    func testSourceBoundariesDoNotExceedFrameCountForLongBuffer() throws {
        guard let (buffer, profile) = try loadedTrackerBuffer() else { return }

        let exactFramesPerBeat = 60.0 / profile.bpm * buffer.format.sampleRate
        let cells = Clicker.buildBeatCells(
            from: buffer,
            profile: profile,
            exactFramesPerBeat: exactFramesPerBeat
        )

        guard let last = cells.last else {
            XCTFail("no cells")
            return
        }

        XCTAssertLessThanOrEqual(
            last.startFrame + AVAudioFramePosition(last.frameLength),
            AVAudioFramePosition(buffer.frameLength)
        )
    }

    // MARK: - Helpers

    private func loadedTrackerBuffer() throws -> (AVAudioPCMBuffer, MotionTrackerAudioProfile)? {
        guard let url = Bundle.module.url(forResource: "alien_original_motion_tracker", withExtension: "m4a") else {
            XCTFail("missing bundled audio")
            return nil
        }

        let file = try AVAudioFile(forReading: url)
        let decodeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.processingFormat.sampleRate,
            channels: file.processingFormat.channelCount,
            interleaved: false
        )!
        let frameCapacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: decodeFormat, frameCapacity: frameCapacity) else {
            XCTFail("decode buffer")
            return nil
        }
        buffer.frameLength = frameCapacity
        try file.read(into: buffer)

        return (buffer, MotionTrackerAudioProfile())
    }

    private func selectorValue(levelCount: Int, rssi: Int, profile: MotionTrackerAudioProfile) -> Int {
        let raw = (Double(rssi) - profile.proximityFarRSSI) / (profile.proximityNearRSSI - profile.proximityFarRSSI)
        return ToneLevelSelector(levelCount: levelCount, initialLevel: 0, hysteresis: profile.proximityHysteresis).update(proximity: max(0, min(1, raw)))
    }
}
#endif

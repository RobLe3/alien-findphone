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
        XCTAssertEqual(first, Int(profile.firstBeatOffsetSeconds * 44_100))
        XCTAssertGreaterThan(tenth, first)
    }

    func testBeatGridBoundariesUseAbsoluteFrameIndexing() throws {
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

    func testBeatRangeAndPairIntegrity() throws {
        guard let url = Bundle.module.url(forResource: "alien_original_motion_tracker", withExtension: "m4a") else {
            XCTFail("missing bundled audio")
            return
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
            return
        }
        buffer.frameLength = frameCapacity
        try file.read(into: buffer)

        let profile = MotionTrackerAudioProfile()
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

        let validIdleIndices = profile.idleLoopBeatRange
        let validTrackingStart = profile.trackingStartBeat
        XCTAssertGreaterThan(pairGrid.idle.last?.first.index ?? -1, -1)
        for pair in pairGrid.idle {
            XCTAssertTrue(validIdleIndices.contains(pair.first.index))
        }

        if !pairGrid.tracking.isEmpty {
            XCTAssertTrue(pairGrid.tracking.first!.first.index >= validTrackingStart)
            for pair in pairGrid.tracking {
                XCTAssertFalse(profile.transitionBeatRange.contains(pair.first.index))
                XCTAssertFalse(profile.transitionBeatRange.contains(pair.second.index))
            }
            XCTAssertEqual(pairGrid.tracking.first?.first.index, 15)
            XCTAssertEqual(pairGrid.tracking.first?.second.index, 16)
            if pairGrid.tracking.count > 1 {
                XCTAssertEqual(pairGrid.tracking[1].first.index, 17)
                XCTAssertEqual(pairGrid.tracking[1].second.index, 18)
            }
            if let lastIdlePair = pairGrid.idle.last {
                XCTAssertEqual(lastIdlePair.first.index, 12)
                XCTAssertEqual(lastIdlePair.second.index, 13)
            }
        }
    }

    func testPairBoundaryTransitionAndPhasePreservation() {
        let profile = MotionTrackerAudioProfile()

        var step = Clicker.nextPair(
            beat: 0,
            requestedPair: 5,
            currentPair: 1,
            pairChangeBoundary: 1,
            pairCount: 10,
            beatsPerPhrase: profile.beatsPerPhrase
        )
        XCTAssertFalse(step.changed)
        XCTAssertEqual(step.newCurrentPair, 1)
        XCTAssertEqual(step.newBoundary, 1)

        step = Clicker.nextPair(
            beat: 1,
            requestedPair: 5,
            currentPair: 1,
            pairChangeBoundary: 1,
            pairCount: 10,
            beatsPerPhrase: profile.beatsPerPhrase
        )
        XCTAssertTrue(step.changed)
        XCTAssertEqual(step.newCurrentPair, 2)
        XCTAssertEqual(step.newBoundary, 3)

        step = Clicker.nextPair(
            beat: 2,
            requestedPair: 5,
            currentPair: step.newCurrentPair,
            pairChangeBoundary: step.newBoundary,
            pairCount: 10,
            beatsPerPhrase: profile.beatsPerPhrase
        )
        XCTAssertFalse(step.changed)
        XCTAssertEqual(step.newCurrentPair, 2)

        step = Clicker.nextPair(
            beat: 3,
            requestedPair: 5,
            currentPair: 2,
            pairChangeBoundary: 3,
            pairCount: 10,
            beatsPerPhrase: profile.beatsPerPhrase
        )
        XCTAssertTrue(step.changed)
        XCTAssertEqual(step.newCurrentPair, 3)
        XCTAssertEqual(step.newBoundary, 5)
    }

    func testPairTransitionDirectionMatchesRequestedMovement() {
        let profile = MotionTrackerAudioProfile()

        let rise = Clicker.nextPair(
            beat: 3,
            requestedPair: 4,
            currentPair: 3,
            pairChangeBoundary: 1,
            pairCount: 6,
            beatsPerPhrase: profile.beatsPerPhrase
        )
        XCTAssertTrue(rise.changed)
        XCTAssertEqual(rise.newCurrentPair, 4)

        let fall = Clicker.nextPair(
            beat: 3,
            requestedPair: 2,
            currentPair: 3,
            pairChangeBoundary: 1,
            pairCount: 6,
            beatsPerPhrase: profile.beatsPerPhrase
        )
        XCTAssertTrue(fall.changed)
        XCTAssertEqual(fall.newCurrentPair, 2)
    }

    func testProximityPairMappingIsMonotonic() {
        let profile = MotionTrackerAudioProfile()
        let pairCount = 20

        func requested(_ proximity: Double) -> Int {
            let raw = max(0.0, min(1.0, proximity))
            return pairCount > 1 ? Int(round(raw * Double(pairCount - 1))) : 0
        }

        let p20 = requested(0.2)
        let p40 = requested(0.4)
        let p60 = requested(0.6)
        let p80 = requested(0.8)

        XCTAssertLessThanOrEqual(p20, p40)
        XCTAssertLessThanOrEqual(p40, p60)
        XCTAssertLessThanOrEqual(p60, p80)

        let stableA = requested(0.45)
        let stableB = requested(0.45)
        XCTAssertEqual(stableA, stableB)
    }

    func testProximityFilterAttackFasterThanRelease() {
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
}
#endif

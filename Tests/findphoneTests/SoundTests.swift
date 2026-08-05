import Foundation
#if canImport(Darwin) && canImport(XCTest)
import Darwin
import XCTest
import AVFoundation

@testable import findphone

final class SoundTests: XCTestCase {
    func testBundledTrackerAudioIsDiscoverable() {
        let url = Bundle.module.url(forResource: "alien_original_motion_tracker", withExtension: "m4a")
        XCTAssertNotNil(url)
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

    func testBeatGridBoundariesUseAbsoluteFrameIndexing() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )!
        let frameCount: AVAudioFrameCount = 40_000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("create buffer")
            return
        }
        buffer.frameLength = frameCount

        // stereo silence is sufficient for boundary calculations.
        let profile = MotionTrackerAudioProfile()
        let exactFramesPerBeat = 60.0 / profile.bpm * format.sampleRate
        let cells = Clicker.buildBeatCells(from: buffer, profile: profile, exactFramesPerBeat: exactFramesPerBeat)
        XCTAssertFalse(cells.isEmpty)

        for cell in cells {
            let expectedStart = Int((Double(profile.firstBeatOffsetSeconds * format.sampleRate) + Double(cell.index) * exactFramesPerBeat).rounded())
            XCTAssertEqual(cell.startFrame, AVAudioFramePosition(expectedStart))
            XCTAssertGreaterThan(cell.frameLength, 0)
            XCTAssertLessThanOrEqual(cell.startFrame, AVAudioFramePosition(cell.startFrame))
            XCTAssertLessThan(Double(cell.startFrame), Double(buffer.frameLength))
        }

        for idx in 1..<cells.count {
            XCTAssertGreaterThan(cells[idx].startFrame, cells[idx - 1].startFrame)
            XCTAssertLessThan(cells[idx - 1].startFrame + AVAudioFramePosition(cells[idx - 1].frameLength), cells[idx].startFrame)
        }
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
            XCTAssertGreaterThan(pair.first.frameLength, 0)
            XCTAssertGreaterThan(pair.second.frameLength, 0)
            let spanStart = min(pair.first.startFrame, pair.second.startFrame)
            let spanEnd = max(pair.first.startFrame + AVAudioFramePosition(pair.first.frameLength), pair.second.startFrame + AVAudioFramePosition(pair.second.frameLength))
            XCTAssertGreaterThanOrEqual(spanEnd, spanStart)
        }

        XCTAssertEqual(pairGrid.idle.count, profile.idleBeatRange.count / 2)
        XCTAssertLessThan(pairGrid.tracking.count, pairGrid.idle.count + pairGrid.tracking.count + 1)
    }

    func testStableProximityToPairMapping() {
        let profile = MotionTrackerAudioProfile()
        let pairCount = 20

        func mapPair(_ proximity: Double) -> Int {
            let clamped = max(0.0, min(1.0, proximity))
            let requested = pairCount > 1 ? Int(round(clamped * Double(pairCount - 1))) : 0
            return profile.clampPairIndex(requested, pairCount: pairCount)
        }

        let p20 = mapPair(0.2)
        let p40 = mapPair(0.4)
        let p60 = mapPair(0.6)
        let p80 = mapPair(0.8)

        XCTAssertLessThanOrEqual(p20, p40)
        XCTAssertLessThanOrEqual(p40, p60)
        XCTAssertLessThanOrEqual(p60, p80)

        XCTAssertEqual(mapPair(0.45), mapPair(0.45))
        XCTAssertEqual(mapPair(0.47), mapPair(0.47))
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

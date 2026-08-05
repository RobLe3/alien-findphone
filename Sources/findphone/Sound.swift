import Foundation
import AVFoundation
import AudioToolbox

/// Distance/location feedback driven by short, irregular audio atoms.
///
/// The focused asset controls atom timing, tone and tone-shaping. We avoid
/// continuous loops and instead replay short segments from the track with variation
/// for each update.
final class Clicker {
    private struct SoundProfile {
        let interval: TimeInterval
        let pitch: Float
        let rate: Float
        let pan: Float
        let reverb: Float
        let volume: Float
    }

    private let distant = -95.0
    private let segmentCount = 5
    private let atomDuration: TimeInterval = 0.12

    private var player: AVAudioPlayerNode?
    private var pitchUnit: AVAudioUnitTimePitch?
    private var reverbUnit: AVAudioUnitReverb?
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?

    private var timer: Timer?
    private var currentBand: Int?
    private var token = 0
    private var lastSources: Set<SignalSource> = []
    private var lastInterval: TimeInterval = 0
    private var latestConfidence: Double = 0
    private var latestEstimate: TriangulationEstimate?

    private var fallback: SystemSoundID = 0
    private var fallbackAvailable = false

    init?(path: String = "/System/Library/Sounds/Tink.aiff") {
        if FileManager.default.fileExists(atPath: path), setupAudioEngine(filePath: path) {
            return
        }

        guard FileManager.default.fileExists(atPath: "/System/Library/Sounds/Tink.aiff"),
              AudioServicesCreateSystemSoundID(
                  URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff") as CFURL,
                  &fallback) == kAudioServicesNoError
        else {
            return nil
        }
        fallbackAvailable = true
    }

    deinit {
        timer?.invalidate()
        timer = nil
        player?.stop()
        if let engine { engine.stop() }
        player = nil
        pitchUnit = nil
        reverbUnit = nil
        engine = nil
        if fallback != 0 {
            AudioServicesDisposeSystemSoundID(fallback)
        }
    }

    private func setupAudioEngine(filePath: String) -> Bool {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: URL(fileURLWithPath: filePath))
        } catch {
            return false
        }

        let format = file.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        let reverb = AVAudioUnitReverb()

        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 12
        pitch.overlap = 8
        pitch.pitch = 0
        pitch.rate = 1

        engine.attach(player)
        engine.attach(pitch)
        engine.attach(reverb)

        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            return false
        }

        player.play()

        self.player = player
        self.pitchUnit = pitch
        self.reverbUnit = reverb
        self.engine = engine
        self.audioFile = file
        return true
    }

    func start() {
        // Audio starts on first valid asset signal.
    }

    /// Update atom scheduler from the focused signal state.
    func update(rssi: Int?, sources: Set<SignalSource> = [], confidence: Double = 0, estimate: TriangulationEstimate? = nil) {
        guard let rawRSSI = rssi else {
            stop()
            return
        }

        let band = bandIndex(for: rawRSSI)
        latestConfidence = confidence
        latestEstimate = estimate
        let changedBand = currentBand != band
        let changedSources = sources != lastSources
        currentBand = band

        let profile = profile(for: band, sources: sources, confidence: confidence)
        lastSources = sources

        applyProfile(profile)

        if changedBand || changedSources {
            token += 1
            scheduleAtomLoop(interval: profile.interval)
        } else if timer == nil || abs(lastInterval - profile.interval) > 0.05 {
            scheduleAtomLoop(interval: profile.interval)
        }

        _ = changedBand
    }

    private func scheduleAtomLoop(interval: TimeInterval) {
        guard currentBand != nil else { return }
        timer?.invalidate()
        let current = token
        let jittered = jitter(interval)
        lastInterval = jittered
        timer = Timer.scheduledTimer(withTimeInterval: jittered, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.currentBand != nil else { return }
            guard self.token == current else { return }

            self.emitAtom()
            self.scheduleAtomLoop(interval: self.currentInterval())
        }
    }

    private func emitAtom() {
        guard let player = player else {
            emitFallbackAtom()
            return
        }

        guard let file = audioFile else {
            emitFallbackAtom()
            return
        }

        guard let band = currentBand,
              let profile = currentProfile() else {
            emitFallbackAtom()
            return
        }

        if player.isPlaying {
            player.stop()
        }

        guard let segment = segmentRange(for: band, fileLength: file.length) else {
            emitFallbackAtom()
            return
        }

        let start = AVAudioFramePosition(segment.start)
        let length = AVAudioFrameCount(segment.count)

        player.scheduleSegment(file, startingFrame: start, frameCount: length, at: nil)
        player.volume = profile.volume
        player.pan = profile.pan
        player.play()
        pitchUnit?.pitch = profile.pitch
        pitchUnit?.rate = profile.rate
        reverbUnit?.wetDryMix = profile.reverb
    }

    private func emitFallbackAtom() {
        guard fallbackAvailable else { return }
        AudioServicesPlaySystemSound(fallback)
    }

    private func profile(for band: Int, sources: Set<SignalSource>, confidence: Double) -> SoundProfile {
        let base = baseProfile(for: band)
        let sourceProfile = sourceProfileModifier(for: sources)
        let conf = max(0.0, min(1.0, confidence))
        let confidenceMod = 0.08 + 0.75 * conf
        let confidenceInterval = base.interval * (0.8 + (1.0 - conf) * 0.7)
        var pan = base.pan + sourceProfile.pan
        if let estimate = latestEstimate {
            if estimate.sources % 2 == 0 { pan += 0.12 }
            if estimate.confidence > 0.7 { pan *= 1.12 }
        }
        return SoundProfile(
            interval: confidenceInterval,
            pitch: base.pitch + sourceProfile.pitch,
            rate: base.rate * sourceProfile.rate,
            pan: max(-1.0, min(1.0, pan)),
            reverb: min(60, base.reverb + sourceProfile.reverb),
            volume: Float(max(0.08, min(0.95, Double(base.volume) + Double(sourceProfile.volume) + confidenceMod * 0.08)))
        )
    }

    private func currentProfile() -> SoundProfile? {
        guard let band = currentBand else { return nil }
        let base = baseProfile(for: band)
        let sourceProfile = sourceProfileModifier(for: lastSources)
        let conf = max(0.0, min(1.0, latestConfidence))
        let confidenceMod = 0.08 + 0.75 * conf

        var pan = base.pan + sourceProfile.pan
        if let estimate = latestEstimate {
            if estimate.sources % 2 == 0 { pan += 0.12 }
            if estimate.confidence > 0.7 { pan *= 1.12 }
        }

        return SoundProfile(
            interval: base.interval * (0.8 + (1 - conf) * 0.7),
            pitch: base.pitch + sourceProfile.pitch,
            rate: base.rate * sourceProfile.rate,
            pan: max(-1.0, min(1.0, pan)),
            reverb: min(60, base.reverb + sourceProfile.reverb),
            volume: Float(max(0.08, min(0.95, Double(base.volume + sourceProfile.volume) + confidenceMod * 0.08)))
        )
    }

    private func applyProfile(_ profile: SoundProfile) {
        pitchUnit?.pitch = profile.pitch
        pitchUnit?.rate = profile.rate
        reverbUnit?.wetDryMix = profile.reverb
        player?.pan = profile.pan
        player?.volume = profile.volume
    }

    private func currentInterval() -> TimeInterval {
        guard let band = currentBand else { return 1.0 }
        guard let profile = currentProfile() else {
            return baseProfile(for: band).interval
        }
        return profile.interval
    }

    private func baseProfile(for band: Int) -> SoundProfile {
        switch band {
        case 0:
            return SoundProfile(interval: 1.1, pitch: -240, rate: 0.58, pan: -0.2, reverb: 10, volume: 0.06)
        case 1:
            return SoundProfile(interval: 0.66, pitch: -155, rate: 0.78, pan: -0.1, reverb: 14, volume: 0.12)
        case 2:
            return SoundProfile(interval: 0.38, pitch: -45, rate: 0.96, pan: 0.04, reverb: 18, volume: 0.17)
        case 3:
            return SoundProfile(interval: 0.23, pitch: 42, rate: 1.09, pan: 0.13, reverb: 23, volume: 0.22)
        default:
            return SoundProfile(interval: 0.11, pitch: 132, rate: 1.26, pan: 0.2, reverb: 30, volume: 0.3)
        }
    }

    private func sourceProfileModifier(for sources: Set<SignalSource>) -> SoundProfile {
        var pitch: Float = 0
        var rate: Float = 1
        var pan: Float = 0
        var reverb: Float = 0
        var volume: Float = 0
        if sources.contains(.wifi) {
            pitch += 42
            rate *= 1.08
            pan -= 0.22
            reverb += 4
            volume += 0.03
        }
        if sources.contains(.bleAdvert) {
            pan -= 0.05
            volume += 0.01
        }
        if sources.contains(.bleLink) {
            pitch -= 24
            rate *= 1.04
            pan += 0.16
            reverb += 2
            volume += 0.02
        }
        if sources.contains(.classic) {
            pitch += 15
            pan += 0.09
            rate *= 1.01
            volume += 0.01
        }
        if sources.contains(.anchor) {
            rate *= 0.96
            reverb += 3
            pan += 0.03
        }
        return SoundProfile(interval: 0, pitch: pitch, rate: rate, pan: pan, reverb: reverb, volume: volume)
    }

    private func segmentRange(for band: Int, fileLength: AVAudioFramePosition) -> (start: Int64, count: Int64)? {
        let sampleRate = audioFile?.processingFormat.sampleRate ?? 44_100
        let segmentFrames = max(1, fileLength / AVAudioFramePosition(segmentCount))
        let index = max(0, min(segmentCount - 1, band))
        let bandStart = segmentFrames * AVAudioFramePosition(index)
        let bandEnd = min(fileLength, bandStart + segmentFrames)

        let atomFrames = max(1, Int64(atomDuration * sampleRate))
        guard bandEnd > bandStart + atomFrames else {
            return (Int64(bandStart), Int64(max(1, bandEnd - bandStart)))
        }

        let offsetMax = max(0, Int64((bandEnd - bandStart) - atomFrames))
        let offset = Int64.random(in: 0...offsetMax)

        return (Int64(bandStart + offset), atomFrames)
    }

    private func bandIndex(for rssi: Int) -> Int {
        if rssi <= Int(distant) { return 0 }
        if rssi <= -85 { return 1 }
        if rssi <= -75 { return 2 }
        if rssi <= -65 { return 3 }
        return 4
    }

    private func jitter(_ interval: TimeInterval) -> TimeInterval {
        let jitter = Double.random(in: 0.8...1.2)
        return max(0.06, interval * jitter)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        token += 1
        currentBand = nil
        latestConfidence = 0
        latestEstimate = nil
        lastSources.removeAll()
        player?.stop()
    }
}

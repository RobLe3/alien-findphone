import Foundation
import AVFoundation
import AudioToolbox

/// Distance/location feedback driven by short, irregular atoms extracted from the
/// detector pack. The approach keeps timing and timing variance in code and keeps
/// pitch mostly from the source atoms so it still sounds like the original asset.
final class Clicker {
    private struct SoundProfile {
        let interval: TimeInterval
        let pitch: Float
        let rate: Float
        let pan: Float
        let reverb: Float
        let volume: Float
    }

    private struct AtomWindow {
        let start: AVAudioFramePosition
        let count: AVAudioFrameCount
        let energy: Float
        let pitchHz: Float
    }

    private enum PitchBand: Int, CaseIterable {
        case low = 0
        case mid = 1
        case high = 2
    }

    private let distant = -95.0

    private var player: AVAudioPlayerNode?
    private var pitchUnit: AVAudioUnitTimePitch?
    private var reverbUnit: AVAudioUnitReverb?
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?

    private var atomWindows: [AtomWindow] = []
    private var atomByBand: [PitchBand: [AtomWindow]] = [:]

    private var timer: Timer?
    private var currentBand: Int?
    private var token = 0
    private var lastSources: Set<SignalSource> = []
    private var lastInterval: TimeInterval = 0

    private var latestConfidence: Double = 0
    private var latestEstimate: TriangulationEstimate?
    private var latestSpectrum: [SignalSource: Int] = [:]

    private var fallback: SystemSoundID = 0
    private var fallbackAvailable = false

    private let minPitchHz: Float = 700
    private let maxPitchHz: Float = 3400

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
        if let engine {
            engine.stop()
        }
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

        reverb.loadFactoryPreset(.smallRoom)
        reverb.wetDryMix = 9
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
        let discovered = discoverAtoms(in: file, sampleRate: format.sampleRate)

        self.player = player
        self.pitchUnit = pitch
        self.reverbUnit = reverb
        self.engine = engine
        self.audioFile = file
        self.atomWindows = discovered
        self.atomByBand = buildAtomByBand(discovered)
        return true
    }

    func start() {
        // Sound is triggered by valid focus data.
    }

    /// Update atom scheduler from the focused signal state.
    func update(
        rssi: Int?,
        sources: Set<SignalSource> = [],
        spectrum: [SignalSource: Int] = [:],
        confidence: Double = 0,
        estimate: TriangulationEstimate? = nil
    ) {
        guard let rawRSSI = rssi else {
            stop()
            return
        }

        let band = bandIndex(for: rawRSSI)
        let previousSpectrum = latestSpectrum

        let changedBand = currentBand != band
        let changedSources = sources != lastSources
        let changedSpectrum = previousSpectrum != spectrum

        latestConfidence = confidence
        latestEstimate = estimate
        latestSpectrum = spectrum
        lastSources = sources
        currentBand = band

        let profile = profile(for: band, sources: sources, spectrum: spectrum, confidence: confidence)

        applyProfile(profile)

        if changedBand || changedSources || changedSpectrum {
            token += 1
            scheduleAtomLoop(interval: profile.interval)
        } else if timer == nil || abs(lastInterval - profile.interval) > 0.05 {
            scheduleAtomLoop(interval: profile.interval)
        }
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
        guard let band = currentBand, let profile = currentProfile() else {
            emitFallbackAtom()
            return
        }

        if player.isPlaying {
            player.stop()
        }

        guard let atom = atomWindow(for: band, spectrum: latestSpectrum) else {
            emitFallbackAtom()
            return
        }

        let start = atom.start
        let length = atom.count
        if length == 0 || start >= file.length {
            emitFallbackAtom()
            return
        }

        let cappedLength = max(1, min(length, AVAudioFrameCount(file.length - start)))
        player.scheduleSegment(file, startingFrame: start, frameCount: cappedLength, at: nil)
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

    private func profile(
        for band: Int,
        sources: Set<SignalSource>,
        spectrum: [SignalSource: Int],
        confidence: Double
    ) -> SoundProfile {
        let base = baseProfile(for: band)
        let sourceProfile = sourceProfileModifier(for: sources)
        let spectrumProfile = spectrumProfileModifier(for: spectrum)

        let conf = max(0.0, min(1.0, confidence))

        let confidenceInterval = base.interval * (1.0 - (conf * 0.25) + (1.0 - conf) * 0.16)
        let confidenceGain = 0.05 + (0.65 * conf)

        var pan = base.pan + sourceProfile.pan + spectrumProfile.pan
        if let estimate = latestEstimate {
            if estimate.sources % 2 == 1 {
                pan -= 0.03
            } else {
                pan += 0.03
            }
            if estimate.confidence > 0.65 {
                pan *= 1.06
            }
        }

        let pitch = base.pitch + sourceProfile.pitch + spectrumProfile.pitch
        let rate = max(0.72, min(1.45, base.rate * sourceProfile.rate * spectrumProfile.rate))

        let interval = max(0.12, confidenceInterval)
        let stablePan = max(-1.0, min(1.0, pan))
        let stableReverb = min(20, base.reverb + sourceProfile.reverb + spectrumProfile.reverb)
        let baseGain = base.volume + sourceProfile.volume + spectrumProfile.volume + Float(confidenceGain * 0.08)
        let stableVolume = Float(max(0.05, min(0.9, Double(baseGain))))

        return SoundProfile(
            interval: interval,
            pitch: pitch,
            rate: rate,
            pan: stablePan,
            reverb: stableReverb,
            volume: stableVolume
        )
    }

    private func currentProfile() -> SoundProfile? {
        guard let band = currentBand else { return nil }
        return profile(
            for: band,
            sources: lastSources,
            spectrum: latestSpectrum,
            confidence: latestConfidence
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
            return SoundProfile(interval: 1.05, pitch: -6, rate: 0.90, pan: -0.13, reverb: 6, volume: 0.08)
        case 1:
            return SoundProfile(interval: 0.74, pitch: -2, rate: 0.94, pan: -0.06, reverb: 7, volume: 0.12)
        case 2:
            return SoundProfile(interval: 0.48, pitch: 0, rate: 1.0, pan: 0.01, reverb: 9, volume: 0.17)
        case 3:
            return SoundProfile(interval: 0.30, pitch: 4, rate: 1.02, pan: 0.08, reverb: 10, volume: 0.20)
        default:
            return SoundProfile(interval: 0.16, pitch: 8, rate: 1.06, pan: 0.12, reverb: 12, volume: 0.24)
        }
    }

    private func sourceProfileModifier(for sources: Set<SignalSource>) -> SoundProfile {
        var pitch: Float = 0
        var rate: Float = 1
        var pan: Float = 0
        var reverb: Float = 0
        var volume: Float = 0

        if sources.contains(.wifi) {
            pitch += 2
            rate *= 1.04
            pan -= 0.05
            reverb += 1
            volume += 0.01
        }

        if sources.contains(.bleAdvert) {
            pan += 0.01
            volume += 0.01
        }

        if sources.contains(.bleLink) {
            pitch -= 1
            rate *= 1.02
            pan += 0.05
            volume += 0.01
        }

        if sources.contains(.classic) {
            pitch += 2
            pan += 0.03
            rate *= 1.01
            reverb += 1
            volume += 0.01
        }

        if sources.contains(.anchor) {
            rate *= 0.99
            pan += 0.04
            reverb += 1
            volume += 0.01
        }

        return SoundProfile(interval: 0, pitch: pitch, rate: rate, pan: pan, reverb: reverb, volume: volume)
    }

    private func spectrumProfileModifier(for spectrum: [SignalSource: Int]) -> SoundProfile {
        let total = spectrum.values.reduce(0, +)
        let distinct = spectrum.count
        let weighted = max(0.0, min(1.0, Double(total) / 25.0))
        let diversity = max(0.0, min(1.0, Double(distinct) / 6.0))

        let pan = Float((diversity - 0.5) * 0.1)
        let reverb = Float(weighted * 2.2)
        let pitch = Float(weighted * 4.0)
        let rate = Float(0.98 + (weighted * 0.09))

        var volume: Float = 0
        if total > 12 {
            volume = 0.01
        }

        return SoundProfile(interval: 0, pitch: pitch, rate: rate, pan: pan, reverb: reverb, volume: volume)
    }

    private func atomWindow(for band: Int, spectrum: [SignalSource: Int]) -> AtomWindow? {
        let windows: [AtomWindow]
        if atomWindows.isEmpty {
            windows = fallbackAtoms(fileLength: audioFile?.length ?? 0)
            if windows.isEmpty { return nil }
            return windows.randomElement()
        }

        let baseBand = preferredPitchBand(for: band)
        let spectrumBand = preferredPitchBand(for: spectrum)

        let chooseSpectrum = band == 0 || band == 4 ? 0.20 : 0.30
        let preferredBand: PitchBand = Double.random(in: 0.0...1.0) < chooseSpectrum ? spectrumBand : baseBand

        let candidateBands: [PitchBand] = {
            if preferredBand == baseBand {
                return [preferredBand]
            }
            return [preferredBand, baseBand]
        }()

        for bandChoice in candidateBands {
            if let bucket = atomByBand[bandChoice], let picked = pickAtom(from: bucket, by: band) {
                return picked
            }
        }

        return pickAtom(from: atomWindows, by: band)
    }

    private func preferredPitchBand(for band: Int) -> PitchBand {
        switch band {
        case 0, 1: return .low
        case 2: return .mid
        default: return .high
        }
    }

    private func preferredPitchBand(for spectrum: [SignalSource: Int]) -> PitchBand {
        guard !spectrum.isEmpty else { return .mid }
        guard let dominant = spectrum.max(by: { (lhs, rhs) -> Bool in
            if lhs.value == rhs.value {
                return lhs.key.rawValue < rhs.key.rawValue
            }
            return lhs.value < rhs.value
        }) else { return .mid }

        switch dominant.key {
        case .wifi, .anchor:
            return .high
        case .bleLink:
            return .mid
        case .bleAdvert:
            return .low
        case .classic:
            return .mid
        }
    }

    private func pickAtom(from windows: [AtomWindow], by band: Int) -> AtomWindow? {
        guard !windows.isEmpty else { return nil }
        let sorted = windows.sorted { $0.start < $1.start }

        let count = sorted.count
        let bandFactor = max(0.0, min(1.0, Double(band) / 4.0))
        let center = Int(Double(count - 1) * bandFactor)
        let spread = max(1, min(4, count / 4))
        let from = max(0, center - spread)
        let to = min(count - 1, center + spread)

        return sorted[Int.random(in: from...to)]
    }

    private func buildAtomByBand(_ windows: [AtomWindow]) -> [PitchBand: [AtomWindow]] {
        let validPitch = windows.filter { $0.pitchHz > 0 }
        guard !validPitch.isEmpty else {
            return [
                .low: windows,
                .mid: windows,
                .high: windows,
            ]
        }

        let sorted = validPitch.sorted { $0.pitchHz < $1.pitchHz }
        let lowIndex = sorted.count / 3
        let highIndex = max(lowIndex, (sorted.count * 2) / 3)

        let lowThreshold = sorted[min(lowIndex, sorted.count - 1)].pitchHz
        let highThreshold = sorted[min(highIndex, sorted.count - 1)].pitchHz

        var byBand: [PitchBand: [AtomWindow]] = [.low: [], .mid: [], .high: []]
        for window in windows {
            if window.pitchHz <= 0 {
                byBand[.mid, default: []].append(window)
                continue
            }

            let bucket: PitchBand
            if window.pitchHz <= lowThreshold {
                bucket = .low
            } else if window.pitchHz >= highThreshold {
                bucket = .high
            } else {
                bucket = .mid
            }
            byBand[bucket, default: []].append(window)
        }

        for band in PitchBand.allCases {
            if byBand[band]?.isEmpty == true {
                byBand[band] = windows
            }
        }

        return byBand
    }

    private func discoverAtoms(in file: AVAudioFile, sampleRate: Double) -> [AtomWindow] {
        guard let samples = readMonoSamples(from: file) else {
            return fallbackAtoms(fileLength: file.length)
        }
        guard !samples.isEmpty else {
            return fallbackAtoms(fileLength: file.length)
        }

        let maxPeak = samples.max() ?? 0
        guard maxPeak > 0.0001 else {
            return fallbackAtoms(fileLength: file.length)
        }

        let threshold = maxPeak * 0.18
        let minFrames = max(256, Int(sampleRate * 0.016))
        let leadTail = Int(sampleRate * 0.008)

        var candidates: [AtomWindow] = []
        var i = 0
        var start = -1

        while i < samples.count {
            if samples[i] > threshold {
                if start < 0 { start = i }
            } else if start >= 0 {
                let end = i
                if end - start >= minFrames {
                    let windowStart = max(0, start - leadTail)
                    let windowEnd = min(samples.count, end + leadTail)
                    let clampedLength = max(1, windowEnd - windowStart)
                    let energy = rms(samples, from: windowStart, to: windowEnd)
                    let pitch = estimatePitchHz(samples: samples,
                                               sampleRate: sampleRate,
                                               start: windowStart,
                                               end: windowEnd)
                    candidates.append(AtomWindow(
                        start: AVAudioFramePosition(windowStart),
                        count: AVAudioFrameCount(clampedLength),
                        energy: energy,
                        pitchHz: pitch
                    ))
                }
                start = -1
            }
            i += 1
        }

        if start >= 0 {
            let end = samples.count
            if end - start >= minFrames {
                let windowStart = max(0, start - leadTail)
                let windowEnd = end
                let clampedLength = max(1, windowEnd - windowStart)
                let energy = rms(samples, from: windowStart, to: windowEnd)
                let pitch = estimatePitchHz(samples: samples,
                                           sampleRate: sampleRate,
                                           start: windowStart,
                                           end: windowEnd)
                candidates.append(AtomWindow(
                    start: AVAudioFramePosition(windowStart),
                    count: AVAudioFrameCount(clampedLength),
                    energy: energy,
                    pitchHz: pitch
                ))
            }
        }

        let sorted = candidates
            .sorted {
                if $0.energy == $1.energy {
                    return $0.count > $1.count
                }
                return $0.energy > $1.energy
            }
            .prefix(24)

        let picks = Array(sorted).sorted { $0.start < $1.start }
        guard !picks.isEmpty else {
            return fallbackAtoms(fileLength: file.length)
        }

        return picks
    }

    private func readMonoSamples(from file: AVAudioFile) -> [Float]? {
        file.framePosition = 0
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: totalFrames) else {
            return nil
        }

        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }

        let length = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else { return nil }
        let channels = Int(file.processingFormat.channelCount)

        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            var sum: Float = 0
            for ch in 0..<channels {
                sum += abs(data[ch][i])
            }
            out[i] = sum / Float(channels)
        }

        return out
    }

    private func rms(_ samples: [Float], from start: Int, to end: Int) -> Float {
        guard start < end, end <= samples.count, start >= 0 else { return 0 }
        var acc: Float = 0
        for i in start..<end {
            let v = samples[i]
            acc += v * v
        }
        let mean = acc / Float(end - start)
        return sqrt(max(0.0, mean))
    }

    private func estimatePitchHz(samples: [Float], sampleRate: Double, start: Int, end: Int) -> Float {
        guard end > start + 256 else { return 0 }
        let clipStart = max(0, start)
        let clipEnd = min(samples.count, end)
        guard clipEnd > clipStart + 256 else { return 0 }

        var segment = Array(samples[clipStart..<clipEnd])
        let trim = max(0, segment.count / 12)
        if trim * 3 < segment.count {
            segment.removeFirst(trim)
            segment.removeLast(trim)
        }

        let count = segment.count
        let mean = segment.reduce(0, +) / Float(count)
        for i in 0..<count {
            segment[i] -= mean
        }

        let minLag = max(1, Int(sampleRate / Double(maxPitchHz)))
        let maxLag = min(Int(sampleRate / Double(minPitchHz)), max(1, count / 2))
        guard maxLag > minLag else { return 0 }

        var bestLag = 0
        var bestScore: Float = 0

        for lag in stride(from: minLag, through: maxLag, by: 1) {
            var score: Float = 0
            let maxI = count - lag
            for i in 0..<maxI {
                score += segment[i] * segment[i + lag]
            }
            score /= Float(maxI)
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }

        guard bestLag > 0 else { return 0 }
        let pitch = Float(sampleRate / Double(bestLag))
        guard pitch >= minPitchHz && pitch <= maxPitchHz else { return 0 }
        return pitch
    }

    private func fallbackAtoms(fileLength: AVAudioFramePosition) -> [AtomWindow] {
        guard fileLength >= 8_000 else { return [] }
        let frameDuration: AVAudioFramePosition = 2_800
        let step = max(1, fileLength / 5)

        return (0..<5).compactMap { idx -> AtomWindow? in
            let start = AVAudioFramePosition(idx) * step
            let end = min(fileLength, start + frameDuration)
            guard end > start else { return nil }
            return AtomWindow(start: start, count: AVAudioFrameCount(end - start), energy: 1, pitchHz: 0)
        }
    }

    private func bandIndex(for rssi: Int) -> Int {
        if rssi <= Int(distant) { return 0 }
        if rssi <= -85 { return 1 }
        if rssi <= -75 { return 2 }
        if rssi <= -65 { return 3 }
        return 4
    }

    private func jitter(_ interval: TimeInterval) -> TimeInterval {
        let jitter = Double.random(in: 0.90...1.15)
        return max(0.09, interval * jitter)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        token += 1
        currentBand = nil
        latestConfidence = 0
        latestEstimate = nil
        latestSpectrum.removeAll()
        lastSources.removeAll()
        player?.stop()
    }
}

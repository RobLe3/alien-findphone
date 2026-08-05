import Foundation
import AVFoundation
import AudioToolbox

/// Distance/location feedback driven by short atoms extracted from the detector pack.
/// The focus is on preserving the original pack tone while introducing
/// deterministic motion (survey → hunt → lock) and spectrum-aware selection.
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
        let duration: TimeInterval
        let toneClass: ToneClass
        let rms: Float
    }

    private enum ToneClass: Int, CaseIterable {
        case short = 0
        case mid = 1
        case long = 2
    }

    private enum TrackerMode: Int, CaseIterable {
        case survey = 0
        case track = 1
        case lock = 2
        case anchor = 3
        case fallback = 4

        var id: Int { rawValue }
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
    private var atomByMode: [TrackerMode: [AtomWindow]] = [:]

    private var cursorByMode: [Int: Int] = [:]

    private var timer: Timer?
    private var currentMode: TrackerMode?
    private var latestRssiBand = 2
    private var token = 0
    private var lastSources: Set<SignalSource> = []
    private var lastInterval: TimeInterval = 0
    private var latestConfidence: Double = 0
    private var latestEstimate: TriangulationEstimate?
    private var latestSpectrum: [SignalSource: Int] = [:]
    private var latestSector = 0

    private var fallback: SystemSoundID = 0
    private var fallbackAvailable = false

    private let minPitchHz: Float = 650
    private let maxPitchHz: Float = 3200

    init?(path: String = "/System/Library/Sounds/Tink.aiff") {
        if FileManager.default.fileExists(atPath: path), setupAudioEngine(filePath: path) {
            return
        }

        guard FileManager.default.fileExists(atPath: "/System/Library/Sounds/Tink.aiff"),
              AudioServicesCreateSystemSoundID(
                  URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff") as CFURL,
                  &fallback
              ) == kAudioServicesNoError
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
        reverb.wetDryMix = 6
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
        self.atomByMode = buildAtomByMode(discovered)
        return true
    }

    func start() {
        // Sound is now driven by focus updates.
    }

    /// Update atom scheduler from the focused signal state.
    func update(
        rssi: Int?,
        sources: Set<SignalSource> = [],
        spectrum: [SignalSource: Int] = [:],
        confidence: Double = 0,
        estimate: TriangulationEstimate? = nil,
        focusIdentity: String? = nil
    ) {
        guard let rawRSSI = rssi else {
            stop()
            return
        }

        let band = bandIndex(for: rawRSSI)
        let mode = mode(for: band, confidence: confidence, sources: sources, spectrum: spectrum)
        let previousMode = currentMode
        let previousSpectrum = latestSpectrum

        let changedMode = previousMode != mode
        let changedSources = lastSources != sources
        let changedSpectrum = previousSpectrum != spectrum

        latestConfidence = confidence
        latestEstimate = estimate
        latestSpectrum = spectrum
        latestSector = sectorIndex(for: focusIdentity)
        latestRssiBand = band
        lastSources = sources
        currentMode = mode

        let profile = profile(for: mode, band: band, sources: sources, spectrum: spectrum, confidence: confidence)
        applyProfile(profile)

        if changedMode || changedSources || changedSpectrum {
            token += 1
            scheduleAtomLoop(interval: profile.interval)
        } else if timer == nil || abs(lastInterval - profile.interval) > 0.06 {
            scheduleAtomLoop(interval: profile.interval)
        }
    }

    private func scheduleAtomLoop(interval: TimeInterval) {
        guard currentMode != nil else { return }
        timer?.invalidate()

        let current = token
        let jittered = jitter(interval)
        lastInterval = jittered

        timer = Timer.scheduledTimer(withTimeInterval: jittered, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.currentMode != nil else { return }
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
        guard let mode = currentMode, let profile = currentProfile() else {
            emitFallbackAtom()
            return
        }

        if player.isPlaying {
            player.stop()
        }

        guard let atom = atomWindow(for: mode, band: latestRssiBand, spectrum: latestSpectrum) else {
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

        pitchUnit?.pitch = profile.pitch
        pitchUnit?.rate = profile.rate
        reverbUnit?.wetDryMix = profile.reverb
        player.play()

        if mode == .lock, Bool.random(), Bool.random() {
            emitDoubleTick(after: 0.06)
        }
    }

    private func emitDoubleTick(after delay: TimeInterval) {
        guard player != nil, let file = audioFile else { return }
        guard let mode = currentMode else { return }

        let next = timerMode(for: mode)
        guard let atom = atomWindow(for: next, band: latestRssiBand, spectrum: latestSpectrum) else { return }
        let length = max(1, min(atom.count, AVAudioFrameCount(file.length - atom.start)))

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.currentMode == mode else { return }
            let profile = self.currentProfile()
            self.player?.scheduleSegment(file, startingFrame: atom.start, frameCount: length, at: nil)
            if let profile {
                self.player?.pan = profile.pan
                self.player?.volume = max(0, profile.volume - 0.04)
            }
            self.player?.play()
        }
    }

    private func timerMode(for mode: TrackerMode) -> TrackerMode {
        switch mode {
        case .lock: return .lock
        case .track: return Bool.random() ? .lock : .track
        case .survey: return .track
        case .anchor: return .anchor
        case .fallback: return .track
        }
    }

    private func emitFallbackAtom() {
        guard fallbackAvailable else { return }
        AudioServicesPlaySystemSound(fallback)
    }

    private func profile(
        for mode: TrackerMode,
        band: Int,
        sources: Set<SignalSource>,
        spectrum: [SignalSource: Int],
        confidence: Double
    ) -> SoundProfile {
        let base = baseProfile(for: mode)
        let sourceProfile = sourceProfileModifier(for: sources)
        let spectrumProfile = spectrumProfileModifier(for: spectrum)

        let conf = max(0.0, min(1.0, confidence))

        var interval = base.interval
        interval = interval * (0.90 - conf * 0.24 + (1.0 - conf) * 0.20)
        interval = interval * (1.0 + Double(max(0, band - 2)) * 0.12)

        let confidenceGain = 0.05 + (0.55 * conf)
        let sectorPan = sectorPan(distance: latestDistanceEstimate(), identity: nil)

        let pitch = base.pitch + sourceProfile.pitch + spectrumProfile.pitch
        let rate = max(0.85, min(1.12, base.rate * sourceProfile.rate * spectrumProfile.rate))
        let pan = max(-1.0, min(1.0, base.pan + sourceProfile.pan + spectrumProfile.pan + sectorPan))
        let reverb = max(0.0, min(20.0, base.reverb + sourceProfile.reverb + spectrumProfile.reverb))
        let volume = Float(max(0.06, min(0.9, Double(base.volume) + Double(sourceProfile.volume) + Double(spectrumProfile.volume) + confidenceGain * 0.08)))

        return SoundProfile(
            interval: interval,
            pitch: pitch,
            rate: rate,
            pan: pan,
            reverb: reverb,
            volume: volume
        )
    }

    private func currentProfile() -> SoundProfile? {
        guard let mode = currentMode else { return nil }
        return profile(
            for: mode,
            band: latestRssiBand,
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
        guard let mode = currentMode else { return 1.0 }
        guard let profile = currentProfile() else {
            return baseProfile(for: mode).interval
        }
        return profile.interval
    }

    private func baseProfile(for mode: TrackerMode) -> SoundProfile {
        switch mode {
        case .survey:
            return SoundProfile(interval: 1.05, pitch: 0, rate: 1.0, pan: -0.10, reverb: 4, volume: 0.09)
        case .track:
            return SoundProfile(interval: 0.58, pitch: 1, rate: 1.0, pan: 0.00, reverb: 7, volume: 0.14)
        case .lock:
            return SoundProfile(interval: 0.33, pitch: 2, rate: 1.01, pan: 0.04, reverb: 10, volume: 0.20)
        case .anchor:
            return SoundProfile(interval: 0.42, pitch: 3, rate: 1.00, pan: -0.02, reverb: 9, volume: 0.17)
        case .fallback:
            return SoundProfile(interval: 0.75, pitch: 0, rate: 1.0, pan: 0.0, reverb: 6, volume: 0.12)
        }
    }

    private func sourceProfileModifier(for sources: Set<SignalSource>) -> SoundProfile {
        var pitch: Float = 0
        var rate: Float = 1
        var pan: Float = 0
        var reverb: Float = 0
        var volume: Float = 0

        if sources.contains(.wifi) {
            pitch += 1
            rate *= 1.02
            pan -= 0.04
            reverb += 0.5
            volume += 0.01
        }

        if sources.contains(.bleAdvert) {
            pan += 0.01
            volume += 0.008
        }

        if sources.contains(.bleLink) {
            pan += 0.03
            volume += 0.009
        }

        if sources.contains(.classic) {
            pitch += 1
            pan += 0.03
            reverb += 0.4
            volume += 0.01
        }

        if sources.contains(.anchor) {
            pitch += 1
            pan -= 0.02
            reverb += 0.6
            volume += 0.01
        }

        return SoundProfile(interval: 0, pitch: pitch, rate: rate, pan: pan, reverb: reverb, volume: volume)
    }

    private func spectrumProfileModifier(for spectrum: [SignalSource: Int]) -> SoundProfile {
        let total = spectrum.values.reduce(0, +)
        let distinct = spectrum.count
        let weighted = max(0.0, min(1.0, Double(total) / 24.0))
        let diversity = max(0.0, min(1.0, Double(distinct) / 6.0))

        let pan = Float((weighted - 0.5) * 0.08)
        let reverb = Float(diversity * 1.8 + weighted * 1.2)
        let pitch = Float(weighted * 1.8 + diversity * 1.2)
        let rate = Float(0.99 + (weighted * 0.05) + (diversity * 0.02))

        let volume: Float
        if total > 14 {
            volume = 0.01
        } else if total > 8 {
            volume = 0.006
        } else {
            volume = 0
        }

        return SoundProfile(interval: 0, pitch: pitch, rate: rate, pan: pan, reverb: reverb, volume: volume)
    }

    private func sectorIndex(for identity: String?) -> Int {
        guard let identity else { return 0 }
        return abs(identity.utf8.reduce(0, { $0 + Int($1) })) % 8
    }

    private func sectorPan(distance: Double, identity: String?) -> Float {
        _ = distance
        let index = latestSector
        return Float((Double(index) / 8.0) - 0.5) * 0.55
    }

    private func latestDistanceEstimate() -> Double {
        guard let conf = latestEstimate else { return 15 }
        let x = sqrt(conf.x * conf.x + conf.y * conf.y)
        return max(0.0, x)
    }

    private func mode(for band: Int, confidence: Double, sources: Set<SignalSource>, spectrum: [SignalSource: Int]) -> TrackerMode {
        let sourceCount = spectrum.values.reduce(0, +)
        if sources.contains(.anchor) || sourceCount >= 5 {
            return .anchor
        }
        if band <= 1 { return .survey }
        if band == 2 { return confidence >= 0.36 ? .track : .survey }
        if band >= 3 { return confidence >= 0.55 ? .lock : .track }
        return .track
    }

    private func atomWindow(for mode: TrackerMode, band: Int, spectrum: [SignalSource: Int]) -> AtomWindow? {
        let candidateOrder: [TrackerMode]
        let preferredBand = preferredPitchBand(for: band)

        if !sourcesAvailable(in: spectrum).isEmpty {
            let dominant = dominantSourceTag(in: spectrum)
            switch dominant {
            case .wifi, .anchor:
                candidateOrder = [mode, .anchor, .lock, .track, .survey]
            case .bleAdvert, .bleLink:
                candidateOrder = [mode, .track, .lock, .anchor, .survey]
            case .classic:
                candidateOrder = [mode, .lock, .anchor, .track, .survey]
            }
        } else {
            candidateOrder = [mode, .track, .lock, .anchor, .survey]
        }

        for candidate in candidateOrder {
            let windows = atomByMode[candidate] ?? []
            let pitchWindows = pitchFiltered(windows, for: preferredBand)
            if let picked = pickAtom(from: pitchWindows, by: band, mode: candidate) {
                return picked
            }

            if let picked = pickAtom(from: windows, by: band, mode: candidate) {
                return picked
            }
        }

        return pickAtom(from: atomWindows, by: band, mode: .fallback)
    }

    private func preferredPitchBand(for band: Int) -> PitchBand {
        switch band {
        case 0, 1: return .low
        case 2: return .mid
        default: return .high
        }
    }

    private func pitchFiltered(_ windows: [AtomWindow], for band: PitchBand) -> [AtomWindow] {
        guard let fromBand = atomByBand[band], !fromBand.isEmpty, !windows.isEmpty else {
            return windows
        }
        let keys = Set(windows.map { windowKey($0) })
        let filtered = fromBand.filter { keys.contains(windowKey($0)) }
        if filtered.isEmpty { return windows }
        return filtered
    }

    private func windowKey(_ window: AtomWindow) -> String {
        "\(window.start):\(window.count)"
    }

    private func sourcesAvailable(in spectrum: [SignalSource: Int]) -> [SignalSource] {
        spectrum.filter { $0.value > 0 }.map { $0.key }
    }

    private func dominantSourceTag(in spectrum: [SignalSource: Int]) -> SignalSource {
        if let dominant = spectrum.max(by: { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key.rawValue < rhs.key.rawValue
            }
            return lhs.value < rhs.value
        }) {
            return dominant.key
        }
        return .bleAdvert
    }

    private func pickAtom(from windows: [AtomWindow], by band: Int, mode: TrackerMode) -> AtomWindow? {
        guard !windows.isEmpty else { return nil }
        let sorted = windows.sorted { $0.pitchHz < $1.pitchHz }
        let count = sorted.count

        let target = Double(max(0, min(2, band))) / 2.0
        let tone = Int(round(target))
        let base = max(0, min(count - 1, (count - 1) * tone / 3))
        let spread = max(1, min(5, count / 4))
        let from = max(0, base - spread)
        let to = min(count - 1, base + spread)

        var candidateRange = Array(from...to)
        candidateRange.shuffle()

        var last = cursorByMode[mode.id] ?? Int.random(in: 0..<count)
        for idx in candidateRange {
            if idx != last || count == 1 {
                last = idx
                cursorByMode[mode.id] = idx
                return sorted[idx]
            }
        }

        let fallback = cursorByMode[mode.id] ?? Int.random(in: 0..<count)
        let next = (fallback + 1) % count
        cursorByMode[mode.id] = next
        return sorted[next]
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

    private func buildAtomByMode(_ windows: [AtomWindow]) -> [TrackerMode: [AtomWindow]] {
        var byMode: [TrackerMode: [AtomWindow]] = [
            .survey: [],
            .track: [],
            .lock: [],
            .anchor: []
        ]

        for window in windows {
            byMode[window.toneClass == .short ? .survey : (window.toneClass == .mid ? .track : .lock)]?.append(window)
            if window.duration < 0.12 || window.pitchHz < 1100 {
                byMode[.survey, default: []].append(window)
            }
            if window.duration > 0.18 {
                byMode[.anchor, default: []].append(window)
            }
        }

        for mode in TrackerMode.allCases where mode != .fallback {
            if byMode[mode] == nil || byMode[mode]!.isEmpty {
                byMode[mode] = windows
            }
        }

        return byMode
    }

    private func discoverAtoms(in file: AVAudioFile, sampleRate: Double) -> [AtomWindow] {
        guard let samples = readMonoSamples(from: file) else {
            return fallbackAtoms(fileLength: file.length)
        }
        guard !samples.isEmpty else {
            return fallbackAtoms(fileLength: file.length)
        }

        let cleaned = normalize(samples)
        guard let maxPeak = cleaned.map(abs).max(), maxPeak > 0.00008 else {
            return fallbackAtoms(fileLength: file.length)
        }

        let envelope = movingAverage(
            cleaned.map { abs($0) },
            window: max(16, Int(sampleRate * 0.006))
        )

        let noiseFloor = quantile(envelope, 0.45)
        let mad = medianAbsoluteDeviation(envelope, around: noiseFloor)
        let threshold = max(0.0008, noiseFloor + mad * 2.6)

        let minGap = Int(sampleRate * 0.012)
        let pad = Int(sampleRate * 0.012)

        var candidates: [AtomWindow] = []
        var start: Int?

        var i = 0
        while i < envelope.count {
            if envelope[i] > threshold {
                if start == nil { start = i }
            } else if let opened = start {
                let rawEnd = i
                let segmentStart = max(0, opened - pad)
                let segmentEnd = min(samples.count, rawEnd + pad)

                if let atom = makeAtom(start: segmentStart, end: segmentEnd, samples: cleaned, sampleRate: sampleRate) {
                    candidates.append(atom)
                }
                start = nil
            }
            i += 1
        }

        if let opened = start {
            let segmentStart = max(0, opened - pad)
            let segmentEnd = samples.count
            if let atom = makeAtom(start: segmentStart, end: segmentEnd, samples: cleaned, sampleRate: sampleRate) {
                candidates.append(atom)
            }
        }

        var merged: [AtomWindow] = []
        for atom in candidates.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last,
               atom.start <= last.start + AVAudioFramePosition(atom.count) &&
               last.start <= atom.start &&
               atom.start - (last.start + AVAudioFramePosition(last.count)) < AVAudioFramePosition(minGap) {
                let maxEnd = max(last.start + AVAudioFramePosition(last.count), atom.start + AVAudioFramePosition(atom.count))
                let mergedAtom = AtomWindow(
                    start: last.start,
                    count: AVAudioFrameCount(maxEnd - last.start),
                    energy: max(last.energy, atom.energy),
                    pitchHz: atom.pitchHz,
                    duration: max(atom.duration, last.duration),
                    toneClass: atom.toneClass,
                    rms: max(last.rms, atom.rms)
                )
                _ = merged.removeLast()
                merged.append(mergedAtom)
            } else {
                merged.append(atom)
            }
        }

        let filtered = merged.filter {
            Double($0.duration) >= 0.085 && Double($0.duration) <= 0.30 && $0.rms > max(0.015, 0.06 * maxPeak)
        }
        let sorted = filtered
            .sorted {
                if $0.energy == $1.energy {
                    return $0.count > $1.count
                }
                return $0.energy > $1.energy
            }
            .prefix(36)

        guard !sorted.isEmpty else {
            return fallbackAtoms(fileLength: file.length)
        }

        return Array(sorted).sorted { $0.start < $1.start }
    }

    private func makeAtom(start: Int, end: Int, samples: [Float], sampleRate: Double) -> AtomWindow? {
        guard end > start + 600 else { return nil }
        let clampedStart = max(0, start)
        let clampedEnd = min(samples.count, end)
        guard clampedEnd > clampedStart else { return nil }

        let length = clampedEnd - clampedStart
        let duration = Double(length) / sampleRate
        if duration < 0.06 || duration > 0.32 { return nil }

        let energy = rms(samples, from: clampedStart, to: clampedEnd)
        let peak = peak(samples, from: clampedStart, to: clampedEnd)
        guard peak > 0 else { return nil }
        let normalizedEnergy = energy / max(peak, 1e-12)

        let pitch = estimatePitchHz(samples: samples,
                                   sampleRate: sampleRate,
                                   start: clampedStart,
                                   end: clampedEnd)

        let toneClass: ToneClass
        if duration <= 0.12 {
            toneClass = .short
        } else if duration <= 0.19 {
            toneClass = .mid
        } else {
            toneClass = .long
        }

        let frameCount = AVAudioFrameCount(length)
        return AtomWindow(
            start: AVAudioFramePosition(clampedStart),
            count: frameCount,
            energy: energy,
            pitchHz: pitch,
            duration: duration,
            toneClass: toneClass,
            rms: normalizedEnergy
        )
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

    private func normalize(_ samples: [Float]) -> [Float] {
        guard let peak = samples.max(by: { abs($0) < abs($1) }), abs(peak) > 0.0005 else {
            return samples
        }
        let scale = 1.0 / abs(peak)
        return samples.map { $0 * scale }
    }

    private func movingAverage(_ values: [Float], window: Int) -> [Float] {
        guard !values.isEmpty else { return [] }
        guard window > 1 else { return values }

        var out = [Float](repeating: 0, count: values.count)
        var sum: Float = 0
        let floatWindow = Float(window)

        for idx in 0..<values.count {
            sum += values[idx]
            if idx >= window {
                sum -= values[idx - window]
                out[idx] = sum / floatWindow
            } else {
                out[idx] = sum / Float(idx + 1)
            }
        }

        return out
    }

    private func quantile(_ values: [Float], _ point: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = Int((Double(sorted.count - 1) * point).rounded())
        return sorted[min(max(0, idx), sorted.count - 1)]
    }

    private func medianAbsoluteDeviation(_ values: [Float], around median: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let shifted = values.map { abs($0 - median) }
        return quantile(shifted, 0.5)
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

    private func peak(_ samples: [Float], from start: Int, to end: Int) -> Float {
        guard start < end, end <= samples.count, start >= 0 else { return 0 }
        var peak: Float = 0
        for i in start..<end {
            let v = abs(samples[i])
            if v > peak { peak = v }
        }
        return peak
    }

    private func estimatePitchHz(samples: [Float], sampleRate: Double, start: Int, end: Int) -> Float {
        guard end > start + 256 else { return 0 }
        let clipStart = max(0, start)
        let clipEnd = min(samples.count, end)
        guard clipEnd > clipStart + 256 else { return 0 }

        var segment = Array(samples[clipStart..<clipEnd])
        let trim = max(0, segment.count / 14)
        if trim * 2 < segment.count {
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
        let frameDuration: AVAudioFramePosition = 2_900
        let step = max(1, fileLength / 6)

        return (0..<6).compactMap { idx -> AtomWindow? in
            let start = AVAudioFramePosition(idx) * step
            let end = min(fileLength, start + frameDuration)
            guard end > start else { return nil }
            let len = Int(end - start)
            let duration = Double(len) / 44_100.0
            return AtomWindow(
                start: start,
                count: AVAudioFrameCount(end - start),
                energy: 1,
                pitchHz: 1800,
                duration: duration,
                toneClass: duration > 0.19 ? .long : .mid,
                rms: 1
            )
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
        let jitter = Double.random(in: 0.92...1.14)
        return max(0.08, interval * jitter)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        token += 1
        currentMode = nil
        latestConfidence = 0
        latestEstimate = nil
        latestSpectrum.removeAll()
        lastSources.removeAll()
        player?.stop()
    }
}

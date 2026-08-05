import Foundation
import AVFoundation
import AudioToolbox

private let legacySystemFallbackPath = "/System/Library/Sounds/Tink.aiff"
private let audioResourceName = "alien_original_motion_tracker"
private let audioDebugEnv = "ALIEN_FINDPHONE_AUDIO_DEBUG"
private let audioFileOverrideEnv = "ALIEN_FINDPHONE_AUDIO_FILE"
private let audioFallbackEnv = "ALIEN_FINDPHONE_ALLOW_SYSTEM_SOUND_FALLBACK"

enum AudioSourceResolution: Equatable {
    case explicitPath(String)
    case overrideEnv(String)
    case bundled
    case missing
    case fallbackSystem
}

enum TrackerAudioMode {
    case tracking
    case idle
}

enum TargetFreshness {
    case fresh
    case fading
    case stale
}

final class Clicker {
    private let profile = MotionTrackerAudioProfile()
    private let queue = DispatchQueue(label: "findphone.audio", qos: .userInteractive)
    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private let engineOutputFormat: AVAudioFormat

    private let debugEnabled: Bool
    private var lastDebug = Date.distantPast

    private var outputFormat: AVAudioFormat
    private var sourceFormat: AVAudioFormat?
    private var sourceBuffer: AVAudioPCMBuffer?
    private(set) var sourceURL: URL?
    private(set) var resolution: AudioSourceResolution = .missing

    private var idlePairs: [BeatPair] = []
    private var trackingPairs: [BeatPair] = []

    private var exactFramesPerBeat: Double = 0
    private(set) var beatCellCount: Int = 0

    private var currentPairIndex = 0
    private var requestedPairIndex = 0
    private var requestedPairHold = 0
    private var pairHoldProximity = 0.0
    private var nextBeatNumber = 0
    private var queuedBeatCount = 0
    private var pairChangeBoundaryBeat = 0

    private var mode: TrackerAudioMode = .idle
    private var staleState: TargetFreshness = .stale
    private var isRunning = false
    private var isStopping = false
    private var lookAheadTimer: DispatchSourceTimer?
    private var fallbackTimer: DispatchSourceTimer?
    private let lookAheadBeats = 2
    private let lookAheadLowWatermark = 1
    private let lookAheadInterval: TimeInterval = 0.08

    private var filter: AudioProximityFilter
    private var lastTargetSeen: Date?
    private var confidence = 0.0

    private var activeTargetIdentity: String?

    private var engineStartCount = 0
    private var underrunCount = 0
    private var completedBeatCount = 0
    private var scheduledBeatCount = 0

    private var usedSystemFallback = false
    private var systemFallbackSound: SystemSoundID = 0

    var diagnostics: AudioBeatDiagnostics {
        let pairCount = max(1, activePairs().count)
        return AudioBeatDiagnostics(
            requestedPair: requestedPairIndex,
            currentPair: currentPairIndex,
            scheduledBeat: nextBeatNumber,
            queuedBeats: queuedBeatCount,
            underrunCount: underrunCount,
            scheduledBeatCount: scheduledBeatCount,
            completedBeatCount: completedBeatCount,
            filteredProximity: filter.filtered,
            sourcePairCount: pairCount,
            engineRestarts: engineStartCount
        )
    }

    init?(path: String? = nil) {
        debugEnabled = {
            let value = ProcessInfo.processInfo.environment[audioDebugEnv]?.lowercased() ?? ""
            return value == "1" || value == "true"
        }()

        outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 2
        ) ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!

        filter = AudioProximityFilter(attackTau: profile.attackTau, releaseTau: profile.releaseTau)

        let allowFallback = {
            let value = ProcessInfo.processInfo.environment[audioFallbackEnv]?.lowercased() ?? ""
            return value == "1" || value == "true"
        }()

        guard let candidate = Clicker.resolveAudioURL(explicitPath: path) else {
            if allowFallback, let fallback = Clicker.configureFallbackSystemSound() {
                usedSystemFallback = true
                resolution = .fallbackSystem
                sourceURL = nil
                engine = AVAudioEngine()
                player = AVAudioPlayerNode()
                engineOutputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
                outputFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
                    ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
                systemFallbackSound = fallback
                return
            }

            FileHandle.standardError.write(Data("findphone: tracker audio source not available\n".utf8))
            return nil
        }

        sourceURL = candidate.url
        resolution = candidate.resolution

        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        player.pan = 0
        engineOutputFormat = engine.mainMixerNode.outputFormat(forBus: 0)

        let mainMixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let desiredOutput = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: max(mainMixerFormat.sampleRate, 1.0),
            channels: AVAudioChannelCount(max(1, min(2, Int(mainMixerFormat.channelCount)))),
            interleaved: false
        ) ?? mainMixerFormat

        guard let decoded = Clicker.decodeAudioFile(at: candidate.url, decodeTo: desiredOutput) else {
            if allowFallback, let fallback = Clicker.configureFallbackSystemSound() {
                usedSystemFallback = true
                resolution = .fallbackSystem
                sourceURL = nil
                outputFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
                    ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
                FileHandle.standardError.write(Data("findphone: fallback to system sound; failed to decode \(candidate.url.path)\n".utf8))
                systemFallbackSound = fallback
                return
            }
            FileHandle.standardError.write(Data("findphone: cannot decode tracker audio at \(candidate.url.path)\n".utf8))
            return nil
        }

        sourceBuffer = decoded
        sourceFormat = decoded.format
        outputFormat = decoded.format

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

        exactFramesPerBeat = 60.0 / profile.bpm * outputFormat.sampleRate

        let cells = Clicker.buildBeatCells(
            from: decoded,
            profile: profile,
            exactFramesPerBeat: exactFramesPerBeat
        )
        beatCellCount = cells.count
        let grid = Clicker.buildBeatPairs(from: cells, profile: profile)
        idlePairs = grid.idle
        trackingPairs = grid.tracking

        setIdleMode()
        filter.reset(to: 0.0)

        if debugEnabled {
            logDiagnostics(force: true)
        }
    }

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.usedSystemFallback {
                self.startFallbackTimer()
                return
            }
            self.startAudioPlayback()
        }
    }

    func update(state: TargetAudioState) {
        queue.async { [weak self] in
            self?.apply(state: state)
        }
    }

    func stop() {
        queue.sync {
            guard !isStopping else { return }
            isStopping = true
            isRunning = false
            lookAheadTimer?.cancel()
            lookAheadTimer = nil
            fallbackTimer?.cancel()
            fallbackTimer = nil

            player.stop()
            if engine.isRunning {
                engine.stop()
            }
            if systemFallbackSound != 0 {
                AudioServicesDisposeSystemSoundID(systemFallbackSound)
                systemFallbackSound = 0
            }
            queuedBeatCount = 0
        }
    }

    // MARK: - Audio update + scheduling

    private func apply(state: TargetAudioState) {
        confidence = max(0.0, min(1.0, state.confidence))

        let now = state.lastSeen ?? Date()

        if state.identifier != activeTargetIdentity {
            activeTargetIdentity = state.identifier
            let resetValue = state.rssi.map(rawProximity) ?? 0.0
            filter.reset(to: max(0.0, min(1.0, resetValue)))
            pairHoldProximity = filter.filtered
            let pairs = activePairs()
            let pairCount = max(1, pairs.count)
            requestedPairHold = profile.clampPairIndex(roundedPair(from: filter.filtered, pairCount: pairCount), pairCount: pairCount)
            requestedPairIndex = requestedPairHold
            pairChangeBoundaryBeat = nextPairBoundary(from: nextBeatNumber)
            player.volume = scheduledGain()
        }

        guard let rssi = state.rssi else {
            staleState = .stale
            if let seen = state.lastSeen ?? lastTargetSeen {
                let age = now.timeIntervalSince(seen)
                if age >= profile.fadingTargetWindow {
                    setIdleMode()
                } else if age >= profile.freshTargetWindow {
                    staleState = .fading
                }
            } else {
                setIdleMode()
            }
            return
        }

        lastTargetSeen = now

        let pairs = activePairs()
        if pairs.isEmpty {
            setIdleMode()
            return
        }

        let raw = rawProximity(from: rssi)
        let filtered = filter.update(raw: raw, now: now)

        staleState = .fresh
        mode = .tracking

        let pairCount = max(1, pairs.count)
        let requested = roundedPair(from: filtered, pairCount: pairCount)

        if abs(filtered - pairHoldProximity) >= profile.proximityHysteresis {
            pairHoldProximity = filtered
            requestedPairHold = requested
            requestedPairIndex = requested
        } else {
            requestedPairIndex = requestedPairHold
        }

        requestedPairIndex = profile.clampPairIndex(requestedPairIndex, pairCount: pairCount)
        player.volume = scheduledGain()
    }

    private func roundedPair(from value: Double, pairCount: Int) -> Int {
        guard pairCount > 1 else { return 0 }
        let clamped = max(0.0, min(1.0, value))
        return Int(round(clamped * Double(pairCount - 1)))
    }

    private func rawProximity(from rssi: Int) -> Double {
        (Double(rssi) - profile.proximityFarRSSI) / (profile.proximityNearRSSI - profile.proximityFarRSSI)
    }

    private func setIdleMode() {
        mode = .idle
        let pairs = idlePairs
        let defaultPair = min(profile.fallbackIdlePairIndex, max(0, pairs.count - 1))
        currentPairIndex = defaultPair
        requestedPairIndex = defaultPair
        requestedPairHold = defaultPair
        pairHoldProximity = 0
        staleState = .stale
        player.volume = scheduledGain()
    }

    private func startAudioPlayback() {
        if isRunning || isStopping { return }

        do {
            try engine.start()
            engineStartCount += 1
        } catch {
            handleEngineStartFailure(error)
            return
        }

        isRunning = true
        fillLookAheadQueue()

        guard queuedBeatCount > 0 else {
            isRunning = false
            return
        }

        player.play()
        startLookAheadTimer()
        if debugEnabled {
            logDiagnostics(force: true)
        }
    }

    private func handleEngineStartFailure(_ error: Error) {
        FileHandle.standardError.write(Data("findphone: audio engine start failed: \(error.localizedDescription)\n".utf8))
    }

    private func startLookAheadTimer() {
        lookAheadTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: lookAheadInterval)
        timer.setEventHandler { [weak self] in
            self?.drainScheduler()
        }
        lookAheadTimer = timer
        timer.resume()
    }

    private func startFallbackTimer() {
        guard usedSystemFallback else { return }

        fallbackTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: profile.beatDuration)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.isStopping { return }
            if !self.isRunning {
                self.isRunning = true
            }
            AudioServicesPlaySystemSound(self.systemFallbackSound)
        }
        fallbackTimer = timer
        timer.resume()
    }

    private func drainScheduler() {
        guard isRunning, !isStopping, !usedSystemFallback else { return }
        guard sourceBuffer != nil else { return }

        let hadZeroQueue = queuedBeatCount == 0
        fillLookAheadQueue()

        if queuedBeatCount == 0, hadZeroQueue {
            underrunCount += 1
        }

        updateFreshnessState()

        if queuedBeatCount <= lookAheadLowWatermark && staleState == .stale {
            if mode == .idle {
                setIdleMode()
            }
        }
    }

    private func fillLookAheadQueue() {
        guard sourceBuffer != nil else { return }
        guard !activePairs().isEmpty else { return }

        while queuedBeatCount < lookAheadBeats {
            guard let buffer = nextBeatBuffer() else { return }

            let beat = nextBeatNumber
            player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async {
                    guard let self else { return }
                    self.queuedBeatCount = max(0, self.queuedBeatCount - 1)
                    self.completedBeatCount += 1
                    if self.debugEnabled {
                        let now = Date()
                        if now.timeIntervalSince(self.lastDebug) > 1.5 {
                            self.logDiagnostics()
                            self.lastDebug = now
                        }
                    }
                }
            }

            queuedBeatCount += 1
            scheduledBeatCount += 1
            nextBeatNumber += 1
            schedulePairStepIfNeeded(afterBeat: beat)
            if queuedBeatCount >= lookAheadBeats {
                break
            }
        }
    }

    private func nextBeatBuffer() -> AVAudioPCMBuffer? {
        let pairs = activePairs()
        guard !pairs.isEmpty else { return nil }

        let activeIndex = profile.clampPairIndex(currentPairIndex, pairCount: pairs.count)
        let pair = pairs[activeIndex]
        let phase = nextBeatNumber % max(1, profile.beatsPerPhrase)

        if phase == 0 {
            return pair.first.buffer
        }
        return pair.second.buffer
    }

    private func nextPairBoundary(from beat: Int) -> Int {
        return beat % profile.beatsPerPhrase == 0 ? beat + 1 : beat
    }

    private func schedulePairStepIfNeeded(afterBeat beat: Int) {
        guard !activePairs().isEmpty else { return }
        let pairCount = activePairs().count
        let target = profile.clampPairIndex(requestedPairIndex, pairCount: pairCount)
        let transition = Self.nextPair(
            beat: beat,
            requestedPair: target,
            currentPair: currentPairIndex,
            pairChangeBoundary: pairChangeBoundaryBeat,
            pairCount: pairCount,
            beatsPerPhrase: profile.beatsPerPhrase
        )

        if transition.changed {
            currentPairIndex = transition.newCurrentPair
            pairChangeBoundaryBeat = transition.newBoundary
        }
        player.volume = scheduledGain()
    }

    static func nextPair(
        beat: Int,
        requestedPair: Int,
        currentPair: Int,
        pairChangeBoundary: Int,
        pairCount: Int,
        beatsPerPhrase: Int
    ) -> (newCurrentPair: Int, newBoundary: Int, changed: Bool) {
        guard pairCount > 0 else { return (currentPair, pairChangeBoundary, false) }
        guard requestedPair != currentPair else { return (currentPair, pairChangeBoundary, false) }
        guard beat % beatsPerPhrase == 1 else { return (currentPair, pairChangeBoundary, false) }
        guard beat >= pairChangeBoundary else { return (currentPair, pairChangeBoundary, false) }

        var next = currentPair
        if requestedPair > currentPair {
            next += 1
        } else if requestedPair < currentPair {
            next -= 1
        }
        let clamped = max(0, min(pairCount - 1, next))
        return (clamped, beat + beatsPerPhrase, true)
    }

    private func updateFreshnessState() {
        guard let seen = lastTargetSeen else {
            staleState = .stale
            mode = .idle
            return
        }

        let age = Date().timeIntervalSince(seen)
        if age >= profile.fadingTargetWindow {
            staleState = .stale
            mode = .idle
            requestedPairIndex = profile.clampPairIndex(profile.fallbackIdlePairIndex, pairCount: max(1, activePairs().count))
        } else if age >= profile.freshTargetWindow {
            staleState = .fading
        } else {
            staleState = .fresh
        }
    }

    private func activePairs() -> [BeatPair] {
        switch mode {
        case .tracking:
            return trackingPairs.isEmpty ? idlePairs : trackingPairs
        case .idle:
            return idlePairs
        }
    }

    static func buildBeatPairs(from buffer: AVAudioPCMBuffer, profile: MotionTrackerAudioProfile) -> (idle: [BeatPair], tracking: [BeatPair]) {
        let exactFramesPerBeat = 60.0 / profile.bpm * buffer.format.sampleRate
        let cells = buildBeatCells(from: buffer, profile: profile, exactFramesPerBeat: exactFramesPerBeat)
        return buildBeatPairs(from: cells, profile: profile)
    }

    static func buildBeatPairs(from cells: [BeatCell], profile: MotionTrackerAudioProfile) -> (idle: [BeatPair], tracking: [BeatPair]) {

        let idleRange = profile.idleLoopBeatRange
        let trackingRange = profile.trackingRange(totalBeats: cells.count)

        func classifyPair(_ first: BeatCell, _ second: BeatCell) -> (BeatCell, BeatCell) {
            let firstEnergy = first.buffer.rmsEnergy()
            let secondEnergy = second.buffer.rmsEnergy()
            if firstEnergy >= secondEnergy {
                var strong = first
                strong = BeatCell(
                    index: strong.index,
                    startFrame: strong.startFrame,
                    frameLength: strong.frameLength,
                    accent: .strong,
                    sourceProgress: strong.sourceProgress,
                    buffer: strong.buffer
                )
                var weak = second
                weak = BeatCell(
                    index: weak.index,
                    startFrame: weak.startFrame,
                    frameLength: weak.frameLength,
                    accent: .weak,
                    sourceProgress: weak.sourceProgress,
                    buffer: weak.buffer
                )
                return (strong, weak)
            }

            var strong = second
            strong = BeatCell(
                index: strong.index,
                startFrame: strong.startFrame,
                frameLength: strong.frameLength,
                accent: .strong,
                sourceProgress: strong.sourceProgress,
                buffer: strong.buffer
            )
            var weak = first
            weak = BeatCell(
                index: weak.index,
                startFrame: weak.startFrame,
                frameLength: weak.frameLength,
                accent: .weak,
                sourceProgress: weak.sourceProgress,
                buffer: weak.buffer
            )
            return (weak, strong)
        }

        let pairRangeFor: (Range<Int>) -> [BeatPair] = { range in
            guard range.count >= 2 else { return [] }
            let start = max(0, range.lowerBound)
            let end = min(cells.count, range.upperBound)
            if end - start < 2 { return [] }

            var pairs: [BeatPair] = []
            var pairIndex = 0
            var i = start
            while i + 1 < end {
                var first = cells[i]
                var second = cells[i + 1]
                let pairSourceProgress = (first.sourceProgress + second.sourceProgress) * 0.5
                let classified = classifyPair(first, second)
                first = classified.0
                second = classified.1

                pairs.append(
                    BeatPair(
                        pairIndex: pairIndex,
                        first: first,
                        second: second,
                        sourceProgress: pairSourceProgress
                    )
                )
                pairIndex += 1
                i += 2
            }
            return pairs
        }

        let idlePairs = pairRangeFor(idleRange)

        if idlePairs.isEmpty {
            return ([], pairRangeFor(trackingRange))
        }

        let trackingPairs = pairRangeFor(trackingRange)

        if trackingPairs.isEmpty {
            return (idlePairs, idlePairs)
        }

        return (idlePairs, trackingPairs)
    }

    static func buildBeatCells(
        from buffer: AVAudioPCMBuffer,
        profile: MotionTrackerAudioProfile,
        exactFramesPerBeat: Double
    ) -> [BeatCell] {
        var cells: [BeatCell] = []

        let totalFrames = Int(buffer.frameLength)
        if totalFrames <= 0 {
            return []
        }

        var beatIndex = 0
        while true {
            let start = sourceFrame(
                forBeat: beatIndex,
                sampleRate: buffer.format.sampleRate,
                profile: profile,
                exactFramesPerBeat: exactFramesPerBeat
            )
            let end = sourceFrame(
                forBeat: beatIndex + 1,
                sampleRate: buffer.format.sampleRate,
                profile: profile,
                exactFramesPerBeat: exactFramesPerBeat
            )

            if end > totalFrames { break }
            if end <= start {
                beatIndex += 1
                continue
            }

            let length = end - start
            guard let segment = buffer.makeSegment(from: start, frameLength: length) else {
                beatIndex += 1
                continue
            }

            let progress = Double(start) / Double(max(1, totalFrames))
            cells.append(
                BeatCell(
                    index: beatIndex,
                    startFrame: AVAudioFramePosition(start),
                    frameLength: AVAudioFrameCount(length),
                    accent: .unknown,
                    sourceProgress: progress,
                    buffer: segment
                )
            )
            beatIndex += 1
        }

        for cell in cells {
            applyFade(to: cell.buffer)
        }

        return cells
    }

    static func sourceFrame(
        forBeat beatIndex: Int,
        sampleRate: Double,
        profile: MotionTrackerAudioProfile,
        exactFramesPerBeat: Double
    ) -> Int {
        Int(
            (
                profile.firstBeatOffsetSeconds * sampleRate
                + Double(beatIndex) * exactFramesPerBeat
            ).rounded()
        )
    }

    private func scheduledGain() -> Float {
        let confidenceGain = 0.4 + (0.6 * confidence)
        let freshnessGain: Double
        switch staleState {
        case .fresh: freshnessGain = 1.0
        case .fading: freshnessGain = 0.72
        case .stale: freshnessGain = 0.45
        }
        let proximity = filter.filtered
        let tonalGain = 0.3 + 0.7 * proximity
        return Float(confidenceGain * freshnessGain * tonalGain)
    }

    static func resolveAudioURL(explicitPath: String?) -> (url: URL, resolution: AudioSourceResolution)? {
        if let explicitPath {
            let expanded = (explicitPath as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return (URL(fileURLWithPath: expanded), .explicitPath(expanded))
            }
            FileHandle.standardError.write(Data("findphone: explicit audio path not found: \(expanded)\n".utf8))
            return nil
        }

        if let override = ProcessInfo.processInfo.environment[audioFileOverrideEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return (URL(fileURLWithPath: expanded), .overrideEnv(expanded))
            }
            FileHandle.standardError.write(Data("findphone: audio override not found at \(expanded)\n".utf8))
            return nil
        }

        if let bundled = Bundle.module.url(forResource: audioResourceName, withExtension: "m4a") {
            return (bundled, .bundled)
        }

        return nil
    }

    static func decodeAudioFile(at url: URL, decodeTo targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        do {
            let file = try AVAudioFile(forReading: url)
            let sourceSampleRate = file.processingFormat.sampleRate
            let sourceChannels = Int(file.processingFormat.channelCount)
            if sourceSampleRate <= 0 || sourceChannels <= 0 {
                return nil
            }

            let decodeFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceSampleRate,
                channels: AVAudioChannelCount(sourceChannels),
                interleaved: false
            ) ?? file.processingFormat

            let frames = AVAudioFrameCount(file.length)
            guard let decoded = AVAudioPCMBuffer(pcmFormat: decodeFormat, frameCapacity: frames) else { return nil }
            decoded.frameLength = frames
            try file.read(into: decoded)

            if decoded.format.sampleRate == targetFormat.sampleRate,
               decoded.format.channelCount == targetFormat.channelCount,
               decoded.format.commonFormat == targetFormat.commonFormat,
               decoded.format.isInterleaved == targetFormat.isInterleaved {
                return decoded
            }

            return convertBuffer(decoded, to: targetFormat)
        } catch {
            return nil
        }
    }

    private static func convertBuffer(_ source: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: source.format, to: targetFormat) else { return nil }

        let requestedFrames = Double(source.frameLength) * targetFormat.sampleRate / source.format.sampleRate
        let targetCapacity = AVAudioFrameCount(max(2, Int64(ceil(requestedFrames + 32.0))))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else { return nil }

        var sourceOffset: AVAudioFrameCount = 0

        let inputBlock: AVAudioConverterInputBlock = { packetCount, status in
            guard sourceOffset < source.frameLength else {
                status.pointee = .endOfStream
                return nil
            }

            let channels = Int(source.format.channelCount)
            let remaining = source.frameLength - sourceOffset
            let frameCount = min(AVAudioFrameCount(packetCount), remaining)
            guard let input = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: frameCount) else {
                status.pointee = .noDataNow
                return nil
            }
            input.frameLength = frameCount

            guard let sourceData = source.floatChannelData, let inputData = input.floatChannelData else {
                status.pointee = .noDataNow
                return nil
            }

            for ch in 0..<channels {
                memcpy(inputData[ch], sourceData[ch].advanced(by: Int(sourceOffset)), Int(frameCount) * MemoryLayout<Float>.size)
            }

            sourceOffset += frameCount
            status.pointee = sourceOffset >= source.frameLength ? .endOfStream : .haveData
            return input
        }

        var error: NSError?
        let status = converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        if status == .error {
            return nil
        }

        if output.frameLength == 0 {
            output.frameLength = output.frameCapacity
        }
        return output
    }

    private func logDiagnostics(force: Bool = false) {
        if !debugEnabled { return }

        let now = Date()
        if !force && now.timeIntervalSince(lastDebug) < 1.5 { return }
        lastDebug = now

        let d = diagnostics
        var lines: [String] = []
        lines.append("path=\(sourceURL?.path ?? "(system-fallback)")")
        if let sourceFormat {
            lines.append("sourceFormat=\(sourceFormat.sampleRate)Hz/\(sourceFormat.channelCount)ch/\(sourceFormat.commonFormat)")
        }
        lines.append("processingFormat=\(outputFormat.sampleRate)Hz/\(outputFormat.channelCount)ch/\(outputFormat.commonFormat)")
        lines.append("engineOutputFormat=\(engineOutputFormat.sampleRate)Hz/\(engineOutputFormat.channelCount)ch/\(engineOutputFormat.commonFormat)")
        lines.append("duration=\(String(format: "%.3f", sourceDuration))")
        lines.append("bpm=\(String(format: "%.2f", profile.bpm))")
        lines.append("beatDuration=\(String(format: "%.4f", profile.beatDuration))")
        lines.append("exactFramesPerBeat=\(String(format: "%.3f", exactFramesPerBeat))")
        lines.append("beatCells=\(beatCellCount)")
        lines.append("idleRange=\(profile.idleLoopBeatRange)")
        lines.append("trackingRange=\(profile.trackingRange(totalBeats: beatCellCount))")
        lines.append("filteredProx=\(String(format: "%.3f", d.filteredProximity))")
        lines.append("requestedPair=\(d.requestedPair)")
        lines.append("currentPair=\(d.currentPair)")
        lines.append("scheduledBeat=\(d.scheduledBeat)")
        lines.append("queued=\(d.queuedBeats)")
        lines.append("scheduledBeatCount=\(d.scheduledBeatCount)")
        lines.append("completedBeatCount=\(d.completedBeatCount)")
        lines.append("underruns=\(d.underrunCount)")
        lines.append("engineRestarts=\(d.engineRestarts)")

        FileHandle.standardError.write(Data("[audio] \(lines.joined(separator: ", "))\n".utf8))
    }

    private static func applyFade(to buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if channels == 0 || frames == 0 { return }

        let fadeDurationSeconds = 0.003
        let fadeFrames = max(1, min(Int(fadeDurationSeconds * buffer.format.sampleRate), frames / 2))

        for ch in 0..<channels {
            let ptr = data[ch]
            for i in 0..<fadeFrames {
                let g = Float(i) / Float(fadeFrames)
                ptr[i] *= g
                ptr[frames - 1 - i] *= g
            }
        }
    }

    private static func configureFallbackSystemSound() -> SystemSoundID? {
        guard FileManager.default.fileExists(atPath: legacySystemFallbackPath) else { return nil }
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(URL(fileURLWithPath: legacySystemFallbackPath) as CFURL, &id)
        guard status == kAudioServicesNoError else { return nil }
        return id
    }

    private var sourceDuration: TimeInterval {
        guard let buffer = sourceBuffer else { return 0 }
        return Double(buffer.frameLength) / buffer.format.sampleRate
    }
}

private extension AVAudioPCMBuffer {
    func rmsEnergy() -> Float {
        guard let data = floatChannelData else { return 0 }
        let channels = Int(format.channelCount)
        let frames = Int(frameLength)
        if channels == 0 || frames == 0 { return 0 }

        var sum: Float = 0
        for ch in 0..<channels {
            let ptr = data[ch]
            for i in 0..<frames {
                sum += ptr[i] * ptr[i]
            }
        }
        return sqrt(sum / Float(channels * frames))
    }

    func makeSegment(from startFrame: Int, frameLength: Int) -> AVAudioPCMBuffer? {
        guard let data = floatChannelData else { return nil }
        let available = Int(self.frameLength)
        guard frameLength > 0, startFrame >= 0, startFrame + frameLength <= available else { return nil }
        guard let dst = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameLength)) else { return nil }
        dst.frameLength = AVAudioFrameCount(frameLength)

        let channels = Int(format.channelCount)
        for ch in 0..<channels {
            memcpy(dst.floatChannelData![ch], data[ch].advanced(by: startFrame), frameLength * MemoryLayout<Float>.size)
        }
        return dst
    }
}

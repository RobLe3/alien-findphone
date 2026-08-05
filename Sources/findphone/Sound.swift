import Foundation
import AVFoundation
import AudioToolbox
import Accelerate

private let legacySystemFallbackPath = "/System/Library/Sounds/Tink.aiff"
private let audioResourceName = "alien_original_motion_tracker"
private let audioDebugEnv = "ALIEN_FINDPHONE_AUDIO_DEBUG"
private let audioFileOverrideEnv = "ALIEN_FINDPHONE_AUDIO_FILE"
private let audioFallbackEnv = "ALIEN_FINDPHONE_ALLOW_SYSTEM_SOUND_FALLBACK"

private let fallbackAudioSampleRate: Double = 44_100
private let audioAnalysisWindowSize = 8192
private let minimumAnalysisBandHz: Double = 1_000.0
private let maximumAnalysisBandHz: Double = 3_000.0
private let minimumTonePairRMS = 0.000_8
private let minimumPitchConfidence = 0.18
private let peakSafety = 0.95
private let toneGainFloor: Float = 0.5

private let defaultRawNoSignalProximity = 0.0

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

    private var engine: AVAudioEngine
    private var player: AVAudioPlayerNode

    private let engineOutputFormat: AVAudioFormat
    private var outputFormat: AVAudioFormat
    private var sourceFormat: AVAudioFormat?
    private var sourceURL: URL?
    private(set) var resolution: AudioSourceResolution = .missing

    private var sourceBuffer: AVAudioPCMBuffer?
    private var idlePairs: [BeatPair] = []
    private var trackingPairs: [BeatPair] = []
    private var toneBank: TrackerToneBank = TrackerToneBank(levels: [])

    private var exactFramesPerBeat = 0.0
    private(set) var beatCellCount: Int = 0

    private var currentToneLevel = 0
    private var requestedToneLevel = 0
    private var scheduledPhraseToneLevel = 0
    private var nextBeatNumber = 0
    private var queuedBeatCount = 0

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
    private var toneSelector: ToneLevelSelector

    private var lastTargetSeen: Date?
    private var confidence = 0.0
    private var rawProximityValue = defaultRawNoSignalProximity
    private var lastRawRSSI: Int?

    private var activeTargetIdentity: String?
    private var engineStartCount = 0
    private var underrunCount = 0
    private var completedBeatCount = 0
    private var scheduledBeatCount = 0

    private var usedSystemFallback = false
    private var systemFallbackSound: SystemSoundID = 0

    private let debugEnabled: Bool
    private var lastDebug = Date.distantPast

    var diagnostics: AudioBeatDiagnostics {
        let level = toneBank.level(at: requestedToneLevel)
        return AudioBeatDiagnostics(
            requestedToneLevel: requestedToneLevel,
            currentToneLevel: currentToneLevel,
            scheduledBeat: nextBeatNumber,
            queuedBeats: queuedBeatCount,
            underrunCount: underrunCount,
            scheduledBeatCount: scheduledBeatCount,
            completedBeatCount: completedBeatCount,
            filteredProximity: filter.filtered,
            targetToneFrequencyHz: Int(level.dominantFrequencyHz.rounded()),
            tonePairIndex: level.sourcePairIndex,
            engineRestarts: engineStartCount
        )
    }

    init?(path: String? = nil) {
        debugEnabled = {
            let value = ProcessInfo.processInfo.environment[audioDebugEnv]?.lowercased() ?? ""
            return value == "1" || value == "true"
        }()

        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: fallbackAudioSampleRate,
            channels: 2,
            interleaved: false
        ) ?? AVAudioFormat(standardFormatWithSampleRate: fallbackAudioSampleRate, channels: 2)!

        filter = AudioProximityFilter(attackTau: profile.attackTau, releaseTau: profile.releaseTau)
        toneSelector = ToneLevelSelector(levelCount: max(1, profile.minimumToneLevelCount), hysteresis: profile.proximityHysteresis)

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
                systemFallbackSound = fallback
                if debugEnabled {
                    logDiagnostics(force: true)
                }
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

        let desiredOutput = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: max(engineOutputFormat.sampleRate, 1.0),
            channels: AVAudioChannelCount(max(1, min(2, Int(engineOutputFormat.channelCount)))),
            interleaved: false
        ) ?? engineOutputFormat

        guard let decoded = Clicker.decodeAudioFile(at: candidate.url, decodeTo: desiredOutput) else {
            if allowFallback, let fallback = Clicker.configureFallbackSystemSound() {
                usedSystemFallback = true
                resolution = .fallbackSystem
                sourceFormat = nil
                sourceBuffer = nil
                outputFormat = desiredOutput
                systemFallbackSound = fallback
                if debugEnabled {
                    logDiagnostics(force: true)
                }
                return
            }
            FileHandle.standardError.write(Data("findphone: cannot decode tracker audio at \(candidate.url.path)\n".utf8))
            return nil
        }

        sourceFormat = decoded.format
        sourceBuffer = decoded
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

        guard let bank = Clicker.buildToneBank(from: trackingPairs, profile: profile) else {
            FileHandle.standardError.write(Data("findphone: insufficient tone levels could be extracted from tracker source\n".utf8))
            return nil
        }
        toneBank = bank

        toneSelector = ToneLevelSelector(
            levelCount: max(1, toneBank.count),
            initialLevel: 0,
            hysteresis: profile.proximityHysteresis
        )

        setIdleMode()
        filter.reset(to: defaultRawNoSignalProximity)

        if debugEnabled {
            printToneBankDebug()
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

            if isRunning {
                player.stop()
            }
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

    private func apply(state: TargetAudioState) {
        confidence = max(0.0, min(1.0, state.confidence))
        let now = state.lastSeen ?? Date()

        if state.identifier != activeTargetIdentity {
            activeTargetIdentity = state.identifier
            if let rssi = state.rssi {
                let raw = rawProximity(from: rssi)
                let clamped = clampProximity(raw)
                rawProximityValue = clamped
                lastRawRSSI = rssi
                filter.reset(to: clamped)

                let initial = toneSelectorValue(
                    from: rawProximity(from: rssi),
                    levelCount: toneBank.count
                )
                toneSelector.reset(to: initial)
                requestedToneLevel = clampToneLevel(initial)
            } else {
                requestedToneLevel = 0
                currentToneLevel = 0
                scheduledPhraseToneLevel = 0
                toneSelector.reset(to: 0)
            }
            rawProximityValue = (state.rssi).map(rawProximity).map(clampProximity) ?? defaultRawNoSignalProximity
            lastTargetSeen = state.lastSeen
        }

        guard let rssi = state.rssi else {
            if let seen = state.lastSeen ?? lastTargetSeen {
                let age = now.timeIntervalSince(seen)
                if age >= profile.fadingTargetWindow {
                    setIdleMode()
                } else if age >= profile.freshTargetWindow {
                    staleState = .fading
                    player.volume = scheduledGain()
                } else {
                    staleState = .fresh
                    mode = .idle
                    player.volume = scheduledGain()
                }
            } else {
                setIdleMode()
            }
            return
        }

        lastTargetSeen = now
        lastRawRSSI = rssi

        let raw = rawProximity(from: rssi)
        rawProximityValue = clampProximity(raw)

        let filtered = filter.update(raw: rawProximityValue, now: now)
        let requested = toneSelector.update(proximity: filtered)
        requestedToneLevel = clampToneLevel(requested)

        staleState = .fresh
        mode = .tracking
        player.volume = scheduledGain()
    }

    // MARK: - Playback control

    private func startAudioPlayback() {
        guard !isRunning, !isStopping else { return }

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
            engine.stop()
            return
        }

        player.play()
        startLookAheadTimer()

        if debugEnabled {
            logDiagnostics(force: true)
        }
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
            if !self.isRunning { self.isRunning = true }
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

        if hadZeroQueue && queuedBeatCount == 0 {
            underrunCount += 1
        }

        updateFreshnessState()

        if debugEnabled {
            let now = Date()
            if now.timeIntervalSince(lastDebug) > 1.5 {
                logDiagnostics(force: false)
                lastDebug = now
            }
        }
    }

    private func fillLookAheadQueue() {
        guard sourceBuffer != nil else { return }
        guard !toneBank.levels.isEmpty else { return }

        if queuedBeatCount <= lookAheadLowWatermark {
            while queuedBeatCount < lookAheadBeats {
                guard let buffer = nextBeatBuffer() else { return }
                player.scheduleBuffer(
                    buffer,
                    at: nil,
                    options: [],
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    self?.queue.async {
                        guard let self else { return }
                        guard !self.isStopping else { return }
                        self.queuedBeatCount = max(0, self.queuedBeatCount - 1)
                        self.completedBeatCount += 1

                        if self.debugEnabled {
                            let now = Date()
                            if now.timeIntervalSince(self.lastDebug) > 1.5 {
                                self.logDiagnostics(force: false)
                                self.lastDebug = now
                            }
                        }

                        // Refill at phrase boundaries and if queue has dropped.
                        if self.queuedBeatCount <= self.lookAheadLowWatermark {
                            self.fillLookAheadQueue()
                        }
                    }
                }

                queuedBeatCount += 1
                scheduledBeatCount += 1
                nextBeatNumber += 1
            }
        }
    }

    private func nextBeatBuffer() -> AVAudioPCMBuffer? {
        guard !toneBank.levels.isEmpty else { return nil }

        let phase = nextBeatNumber % max(1, profile.beatsPerPhrase)
        if phase == 0 {
            let requested = clampToneLevel(requestedToneLevel)
            currentToneLevel = requested
            scheduledPhraseToneLevel = requested
        }

        let level = toneBank.level(at: scheduledPhraseToneLevel)
        let pair = level.pair
        return phase == 0 ? pair.first.buffer : pair.second.buffer
    }

    private func setIdleMode() {
        mode = .idle
        staleState = .stale
        requestedToneLevel = profile.clampToneLevel(0, levelCount: toneBank.count)
        currentToneLevel = requestedToneLevel
        scheduledPhraseToneLevel = requestedToneLevel
        toneSelector.reset(to: requestedToneLevel)
        filter.reset(to: defaultRawNoSignalProximity)
        player.volume = scheduledGain()
    }

    private func updateFreshnessState() {
        guard let seen = lastTargetSeen else {
            setIdleMode()
            return
        }

        let age = Date().timeIntervalSince(seen)
        switch age {
        case 0..<profile.freshTargetWindow:
            if staleState != .fresh { staleState = .fresh }
        case profile.freshTargetWindow..<profile.fadingTargetWindow:
            staleState = .fading
            mode = .tracking
            player.volume = scheduledGain()
        default:
            staleState = .stale
            setIdleMode()
        }
    }

    private func clampToneLevel(_ value: Int) -> Int {
        return profile.clampToneLevel(value, levelCount: toneBank.count)
    }

    // MARK: - Audio analysis and source grid

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

    static func buildBeatCells(
        from buffer: AVAudioPCMBuffer,
        profile: MotionTrackerAudioProfile,
        exactFramesPerBeat: Double
    ) -> [BeatCell] {
        var cells: [BeatCell] = []
        let totalFrames = Int(buffer.frameLength)

        guard totalFrames > 0 else { return [] }

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

            let progress = Double(start) / Double(totalFrames)
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

    static func buildBeatPairs(from buffer: AVAudioPCMBuffer, profile: MotionTrackerAudioProfile) -> (idle: [BeatPair], tracking: [BeatPair]) {
        let exactFramesPerBeat = 60.0 / profile.bpm * buffer.format.sampleRate
        let cells = buildBeatCells(
            from: buffer,
            profile: profile,
            exactFramesPerBeat: exactFramesPerBeat
        )
        return buildBeatPairs(from: cells, profile: profile)
    }

    static func buildBeatPairs(
        from cells: [BeatCell],
        profile: MotionTrackerAudioProfile
    ) -> (idle: [BeatPair], tracking: [BeatPair]) {
        let idleRange = profile.idleLoopBeatRange
        let trackingRange = profile.trackingRange(totalBeats: cells.count)

        func makePairs(_ range: Range<Int>) -> [BeatPair] {
            let start = max(0, range.lowerBound)
            let end = min(range.upperBound, cells.count)
            guard end - start >= 2 else { return [] }

            var result: [BeatPair] = []
            var i = start
            var pairIndex = 0
            while i + 1 < end {
                let first = cells[i]
                let second = cells[i + 1]

                let firstEnergy = first.buffer.rmsEnergy()
                let secondEnergy = second.buffer.rmsEnergy()
                let firstAccent: BeatAccent = firstEnergy >= secondEnergy ? .strong : .weak
                let secondAccent: BeatAccent = firstEnergy >= secondEnergy ? .weak : .strong

                let pair = BeatPair(
                    pairIndex: pairIndex,
                    first: BeatCell(
                        index: first.index,
                        startFrame: first.startFrame,
                        frameLength: first.frameLength,
                        accent: firstAccent,
                        sourceProgress: first.sourceProgress,
                        buffer: first.buffer
                    ),
                    second: BeatCell(
                        index: second.index,
                        startFrame: second.startFrame,
                        frameLength: second.frameLength,
                        accent: secondAccent,
                        sourceProgress: second.sourceProgress,
                        buffer: second.buffer
                    ),
                    sourceProgress: (first.sourceProgress + second.sourceProgress) / 2.0
                )

                result.append(pair)
                pairIndex += 1
                i += 2
            }
            return result
        }

        let idlePairs = makePairs(idleRange)
        let trackingPairs = makePairs(trackingRange)
        return (idlePairs, trackingPairs)
    }

    static func buildToneBank(from pairs: [BeatPair], profile: MotionTrackerAudioProfile) -> TrackerToneBank? {
        guard !pairs.isEmpty else { return nil }
        guard let sampleRate = pairs.first?.first.buffer.format.sampleRate, sampleRate > 0 else { return nil }

        let analyses = pairs.compactMap { pair -> CandidateToneLevel? in
            let first = analyzeBeatTone(pair.first.buffer, sampleRate: sampleRate)
            let second = analyzeBeatTone(pair.second.buffer, sampleRate: sampleRate)

            let pairRMS = (Double(first.rms) + Double(second.rms)) * 0.5
            let pairPeak = max(Double(first.peakAmplitude), Double(second.peakAmplitude))
            let pairConfidence = (Double(first.confidence) + Double(second.confidence)) * 0.5

            guard pairRMS >= minimumTonePairRMS else { return nil }
            guard pairConfidence >= minimumPitchConfidence else { return nil }

            let firstFrequency = first.frequencyHz
            let secondFrequency = second.frequencyHz
            if firstFrequency <= 0 || secondFrequency <= 0 { return nil }

            let weighted = weightedFrequency(
                firstFrequency: firstFrequency,
                secondFrequency: secondFrequency,
                firstRms: first.rms,
                secondRms: second.rms
            )

            return CandidateToneLevel(
                pair: pair,
                sourcePairIndex: pair.pairIndex,
                dominantFrequencyHz: weighted,
                pitchConfidence: pairConfidence,
                pairRMS: pairRMS,
                pairPeak: pairPeak
            )
        }

        guard analyses.count >= profile.minimumToneLevelCount else {
            return nil
        }

        let sorted = analyses.sorted {
            if $0.dominantFrequencyHz == $1.dominantFrequencyHz {
                return $0.sourcePairIndex < $1.sourcePairIndex
            }
            return $0.dominantFrequencyHz < $1.dominantFrequencyHz
        }

        let deduplicated = removeNearDuplicateFrequencies(sorted, profile: profile)
        guard !deduplicated.isEmpty else { return nil }

        let desiredCount = min(profile.maximumToneLevelCount, deduplicated.count)
        let selectedCount = max(profile.minimumToneLevelCount, min(profile.desiredToneLevelCount, desiredCount))

        guard selectedCount > 0 else { return nil }

        let minFrequency = deduplicated.map { (candidate: CandidateToneLevel) in candidate.dominantFrequencyHz }.min() ?? 0
        let maxFrequency = deduplicated.map { (candidate: CandidateToneLevel) in candidate.dominantFrequencyHz }.max() ?? 0
        guard minFrequency > 0, maxFrequency > 0 else { return nil }

        let selection = pickFittedLevels(
            candidates: deduplicated,
            totalLevels: selectedCount,
            minFrequency: minFrequency,
            maxFrequency: maxFrequency
        )

        guard selection.count == selectedCount else { return nil }

        let selected = selection.compactMap { deduplicated[$0] }
        guard selected.count == selectedCount else { return nil }

        let medianRMS = median(selected.map { $0.pairRMS })
        let normalizedLevels = selected.enumerated().map { index, candidate in
            candidate.createLevel(index: index, normalizationTargetRMS: max(0.000_1, medianRMS))
        }

        return TrackerToneBank(levels: normalizedLevels)
    }

    static func buildToneBankDebugText(from levelCount: Int) -> String {
        "tone levels: \(levelCount)"
    }

    private func toneSelectorValue(from raw: Double, levelCount: Int) -> Int {
        guard levelCount > 1 else { return 0 }
        let clamped = clampProximity(raw)
        return Int(round(clamped * Double(levelCount - 1)))
    }

    private func rawProximity(from rssi: Int) -> Double {
        (Double(rssi) - profile.proximityFarRSSI) / (profile.proximityNearRSSI - profile.proximityFarRSSI)
    }

    private func clampProximity(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }

    private func scheduledGain() -> Float {
        let confidenceGain = 0.75 + 0.25 * confidence
        let freshnessGain: Double
        switch staleState {
        case .fresh:
            freshnessGain = 1.0
        case .fading:
            freshnessGain = 0.78
        case .stale:
            freshnessGain = 0.55
        }

        return Float(confidenceGain * freshnessGain)
    }

    private func printToneBankDebug() {
        for level in toneBank.levels {
            let line = "tone level \(level.level): pair \(level.sourcePairIndex), \(Int(level.dominantFrequencyHz.rounded())) Hz"
            FileHandle.standardError.write(Data("[audio] \(line)\n".utf8))
        }
    }

    private static func logLine(forToneLevel level: TrackerToneLevel?) -> String {
        guard let level else { return "tone=n/a pair=n/a freq=n/a" }
        return "tone=\(level.level) pair=\(level.sourcePairIndex) freq=\(Int(level.dominantFrequencyHz.rounded()))Hz"
    }

    private func logDiagnostics(force: Bool = false) {
        guard debugEnabled else { return }

        let now = Date()
        if !force && now.timeIntervalSince(lastDebug) < 1.5 { return }
        lastDebug = now

        let tone = toneBank.levels.isEmpty ? nil : toneBank.level(at: requestedToneLevel)
        let d = diagnostics

        func fmt3(_ value: Double) -> String { String(format: "%.3f", value) }
        func fmt4(_ value: Double) -> String { String(format: "%.4f", value) }
        func fmt2(_ value: Double) -> String { String(format: "%.2f", value) }
        func fmt0(_ value: Double) -> String { String(format: "%.0f", value) }

        var lines: [String] = []
        lines.append("path=\(sourceURL?.path ?? "(system-fallback)")")
        if let resolvedSourceFormat = sourceFormat {
            lines.append("sourceFormat=\(fmt0(resolvedSourceFormat.sampleRate))/\(resolvedSourceFormat.channelCount)ch/\(resolvedSourceFormat.commonFormat)")
        }
        lines.append("processingFormat=\(fmt0(outputFormat.sampleRate))/\(outputFormat.channelCount)ch/\(outputFormat.commonFormat)")
        lines.append("engineOutputFormat=\(fmt0(engineOutputFormat.sampleRate))/\(engineOutputFormat.channelCount)ch/\(engineOutputFormat.commonFormat)")
        lines.append("duration=\(fmt3(sourceDuration))")
        lines.append("bpm=\(fmt2(profile.bpm))")
        lines.append("beatDuration=\(fmt4(profile.beatDuration))")
        lines.append("exactFramesPerBeat=\(fmt3(exactFramesPerBeat))")
        lines.append("beatCells=\(beatCellCount)")
        lines.append("toneLevels=\(toneBank.count)")

        lines.append("identity=\(activeTargetIdentity ?? "(none)")")
        lines.append("rawRSSI=\(lastRawRSSI?.description ?? "n/a")")
        lines.append("rawProx=\(fmt3(rawProximityValue))")
        lines.append("filteredProx=\(fmt3(d.filteredProximity))")
        lines.append("requestedTone=\(d.requestedToneLevel)")
        lines.append("currentTone=\(d.currentToneLevel)")
        lines.append("\(Self.logLine(forToneLevel: tone))")
        lines.append("confidence=\(fmt2(confidence))")
        lines.append("freshness=\(staleState)")
        lines.append("queued=\(d.queuedBeats)")
        lines.append("underruns=\(d.underrunCount)")
        lines.append("scheduledBeat=\(d.scheduledBeat)")
        lines.append("scheduledBeatCount=\(d.scheduledBeatCount)")
        lines.append("completedBeatCount=\(d.completedBeatCount)")
        lines.append("engineRestarts=\(d.engineRestarts)")

        let payload = lines.joined(separator: ", ")
        FileHandle.standardError.write(Data("[audio] \(payload)\n".utf8))
    }

    private func handleEngineStartFailure(_ error: Error) {
        FileHandle.standardError.write(Data("findphone: audio engine start failed: \(error.localizedDescription)\n".utf8))
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
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty {
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
            let sourceFormat = file.processingFormat
            if sourceFormat.sampleRate <= 0 || sourceFormat.channelCount == 0 {
                return nil
            }

            let decodeFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceFormat.sampleRate,
                channels: sourceFormat.channelCount,
                interleaved: false
            ) ?? sourceFormat

            let frameCapacity = AVAudioFrameCount(file.length)
            guard let decoded = AVAudioPCMBuffer(pcmFormat: decodeFormat, frameCapacity: frameCapacity) else { return nil }
            decoded.frameLength = frameCapacity
            try file.read(into: decoded)

            if decoded.format.sampleRate == targetFormat.sampleRate &&
                decoded.format.channelCount == targetFormat.channelCount &&
                decoded.format.commonFormat == targetFormat.commonFormat &&
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

        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError, withInputFrom: inputBlock)
        guard status != .error else {
            return nil
        }

        if output.frameLength == 0 {
            output.frameLength = output.frameCapacity
        }
        return output
    }

    private static func configureFallbackSystemSound() -> SystemSoundID? {
        guard FileManager.default.fileExists(atPath: legacySystemFallbackPath) else { return nil }
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(URL(fileURLWithPath: legacySystemFallbackPath) as CFURL, &id)
        guard status == kAudioServicesNoError else { return nil }
        return id
    }

    private static func analyzeBeatTone(_ buffer: AVAudioPCMBuffer, sampleRate: Double) -> ToneAnalysis {
        guard let sourceData = buffer.floatChannelData else {
            return ToneAnalysis(frequencyHz: 0, confidence: 0, rms: 0, peakAmplitude: 0)
        }
        let channels = Int(buffer.format.channelCount)
        if channels == 0 || buffer.frameLength == 0 {
            return ToneAnalysis(frequencyHz: 0, confidence: 0, rms: 0, peakAmplitude: 0)
        }

        let totalFrames = Int(buffer.frameLength)
        if totalFrames < 16 {
            return ToneAnalysis(frequencyHz: 0, confidence: 0, rms: 0, peakAmplitude: 0)
        }

        let mono = monoBuffer(
            from: sourceData,
            channels: channels,
            frameCount: totalFrames
        )

        let rms = monoAmplitudeRMS(mono)
        let peak = monoPeakAmplitude(mono)

        guard rms >= minimumTonePairRMS else {
            return ToneAnalysis(frequencyHz: 0, confidence: 0, rms: rms, peakAmplitude: peak)
        }

        let analysis = analyzeSpectrum(mono, sampleRate: sampleRate)
        guard let frequency = analysis.frequencyHz else {
            return ToneAnalysis(frequencyHz: 0, confidence: 0, rms: rms, peakAmplitude: peak)
        }

        return ToneAnalysis(
            frequencyHz: frequency,
            confidence: analysis.confidence,
            rms: rms,
            peakAmplitude: peak
        )
    }

    private static func analyzeSpectrum(_ mono: [Float], sampleRate: Double) -> (frequencyHz: Double?, confidence: Double) {
        let window = min(audioAnalysisWindowSize, mono.count)
        guard window >= 16 else { return (nil, 0) }

        let range = bestAnalysisWindow(in: mono, windowSize: window)
        guard range.length > 8 else { return (nil, 0) }
        let windowed = Array(mono[range.start..<(range.start + range.length)])

        let n = 1 << Int(ceil(log2(Double(windowed.count))))
        var packed = [Float](repeating: 0, count: n)

        for i in 0..<(n/2) {
            let firstIndex = i * 2
            let secondIndex = firstIndex + 1
            if firstIndex < windowed.count {
                packed[2 * i] = windowed[firstIndex] * 0.5
            }
            if secondIndex < windowed.count && (2 * i + 1) < n {
                packed[2 * i + 1] = 0
            }
        }

        let halfN = n / 2
        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)
        var mags = [Float](repeating: 0, count: halfN)

        guard let setup = vDSP_create_fftsetup(
            vDSP_Length(log2(Double(n))),
            FFTRadix(kFFTRadix2)
        ) else {
            return (nil, 0)
        }

        defer { vDSP_destroy_fftsetup(setup) }

        packed.withUnsafeMutableBufferPointer { packedBuf in
            real.withUnsafeMutableBufferPointer { realBuf in
                imag.withUnsafeMutableBufferPointer { imagBuf in
                    var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                    packedBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(halfN))
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(n))), FFTDirection(kFFTDirection_Forward))
                    split.imagp[0] = 0
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(halfN))
                }
            }
        }

        if mags.isEmpty {
            return (nil, 0)
        }

        let minHz = max(minimumAnalysisBandHz, 1)
        let maxHz = min(maximumAnalysisBandHz, sampleRate * 0.49)

        let startBin = Int(minHz * Double(n) / sampleRate)
        let endBin = Int(maxHz * Double(n) / sampleRate)
        if startBin < 0 || startBin >= endBin || endBin >= halfN {
            return (nil, 0)
        }

        let safeStart = max(1, startBin)
        let safeEnd = min(halfN - 2, endBin)
        if safeStart > safeEnd {
            return (nil, 0)
        }

        let search = Array(mags[safeStart...safeEnd])
        guard let maxOffset = search.enumerated().max(by: { lhs, rhs in lhs.element < rhs.element })?.0 else {
            return (nil, 0)
        }
        let peakIndex = safeStart + maxOffset

        let bandMedian = max(1e-12, Double(median(search)))
        let rawPeak = Double(mags[peakIndex])
        let conf = min(8.0, rawPeak / bandMedian)

        guard peakIndex > 0 && peakIndex + 1 < mags.count else {
            let freq = sampleRate * Double(peakIndex) / Double(n)
            return (freq, conf)
        }

        let peak = mags[peakIndex]
        let left = mags[peakIndex - 1]
        let right = mags[peakIndex + 1]

        let denominator = 2 * peak - left - right
        let safeDenominator = max(1e-12, Double(denominator))
        let interpolated = Double(peakIndex) + 0.5 * (Double(left) - Double(right)) / safeDenominator
        let frequency = sampleRate * interpolated / Double(n)

        return (frequency, conf)
    }

    private static func bestAnalysisWindow(in mono: [Float], windowSize: Int) -> (start: Int, length: Int) {
        let frameCount = mono.count
        guard frameCount > 0 else { return (0, 0) }
        let requestedWindow = min(windowSize, frameCount)

        if frameCount <= requestedWindow {
            return (0, frameCount)
        }

        let step = max(1, requestedWindow / 4)
        var bestStart = 0
        var bestEnergy = -Double.infinity

        var start = 0
        while start + requestedWindow <= frameCount {
            let end = start + requestedWindow
            var energy = 0.0
            for i in start..<end {
                let sample = mono[i]
                energy += Double(sample * sample)
            }
            if energy > bestEnergy {
                bestEnergy = energy
                bestStart = start
            }
            start += step
        }

        return (bestStart, requestedWindow)
    }

    private static func monoBuffer(
        from sourceData: UnsafePointer<UnsafeMutablePointer<Float>>?,
        channels: Int,
        frameCount: Int
    ) -> [Float] {
        guard let sourceData else { return [] }
        guard channels > 0, frameCount > 0 else { return [] }

        var mono = [Float](repeating: 0, count: frameCount)
        let divisor = Float(channels)
        for i in 0..<frameCount {
            var sum: Float = 0
            for ch in 0..<channels {
                sum += sourceData[ch][i]
            }
            mono[i] = sum / divisor
        }
        return mono
    }

    private static func monoAmplitudeRMS(_ values: [Float]) -> Double {
        guard !values.isEmpty else { return 0 }
        var total: Float = 0
        for v in values {
            total += v * v
        }
        return Double(sqrt(total / Float(values.count)))
    }

    private static func monoPeakAmplitude(_ values: [Float]) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.map { abs($0) }.max() ?? 0)
    }

    private static func weightedFrequency(
        firstFrequency: Double,
        secondFrequency: Double,
        firstRms: Double,
        secondRms: Double
    ) -> Double {
        let numerator = firstFrequency * firstRms + secondFrequency * secondRms
        let denominator = firstRms + secondRms
        guard denominator > 0 else { return max(firstFrequency, secondFrequency) }
        return numerator / denominator
    }

    private static func removeNearDuplicateFrequencies(
        _ candidates: [CandidateToneLevel],
        profile: MotionTrackerAudioProfile
    ) -> [CandidateToneLevel] {
        var deduplicated: [CandidateToneLevel] = []
        var last: CandidateToneLevel?

        for candidate in candidates {
            if let previous = last {
                if centsBetween(previous.dominantFrequencyHz, candidate.dominantFrequencyHz) < profile.duplicateToneCents {
                    continue
                }
            }
            deduplicated.append(candidate)
            last = candidate
        }

        return deduplicated
    }

    private static func pickFittedLevels(
        candidates: [CandidateToneLevel],
        totalLevels: Int,
        minFrequency: Double,
        maxFrequency: Double
    ) -> [Int] {
        guard totalLevels > 0, !candidates.isEmpty else { return [] }

        if candidates.count == totalLevels {
            return Array(0..<candidates.count)
        }

        var result: [Int] = []
        var used: Set<Int> = []

        for i in 0..<totalLevels {
            let fraction = Double(i) / Double(max(1, totalLevels - 1))
            let targetLogFrequency = log(minFrequency) + (log(maxFrequency) - log(minFrequency)) * fraction

            var selected: Int?
            var bestDistance = Double.greatestFiniteMagnitude
            for index in 0..<candidates.count where !used.contains(index) {
                let candidate = candidates[index]
                let distance = abs(log(candidate.dominantFrequencyHz) - targetLogFrequency)
                if distance < bestDistance {
                    bestDistance = distance
                    selected = index
                }
            }

            guard let pick = selected else { continue }
            result.append(pick)
            used.insert(pick)
        }

        return Array(Set(result)).sorted()
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private var sourceDuration: TimeInterval {
        guard let buffer = sourceBuffer else { return 0 }
        return Double(buffer.frameLength) / buffer.format.sampleRate
    }
}

private struct CandidateToneLevel {
    let pair: BeatPair
    let sourcePairIndex: Int
    let dominantFrequencyHz: Double
    let pitchConfidence: Double
    let pairRMS: Double
    let pairPeak: Double

    func createLevel(index: Int, normalizationTargetRMS: Double) -> TrackerToneLevel {
        let scaledFirst = pair.first.buffer
        let scaledSecond = pair.second.buffer

        let effectiveTarget = max(0.000_1, normalizationTargetRMS)
        let desiredGain = effectiveTarget / max(pairRMS, 0.000_001)
        let peakSafeGain = peakSafety / max(pairPeak, 0.000_001)
        let gainUpper = min(desiredGain, peakSafeGain)
        let gainClamped = min(2.0, gainUpper)
        let gain = Float(max(Double(toneGainFloor), gainClamped))

        let first = Clicker.copyAndScaleBuffer(scaledFirst, gain: gain)
        let second = Clicker.copyAndScaleBuffer(scaledSecond, gain: gain)
        let normalisedPair = BeatPair(
            pairIndex: pair.pairIndex,
            first: BeatCell(
                index: pair.first.index,
                startFrame: pair.first.startFrame,
                frameLength: pair.first.frameLength,
                accent: pair.first.accent,
                sourceProgress: pair.first.sourceProgress,
                buffer: first
            ),
            second: BeatCell(
                index: pair.second.index,
                startFrame: pair.second.startFrame,
                frameLength: pair.second.frameLength,
                accent: pair.second.accent,
                sourceProgress: pair.second.sourceProgress,
                buffer: second
            ),
            sourceProgress: pair.sourceProgress
        )

        return TrackerToneLevel(
            level: index,
            sourcePairIndex: pair.pairIndex,
            pair: normalisedPair,
            dominantFrequencyHz: dominantFrequencyHz,
            pitchConfidence: pitchConfidence,
            normalizationGain: gain
        )
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

        guard frameLength > 0,
              startFrame >= 0,
              startFrame + frameLength <= available else { return nil }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameLength)
        ) else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameLength)

        let channels = Int(format.channelCount)
        for ch in 0..<channels {
            memcpy(buffer.floatChannelData![ch], data[ch].advanced(by: startFrame), frameLength * MemoryLayout<Float>.size)
        }

        return buffer
    }
}

private extension Clicker {
    static func copyAndScaleBuffer(_ buffer: AVAudioPCMBuffer, gain: Float) -> AVAudioPCMBuffer {
        guard let sourceData = buffer.floatChannelData else {
            return buffer
        }

        guard let scaled = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return buffer
        }
        scaled.frameLength = buffer.frameLength
        guard let targetData = scaled.floatChannelData else {
            return buffer
        }

        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)

        for ch in 0..<channels {
            let source = sourceData[ch]
            let target = targetData[ch]
            for i in 0..<frameCount {
                target[i] = source[i] * gain
            }
        }

        return scaled
    }

    static func applyFade(to buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }

        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if channels == 0 || frames == 0 { return }

        let fadeFrames = max(1, min(Int(0.003 * buffer.format.sampleRate), frames / 2))

        for ch in 0..<channels {
            let ptr = data[ch]
            for i in 0..<fadeFrames {
                let factor = Float(i) / Float(fadeFrames)
                ptr[i] *= factor
                ptr[frames - 1 - i] *= factor
            }
        }
    }
}

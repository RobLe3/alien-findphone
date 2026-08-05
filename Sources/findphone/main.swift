import Foundation
import Darwin

var activeTerminalInput: TerminalSelectionController?
private var activeClicker: Clicker?
private let runLockFile = "\(NSHomeDirectory())/.cache/findphone/findphone.lock"
private var runLockDescriptor: Int32 = -1

private func activeRunLockPath() -> String {
    let parent = (runLockFile as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    return runLockFile
}

private func activeProcess(pid: Int) -> Bool {
    let result = kill(Int32(pid), 0)
    return result == 0 || errno == EPERM
}

private func stopProcess(pid: Int) {
    guard pid != Int(getpid()) else { return }
    guard activeProcess(pid: pid) else { return }

    _ = kill(Int32(pid), SIGTERM)
    for _ in 0..<20 {
        if !activeProcess(pid: pid) { return }
        usleep(60_000)
    }
    _ = kill(Int32(pid), SIGKILL)
}

private func existingPidFromLockFile(_ path: String) -> Int? {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let first = contents.split(separator: "\n").first
    return first.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

private func writeRunLock(pid: Int32, to descriptor: Int32) {
    let marker = "\(pid)\n\(Date())\n"
    _ = lseek(descriptor, 0, SEEK_SET)
    _ = ftruncate(descriptor, 0)
    marker.withCString { cStr in
        _ = write(descriptor, cStr, strlen(cStr))
    }
}

private func releaseRunLock() {
    if runLockDescriptor >= 0 {
        flock(runLockDescriptor, LOCK_UN)
        _ = close(runLockDescriptor)
        runLockDescriptor = -1
    }
    if FileManager.default.fileExists(atPath: runLockFile) {
        try? FileManager.default.removeItem(atPath: runLockFile)
    }
}

private func acquireRunLockOrExit(replaceExisting: Bool) {
    let lockPath = activeRunLockPath()
    let lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard lockFD >= 0 else {
        FileHandle.standardError.write(Data("findphone: unable to create run lock file.\n".utf8))
        exit(1)
    }

    if flock(lockFD, LOCK_EX | LOCK_NB) == 0 {
        runLockDescriptor = lockFD
        writeRunLock(pid: getpid(), to: lockFD)
        return
    }

    let existingPid = existingPidFromLockFile(lockPath)
    if let existingPid, existingPid != Int(getpid()) {
        if replaceExisting && activeProcess(pid: existingPid) {
            stopProcess(pid: existingPid)
            if flock(lockFD, LOCK_EX | LOCK_NB) == 0 {
                runLockDescriptor = lockFD
                writeRunLock(pid: getpid(), to: lockFD)
                return
            }
        }
        if activeProcess(pid: existingPid) {
            FileHandle.standardError.write(
                Data("findphone: another instance appears to be running (pid \(existingPid)). Stop it before starting a new detector.\n".utf8)
            )
        } else {
            FileHandle.standardError.write(
                Data("findphone: lock holder from pid \(existingPid) is stale. Releasing stale lock.\n".utf8)
            )
            _ = close(lockFD)
            try? FileManager.default.removeItem(atPath: lockPath)
            acquireRunLockOrExit(replaceExisting: replaceExisting)
            return
        }
    } else {
        FileHandle.standardError.write(
            Data("findphone: cannot acquire lock (filesystem busy). Another process may still hold it.\n".utf8)
        )
    }
    _ = close(lockFD)
    exit(1)
}

@inline(__always)
private func stopTerminalInput() {
    activeTerminalInput?.stop()
    activeTerminalInput = nil
}

@inline(__always)
private func terminalExit(_ code: Int32) -> Never {
    stopTerminalInput()
    activeClicker = nil
    releaseRunLock()
    exit(code)
}

func terminalSignalHandler(_ signal: Int32) {
    switch signal {
    case SIGINT, SIGTERM, SIGHUP, SIGQUIT:
        terminalExit(128 + signal)
    default:
        terminalExit(0)
    }
}

func terminalCleanup() {
    stopTerminalInput()
    activeClicker = nil
    releaseRunLock()
}

final class TerminalSelectionController {
    private enum EscapeState: Int {
        case none
        case escape
        case bracket
        case ss3
    }

    enum Command {
        case up
        case down
        case lock
        case clear
        case quit
    }

    private let onCommand: (Command) -> Void
    private let stdin = FileHandle.standardInput
    private var originalState: termios?
    private var escapeState: EscapeState = .none

    init(onCommand: @escaping (Command) -> Void) {
        self.onCommand = onCommand
    }

    func start() {
        guard originalState == nil else { return }
        guard isatty(STDIN_FILENO) == 1 else { return }

        originalState = currentTerminalState()
        configureInteractiveInputMode()

        stdin.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                self.stop()
                return
            }
            data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for i in 0..<bytes.count {
                    self.consume(bytes[i])
                }
            }
        }
    }

    func stop() {
        stdin.readabilityHandler = nil
        restoreTerminal()
    }

    deinit {
        stop()
    }

    private func consume(_ byte: UInt8) {
        switch escapeState {
        case .none:
            switch byte {
            case 0x1B: // ESC
                escapeState = .escape
            case 0x0A, 0x0D: // LF / CR
                onCommand(.lock)
            case 0x03: // Ctrl-C
                onCommand(.quit)
            case 0x71, 0x51: // q/Q
                onCommand(.quit)
            case 0x63, 0x43: // c/C
                onCommand(.clear)
            case 0x6A, 0x4A: // j/J
                onCommand(.down)
            case 0x6B, 0x4B: // k/K
                onCommand(.up)
            default:
                break
            }
        case .escape:
            if byte == 0x5B {
                escapeState = .bracket
            } else if byte == 0x4F { // SS3
                escapeState = .ss3
            } else {
                escapeState = .none
                if byte != 0x1B {
                    consume(byte)
                }
            }
        case .ss3:
            switch byte {
            case 0x41:
                onCommand(.up)
            case 0x42:
                onCommand(.down)
            default:
                break
            }
            escapeState = .none
        case .bracket:
            switch byte {
            case 0x41:
                onCommand(.up)
            case 0x42:
                onCommand(.down)
            default:
                break
            }
            escapeState = .none
        }
    }

    private func currentTerminalState() -> termios? {
        var state = termios()
        guard tcgetattr(STDIN_FILENO, &state) == 0 else { return nil }
        return state
    }

    private func configureInteractiveInputMode() {
        guard let original = originalState else { return }
        var state = makeInteractiveInputMode(from: original)
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &state)
    }

    private func restoreTerminal() {
        guard var state = originalState else { return }
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &state)
        originalState = nil
    }
}

func makeInteractiveInputMode(from original: termios) -> termios {
    var state = original
    state.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
    state.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON | IXOFF)
    withUnsafeMutableBytes(of: &state.c_cc) { raw in
        raw[raw.index(raw.startIndex, offsetBy: Int(VMIN))] = 0
        raw[raw.index(raw.startIndex, offsetBy: Int(VTIME))] = 1
    }
    return state
}

let usage = """
findphone — locate a nearby Bluetooth device by signal strength

  findphone            survey every nearby RF source
  findphone <name>     track one device by name (case-insensitive)
  findphone --list     show paired devices and their addresses

  Interactive selection (survey or manual hunt):
  arrows or j/k    move highlight in the list
  enter           lock onto selected target
  c               clear manual lock
  q               quit immediately

  --help, -h            show help
  --sound              legacy alias; audio is enabled by default unless muted
  --redact             mask Bluetooth addresses, for screen recording
  --wifi               force-enable Wi‑Fi scanning
  --no-wifi            disable Wi‑Fi scanning
  --anchors <path>     path to optional anchors.json
  --audio-pack <path>  optional path to an m4a tracker sound pack. If omitted, uses bundled "alien_original_motion_tracker.m4a" unless ALIEN_FINDPHONE_AUDIO_FILE overrides it.
  --replace            replace any already-running detector instance
  --replace-existing   legacy alias for --replace
  --mute               run without tracker sound (audio disabled)
  --no-sound           alias for --mute
"""

final class SelectionState {
    private let lock = NSLock()
    private(set) var candidateIdentities: [String] = []
    private(set) var selectedIndex: Int = 0

    func replaceCandidates(_ identities: [String], selectedIdentity: String?) {
        lock.lock()
        defer { lock.unlock() }
        candidateIdentities = identities

        if let selectedIdentity,
           let explicitIndex = identities.firstIndex(of: selectedIdentity) {
            selectedIndex = explicitIndex
            return
        }

        if identities.isEmpty {
            selectedIndex = 0
            return
        }

        if selectedIndex >= identities.count {
            selectedIndex = identities.count - 1
        }
    }

    func moveUp() {
        lock.lock()
        defer { lock.unlock() }
        guard !candidateIdentities.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + candidateIdentities.count) % candidateIdentities.count
    }

    func moveDown() {
        lock.lock()
        defer { lock.unlock() }
        guard !candidateIdentities.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % candidateIdentities.count
    }

    func currentIdentity() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !candidateIdentities.isEmpty else { return nil }
        return candidateIdentities[selectedIndex]
    }

    var highlightedIdentity: String? {
        lock.lock()
        defer { lock.unlock() }
        guard !candidateIdentities.isEmpty && selectedIndex < candidateIdentities.count else { return nil }
        return candidateIdentities[selectedIndex]
    }
}


func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("findphone: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

let rawArgs = Array(CommandLine.arguments.dropFirst())

var args = rawArgs
var options: Set<String> = []
var values: [String: String] = [:]
var names: [String] = []

var i = 0
while i < args.count {
    let arg = args[i]
    if arg.hasPrefix("-") {
        switch arg {
        case "--anchors", "--audio-pack":
            let next = i + 1
            guard next < args.count else {
                usageError("option '\(arg)' needs a value")
            }
            values[arg] = args[next]
            options.insert(arg)
            i += 1
        case "--help", "-h", "--list", "--redact", "--sound", "--wifi", "--no-wifi", "--replace", "--replace-existing", "--mute", "--no-sound":
            options.insert(arg)
        default:
            if arg.hasPrefix("--") {
                usageError("unknown option '\(arg)'")
            } else {
                names.append(arg)
            }
        }
        i += 1
        continue
    }
    names.append(arg)
    i += 1
}

if options.contains("-h") || options.contains("--help") {
    print(usage)
    exit(0)
}

if names.count > 1 {
    usageError("expected one device name, got \(names.count): \(names.joined(separator: ", "))")
}

let redact = options.contains("--redact")
let enableWiFi = !options.contains("--no-wifi")
let anchorPath = values["--anchors"]
let audioPath = values["--audio-pack"].map { ($0 as NSString).expandingTildeInPath }
let replaceExisting = options.contains("--replace") || options.contains("--replace-existing")
let silentMode = options.contains("--mute") || options.contains("--no-sound") || isAudioMutedByDefault()

if options.contains("--list") {
    Display.list(Classic.devicesByStrength(), redact: redact)
    exit(0)
}

atexit(terminalCleanup)
signal(SIGINT, terminalSignalHandler)
signal(SIGTERM, terminalSignalHandler)
signal(SIGHUP, terminalSignalHandler)
signal(SIGQUIT, terminalSignalHandler)

acquireRunLockOrExit(replaceExisting: replaceExisting)

/// Detector audio is default when any tracking is active (hunt + survey).
activeClicker = silentMode ? nil : Clicker(path: audioPath)
if let clicker = activeClicker {
    clicker.start()
} else if silentMode {
    FileHandle.standardError.write(Data("findphone: sound disabled (start with --mute to force quiet mode).\n".utf8))
} else {
    FileHandle.standardError.write(Data("findphone: tracker audio not available, using silent mode\n".utf8))
}

let tracker = Tracker(targetName: names.first, enableWiFi: enableWiFi, anchorPath: anchorPath)
tracker.start()

let selectionState = SelectionState()
let interactiveSelection = isatty(STDIN_FILENO) == 1

if interactiveSelection {
    var terminalInput: TerminalSelectionController?
    terminalInput = TerminalSelectionController { command in
        switch command {
        case .up:
            selectionState.moveUp()
        case .down:
            selectionState.moveDown()
        case .lock:
            if let identity = selectionState.currentIdentity() {
                tracker.setManualFocus(identity: identity)
            }
        case .clear:
            tracker.setManualFocus(identity: nil)
        case .quit:
            terminalExit(0)
        }
    }
    terminalInput?.start()
    activeTerminalInput = terminalInput
}

let drawInterval = names.isEmpty ? 1.0 : 0.25
Timer.scheduledTimer(withTimeInterval: drawInterval, repeats: true) { _ in
    let snapshot = tracker.snapshot()
    if interactiveSelection {
        let selectable = snapshot.potentialAssets.isEmpty ? snapshot.assets : snapshot.potentialAssets
        let identities = selectable.map(\.identity)
        selectionState.replaceCandidates(identities, selectedIdentity: snapshot.selectedIdentity)
    }

    Display.render(snapshot, redact: redact, interactive: interactiveSelection, highlightedIdentity: selectionState.highlightedIdentity)

    var shouldSound = false
    if let focus = snapshot.focusAsset {
        let age = snapshot.at.timeIntervalSince(focus.last)
        shouldSound = age < 18
        if shouldSound {
            let staleLock = snapshot.isManualTracking
                && snapshot.selectedIdentity != nil
                && snapshot.selectedIdentity != focus.identity
            if staleLock {
                activeClicker?.update(rssi: nil)
                return
            }
            let live = snapshot.focusLive ?? focus.bestRSSI
            let staleQuality = focus.confidence(now: snapshot.at)
            let confidence = snapshot.focusFresh ? staleQuality : staleQuality * 0.55
            let sourceTags: Set<SignalSource> = Set(focus.sources.keys)
            activeClicker?.update(
                rssi: live,
                sources: sourceTags,
                spectrum: snapshot.sourceDistribution,
                confidence: confidence,
                estimate: snapshot.estimate,
                focusIdentity: snapshot.selectedIdentity ?? focus.identity
            )
            return
        }
    }

    if !shouldSound {
        activeClicker?.update(rssi: nil)
    }
}

RunLoop.main.run()


private func isAudioMutedByDefault() -> Bool {
    let env = ProcessInfo.processInfo.environment
    if env["ALIEN_FINDPHONE_MUTE"]?.lowercased() == "1" || env["ALIEN_FINDPHONE_MUTE"]?.lowercased() == "true" {
        return true
    }
    if env["CI"] != nil {
        return true
    }
    return false
}

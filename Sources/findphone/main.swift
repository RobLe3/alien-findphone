import Foundation

let usage = """
findphone — locate a nearby Bluetooth device by signal strength

  findphone            survey every nearby RF source
  findphone <name>     track one device by name (case-insensitive)
  findphone --list     show paired devices and their addresses

  --sound              legacy alias; distance tone is on by default in hunt mode
  --redact             mask Bluetooth addresses, for screen recording
  --wifi               force-enable Wi‑Fi scanning
  --no-wifi            disable Wi‑Fi scanning
  --anchors <path>     path to optional anchors.json
  --audio-pack <path>  use custom m4a tracker sound pack (default: detector_asssets/audio.m4a)
"""


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
        case "--help", "-h", "--list", "--redact", "--sound", "--wifi", "--no-wifi":
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
let audioPath = resolveAudioPackPath(values["--audio-pack"])

if options.contains("--list") {
    Display.list(Classic.devicesByStrength(), redact: redact)
    exit(0)
}

/// Detector audio is default when any tracking is active (hunt + survey).
var clicker: Clicker?
clicker = Clicker(path: audioPath)
if let clicker {
    clicker.start()
} else if FileManager.default.fileExists(atPath: audioPath) {
    FileHandle.standardError.write(Data("findphone: could not open tracker audio at \(audioPath)\n".utf8))
} else {
    FileHandle.standardError.write(Data("findphone: tracker audio not available, using silent mode\n".utf8))
}

let tracker = Tracker(targetName: names.first, enableWiFi: enableWiFi, anchorPath: anchorPath)
tracker.start()

Timer.scheduledTimer(withTimeInterval: names.isEmpty ? 1.0 : 0.25, repeats: true) { _ in
    let snapshot = tracker.snapshot()
    Display.render(snapshot, redact: redact)
    if snapshot.focusFresh {
        let quality = snapshot.focusAsset?.confidence(now: snapshot.at) ?? 0
        let sourceTags: Set<SignalSource> = snapshot.focusAsset.map { Set($0.sources.keys) } ?? []
        clicker?.update(
            rssi: snapshot.focusLive,
            sources: sourceTags,
            confidence: quality,
            estimate: snapshot.estimate
        )
    } else {
        clicker?.update(rssi: nil)
    }
}

RunLoop.main.run()


func defaultAudioPackPath() -> String {
    let cwd = FileManager.default.currentDirectoryPath
    let executableDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().path
    let candidates = [
        "\(cwd)/detector_asssets/audio.m4a",
        "\(NSHomeDirectory())/development/findphone/detector_asssets/audio.m4a",
        "\(executableDir)/detector_asssets/audio.m4a",
        Bundle.main.bundlePath + "/../Resources/detector_asssets/audio.m4a"
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
}

func resolveAudioPackPath(_ explicit: String?) -> String {
    guard let path = explicit else { return defaultAudioPackPath() }
    let expanded = (path as NSString).expandingTildeInPath
    return expanded
}

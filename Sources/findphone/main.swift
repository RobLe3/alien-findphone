import Foundation

let usage = """
findphone — locate a nearby Bluetooth device by signal strength

  findphone            survey every nearby Apple handheld
  findphone <name>     track one device by name (case-insensitive)
  findphone --list     show paired devices and their addresses

  --sound              click faster as you get closer (hunt mode)
  --redact             mask Bluetooth addresses, for screen recording
"""

let knownFlags: Set<String> = ["-h", "--help", "--list", "--redact", "--sound"]

func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("findphone: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

let args = CommandLine.arguments.dropFirst()

if args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(0)
}

if let unknown = args.first(where: { $0.hasPrefix("-") && !knownFlags.contains($0) }) {
    usageError("unknown option '\(unknown)'")
}

let names = args.filter { !$0.hasPrefix("-") }
if names.count > 1 {
    usageError("expected one device name, got \(names.count): \(names.joined(separator: ", "))")
}

let redact = args.contains("--redact")

if args.contains("--list") {
    Display.list(Classic.devicesByStrength(), redact: redact)
    exit(0)
}

/// Clicks only make sense with a single target; survey mode tracks many.
var clicker: Clicker?
if args.contains("--sound") {
    if names.isEmpty {
        usageError("--sound needs a device name to track")
    }
    clicker = Clicker()
    if clicker == nil {
        FileHandle.standardError.write(Data("findphone: could not open the click sound\n".utf8))
    }
}

let tracker = Tracker(targetName: names.first)
tracker.start()

Timer.scheduledTimer(withTimeInterval: names.isEmpty ? 1.0 : 0.25, repeats: true) { _ in
    let snapshot = tracker.snapshot()
    Display.render(snapshot, redact: redact)
    if let live = snapshot.live, snapshot.isFresh {
        clicker?.click(rssi: live, now: snapshot.at)
    }
}

RunLoop.main.run()

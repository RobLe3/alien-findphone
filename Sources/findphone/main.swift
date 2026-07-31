import Foundation

let usage = """
findphone — locate a nearby Bluetooth device by signal strength

  findphone            survey every nearby Apple handheld
  findphone <name>     track one device by name (case-insensitive)
  findphone --list     show paired devices and their addresses

  --redact             mask Bluetooth addresses, for screen recording
"""

let args = CommandLine.arguments.dropFirst()

if args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(0)
}

let redact = args.contains("--redact")

if args.contains("--list") {
    Display.list(Classic.devicesByStrength(), redact: redact)
    exit(0)
}

let target = args.first { !$0.hasPrefix("-") }
let tracker = Tracker(targetName: target)
tracker.start()

Timer.scheduledTimer(withTimeInterval: target == nil ? 1.0 : 0.25, repeats: true) { _ in
    Display.render(tracker.snapshot(), redact: redact)
}

RunLoop.main.run()

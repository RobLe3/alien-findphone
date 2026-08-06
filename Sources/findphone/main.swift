import Foundation

private func printUsageAndExit() -> Never {
    print(usageText)
    exit(0)
}

func selectCandidate(tracker: Tracker, redact: Bool) -> String? {
    let interval = 1.0

    while true {
        let snapshot = tracker.snapshot()

        if snapshot.candidates.isEmpty {
            print("Nearby Apple handhelds — no candidates yet")
            print("Waiting for nearby devices... (or press q to quit)")
            if let input = readLine(strippingNewline: true), input.lowercased() == "q" {
                return nil
            }
            sleep(UInt32(interval))
            continue
        }

        print("Nearby Apple handhelds — select one to track:\n")
        for (index, candidate) in snapshot.candidates.enumerated() {
            let live = Int(candidate.smoothed.rounded())
            let stale = snapshot.at.timeIntervalSince(candidate.last) > 3 ? " (stale)" : ""
            let name = redact ? candidate.kind : candidate.label
            let line = String(format: "%2d. %@ %4d dBm  peak %4d", index + 1, bar(live), live, candidate.peak)
            print("\(line)  \(name)\(stale)")
        }

        print("Select a device number, or q to quit: ", terminator: "")
        guard let raw = readLine(strippingNewline: true) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.lowercased() == "q" {
            return nil
        }

        guard let selected = Int(value), selected > 0, selected <= snapshot.candidates.count else {
            print("Invalid selection. Enter 1 through \(snapshot.candidates.count), or q to quit.")
            sleep(1)
            continue
        }

        return snapshot.candidates[selected - 1].identity
    }
}

let args = CommandLine.arguments.dropFirst()
let parsed: ParsedArguments

do {
    parsed = try parseArguments(args)
} catch let error as ParseError {
    switch error {
    case .unknownFlag(let flag):
        usageError("unknown option '\(flag)'")
    case .tooManyNames(let count):
        usageError("expected one device name, got \(count)")
    case .selectWithName:
        usageError("--select does not take a device name")
    case .missingNameForSound:
        usageError("--sound needs a device name to track")
    case .selectWithList:
        usageError("--select and --list are mutually exclusive")
    }
} catch {
    usageError("failed to parse arguments")
}

if parsed.wantsHelp {
    printUsageAndExit()
}

if parsed.wantsList {
    Display.list(Classic.devicesByStrength(), redact: parsed.redact)
    exit(0)
}

let tracker = Tracker(targetName: parsed.targetName)
tracker.start()

var clicker: Clicker?
if parsed.wantsSound {
    clicker = Clicker()
    if let clicker {
        clicker.start()
    } else {
        FileHandle.standardError.write(Data("findphone: could not open the click sound\n".utf8))
    }
}

if parsed.wantsSelect {
    guard let selectedIdentity = selectCandidate(tracker: tracker, redact: parsed.redact) else {
        print("No selection made.")
        exit(0)
    }
    tracker.setManualSelection(identity: selectedIdentity)
}

let renderInterval = parsed.targetName == nil && !parsed.wantsSelect ? 1.0 : 0.25
Timer.scheduledTimer(withTimeInterval: renderInterval, repeats: true) { _ in
    let snapshot = tracker.snapshot()
    Display.render(snapshot, redact: parsed.redact)
    let value = snapshot.effectiveFresh ? snapshot.effectiveLive : nil
    clicker?.update(rssi: value)
}

RunLoop.main.run()

import Foundation

private let clearScreen = "\u{1B}[2J\u{1B}[H"
private let huntRule = String(repeating: "=", count: 56)
private let surveyRule = String(repeating: "-", count: 78)

enum Display {
    /// One write per frame; twenty prints to a line-buffered TTY tears.
    static func render(_ s: Snapshot) {
        let lines = s.targetName == nil ? survey(s) : hunt(s)
        print(clearScreen + lines.joined(separator: "\n"), terminator: "\n")
        fflush(stdout)
    }

    private static func hunt(_ s: Snapshot) -> [String] {
        var out = ["Tracking \"\(s.targetName!)\"   \(s.address ?? "")   [\(s.elapsed)s]", huntRule]

        if let issue = s.radioIssue {
            return out + ["", "  \(issue)"]
        }
        guard let last = s.readings.last else {
            return out + ["", "  No contact yet — \(s.deviceCount) other devices in range.", "",
                          "  If this persists the device is powered off, out of range",
                          "  (~10-20 m), or shut inside something metal."]
        }

        let live = s.readings.since(4, now: s.at).medianRSSI ?? last.rssi
        let lastMinute = s.readings.since(60, now: s.at)
        let peak = lastMinute.peakRSSI ?? live
        let age = s.at.timeIntervalSince(last.at)

        out += [
            "",
            String(format: "        %4d dBm        %@", live, s.link.rawValue),
            "",
            "   [\(bar(live, width: 38))]",
            "",
            "   \(sparkline(s.readings.suffix(44)))",
            "   each block = one real measurement",
            "",
            String(format: "   peak/min %4d   measurements %d   last min %d   via %@",
                   peak, s.readings.count, lastMinute.count, last.source),
            "",
            "        >>>  \(Proximity.describe(live))  <<<",
            "",
            String(format: "   refreshed %.0fs ago%@", age,
                   age > 15 ? "  (stale — hold still)" : ""),
            huntRule,
            "Move a few metres, then STAND STILL ~10s for a refresh.",
            "Ctrl-C to stop.",
        ]
        return out
    }

    private static func survey(_ s: Snapshot) -> [String] {
        var out = [
            "Nearby Apple handhelds — live signal   [\(s.elapsed)s, \(s.deviceCount) tracked]",
            "Walk slowly. The one that climbs as you approach a spot is your device.",
            surveyRule,
        ]
        if let issue = s.radioIssue { out.append("  \(issue)") }
        if s.advertisers.isEmpty { out.append("  (nothing yet — give it a few seconds)") }

        for (i, a) in s.advertisers.prefix(12).enumerated() {
            let live = Int(a.smoothed.rounded())
            let stale = s.at.timeIntervalSince(a.last) > 3 ? " (stale)" : ""
            out.append(String(format: "%2d. %@ %4d dBm  peak %4d  ", i + 1, bar(live), live, a.peak)
                       + pad(Proximity.describe(live), Proximity.labelWidth) + stale)
            out.append("    \(a.label)")
        }
        return out + [surveyRule, "Ctrl-C to stop."]
    }

    static func list(_ devices: [ClassicDevice]) {
        guard !devices.isEmpty else {
            print("No paired Bluetooth devices found.")
            return
        }
        print(pad("NAME", 26) + pad("ADDRESS", 20) + pad("RSSI", 7) + "STATE")
        for d in devices {
            print(pad(d.name, 26) + pad(d.address, 20)
                  + pad(d.rssi.map(String.init) ?? "-", 7)
                  + (d.connected ? "connected" : "not connected"))
        }
        print("\nTrack one with:  findphone <name>")
    }
}

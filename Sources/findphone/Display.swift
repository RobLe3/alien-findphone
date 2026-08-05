import Foundation

private let clearScreen = "\u{1B}[2J\u{1B}[H"
private let margin = "    "
private let panelWidth = 88
private let surveyRule = String(repeating: "-", count: panelWidth)

private let huntWidth = 82
private let huntRule = Style.wrap(String(repeating: "─", count: huntWidth), Style.cyan)
private let huntFooter = Style.wrap("  alien scanner :: move, hold still 8-12s for clearer trend", Style.dim)
private let dBmSuffix = Style.wrap("   dBm", Style.dim)

/// Indexed by Proximity.band, so the colour cannot drift from the label.
private let bandTones = [Style.brightGreen, Style.green, Style.yellow, Style.amber, Style.red]

/// A Bluetooth public address is a stable hardware identifier, so it is worth
/// hiding when the screen is being recorded.
private let maskedAddress = "••:••:••:••:••:••"

private let assetColumn = 22
private let sourceColumn = 24
private let confidenceColumn = 10
private let meterBarWidth = 52

enum Display {
    /// One write per frame; one print per frame avoids line tearing in TTY.
    static func render(_ s: Snapshot, redact: Bool = false) {
        let lines = s.targetName == nil ? survey(s, redact: redact) : hunt(s, redact: redact)
        print(clearScreen + lines.joined(separator: "\n"), terminator: "\n")
        fflush(stdout)
    }

    private static func hunt(_ s: Snapshot, redact: Bool) -> [String] {
        let address = redact ? maskedAddress : (s.address ?? "")
        let status = "\(s.link.rawValue) · \(s.elapsed)s"
        let titleText = "[ALIEN SCAN] TRACK: \(s.targetName ?? "target")"
        let padCount = max(1, huntWidth - titleText.count - status.count)
        var lines = [
            Style.wrap(titleText + String(repeating: " ", count: padCount) + status, Style.cyan),
            huntRule,
            "",
            "  target: \(address)",
            ""
        ]

        lines += focusMeterLines(focus: s.focusAsset, at: s.at, readings: s.focusReadings, headline: "TRACK")

        if let issue = s.radioIssue {
            lines.append("  \(issue)")
        }

        if let est = s.estimate {
            lines.append(Style.wrap("  trilateration hint: (\(fmt(est.x)), \(fmt(est.y))) conf \(percent(est.confidence))", Style.dim))
        }

        lines.append("")
        lines.append(Style.wrap("  nearby high-confidence assets", Style.cyan))

        if s.potentialAssets.isEmpty {
            lines.append("    (none yet, waiting for RSSI convergence)")
        } else {
            for (i, asset) in s.potentialAssets.prefix(6).enumerated() {
                lines.append(assetLine(i: i, asset: asset, now: s.at, redact: redact))
            }
        }

        return lines + [huntRule, huntFooter]
    }

    private static func survey(_ s: Snapshot, redact: Bool) -> [String] {
        var lines = [
            Style.wrap("[ALIEN SCANNER] MULTI-SOURCE SURVEY", Style.cyan),
            Style.wrap("Live assets: \(s.deviceCount) · potential: \(s.potentialAssets.count) · elapsed \(s.elapsed)s", Style.dim),
            surveyRule,
        ]

        let sourceSummary = s.sourceDistribution
            .map { "\($0.key.rawValue): \($0.value)" }
            .sorted()
            .joined(separator: "  ")
        if !sourceSummary.isEmpty {
            lines.append("  source mix: \(sourceSummary)")
        }
        let spectrum = sourceSummaryTagLine(s.sourceDistribution)
        if !spectrum.isEmpty {
            lines.append("  spectrum: \(spectrum)")
        }
        if let est = s.estimate {
            lines.append("  trilateration: (\(fmt(est.x)), \(fmt(est.y))) confidence \(percent(est.confidence)) from \(est.sources) anchors")
        }
        if let issue = s.radioIssue {
            lines.append("  \(issue)")
        }

        lines.append("")
        lines += focusMeterLines(focus: s.focusAsset, at: s.at, readings: s.focusReadings, headline: "FOCUS")

        lines.append("")
        lines.append(Style.wrap("  top candidates", Style.cyan))
        lines.append("  #  \(pad("label", assetColumn)) \(pad("src", sourceColumn)) \(pad("rssi", 6)) \(pad("conf", confidenceColumn)) age")

        guard !s.assets.isEmpty else {
            lines.append("  (nothing yet — give it a few seconds)")
            return lines + ["", "Ctrl-C to stop."]
        }

        let shown = s.potentialAssets.isEmpty ? s.assets.prefix(16) : s.potentialAssets.prefix(16)
        for (i, asset) in shown.enumerated() {
            lines.append(assetLine(i: i, asset: asset, now: s.at, redact: redact))
        }
        lines.append("")
        lines.append("Ctrl-C to stop.")
        return lines
    }

    private static func focusMeterLines(focus: TrackedAsset?, at: Date,
                                      readings: [Reading], headline: String) -> [String] {
        var out: [String] = [Style.wrap("  \(headline) METER", Style.cyan)]

        guard let focus = focus else {
            out.append("  waiting for a stable asset…")
            return out + [""]
        }

        let sourceTags = focus.sources.keys.map(\.rawValue).sorted().joined(separator: ",")
        let conf = percent(focus.confidence(now: at))
        let age = Int(at.timeIntervalSince(focus.last).rounded())
        let stale = age > 7 ? Style.wrap("  stale", Style.amber) : ""
        out.append("  \(focus.label) · \(sourceTags) · conf \(conf) · age \(age)s\(stale)")

        let sampleHistory = readings.isEmpty
            ? [Reading(rssi: focus.bestRSSI, at: focus.last, source: focus.mostRecentSource?.rawValue ?? "")] : readings
        let last = sampleHistory.last
        let live = sampleHistory.since(liveWindow, now: at).medianRSSI ?? sampleHistory.last?.rssi
        let lastMinute = sampleHistory.since(60, now: at)
        let peak = lastMinute.peakRSSI ?? live
        let peakText = peak.map(String.init) ?? "-"

        guard let last, let live else {
            out.append("  no valid RSSI sample yet")
            return out
        }

        let ageText = Int(at.timeIntervalSince(last.at).rounded())
        let tone = bandTones[Proximity.band(live)]
        let digits = bigNumber(String(live)).enumerated().map { row, glyph in
            margin + Style.wrap(glyph, tone) + (row == bigTextMiddle ? dBmSuffix : "")
        }
        let label = Style.wrap(Proximity.describe(live).uppercased(), tone)
        let trend = trendLabel(Trend.of(sampleHistory, now: at))

        out += [
            "",
            label + "   " + trend,
            "",
            margin + Style.wrap(bar(live, width: meterBarWidth, fill: "█", empty: "░"), tone),
            "",
            margin + Style.wrap(sparkline(sampleHistory.suffix(44)), Style.dim),
            Style.wrap("\(margin)spark · via \(last.source) · refreshed \(ageText)s ago", Style.dim),
            Style.wrap("\(margin)peak/min \(peakText) · asset \(focus.bestRSSI) dBm", Style.dim),
            ""
        ]

        out += digits
        return out
    }

    private static func trendLabel(_ trend: Trend) -> String {
        switch trend {
        case .warmer:  return Style.wrap("▲ WARMER", Style.brightGreen)
        case .colder:  return Style.wrap("▼ COLDER", Style.red)
        case .steady:  return Style.wrap("· steady", Style.dim)
        case .unknown: return ""
        }
    }

    private static func assetLine(i: Int, asset: TrackedAsset, now: Date, redact: Bool) -> String {
        let label = redact ? redactLabel(asset.label, maxLen: assetColumn) : pad(asset.label, assetColumn)
        let sources = asset.sources.keys
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let sourceSnippet = pad(String(sources.prefix(sourceColumn)), sourceColumn)
        let conf = percent(asset.confidence(now: now))
        let stale = now.timeIntervalSince(asset.last) > 7
        let age = Int(now.timeIntervalSince(asset.last).rounded())
        let staleSuffix = stale ? "  stale" : ""
        return "  \(pad(String(i + 1), 2)). \(label) \(sourceSnippet)  \(pad(String(asset.bestRSSI), 6))  \(pad(conf, confidenceColumn))  \(age)s\(staleSuffix)"
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    private static func percent(_ v: Double) -> String {
        String(format: "%3.0f%%", v * 100)
    }

    private static func redactLabel(_ label: String, maxLen: Int) -> String {
        if maxLen < 2 { return String(label.prefix(maxLen)) }
        return pad("█" + String(label.dropFirst()), maxLen)
    }

    private static func sourceSummaryTagLine(_ distribution: [SignalSource: Int]) -> String {
        distribution
            .filter { $0.value > 0 }
            .sorted { a, b in
                if a.key.rawValue == b.key.rawValue { return a.value > b.value }
                return a.key.rawValue < b.key.rawValue
            }
            .map { "\($0.key.rawValue):\($0.value)" }
            .joined(separator: ", ")
    }

    static func list(_ devices: [ClassicDevice], redact: Bool = false) {
        guard !devices.isEmpty else {
            print("No paired Bluetooth devices found.")
            return
        }
        print(pad("NAME", 26) + pad("ADDRESS", 20) + pad("RSSI", 7) + "STATE")
        for d in devices {
            print(pad(d.name, 26) + pad(redact ? maskedAddress : d.address, 20)
                  + pad(d.rssi.map(String.init) ?? "-", 7)
                  + (d.connected ? "connected" : "not connected"))
        }
        print("\nTrack one with:  findphone <name>")
    }
}

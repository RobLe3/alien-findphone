import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let clearScreen = "\u{1B}[0m\u{1B}[2J\u{1B}[H"
private let margin = "    "

private let huntWidth = 82
private let dBmSuffix = Style.wrap("   dBm", Style.dim)

private let bandTones = [Style.brightGreen, Style.green, Style.yellow, Style.amber, Style.red]
private let sectors = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

private let maskedAddress = "••:••:••:••:••:••"

private let defaultAssetColumn = 22
private let defaultSourceColumn = 24
private let distanceColumn = 7
private let sectorColumn = 4
private let minAssetColumn = 10
private let minSourceColumn = 7
private let meterBarWidth = 52

private let defaultTerminalColumns = 120
private let defaultTerminalRows = 40

private enum HudMode: Int {
    case wide = 0, standard = 1, compact = 2, tiny = 3
}

private enum TinyDensity {
    case normal
    case compact
    case ultra
}

enum Display {
    /// One write per frame; one print per frame avoids line tearing in TTY.
    static func render(_ s: Snapshot, redact: Bool = false, interactive: Bool = false, highlightedIdentity: String? = nil) {
        let (columns, rows) = terminalSize()
        let density = tinyDensity(columns: columns, rows: rows)
        let lines = s.targetName == nil
            ? survey(s, columns: columns, rows: rows, density: density, redact: redact, interactive: interactive, highlightedIdentity: highlightedIdentity)
            : hunt(s, columns: columns, rows: rows, density: density, redact: redact, interactive: interactive, highlightedIdentity: highlightedIdentity)

        let fitted = lines.map { clampLine($0, to: columns) }
        print(clearScreen + fitted.joined(separator: "\n"), terminator: "\n")
        fflush(stdout)
    }

    private static func hunt(
        _ s: Snapshot,
        columns: Int,
        rows: Int,
        density: TinyDensity,
        redact: Bool,
        interactive: Bool,
        highlightedIdentity: String?
    ) -> [String] {
        let mode = hudMode(columns)
        let address = redact ? maskedAddress : (s.address ?? "")
        let status = "\(s.link.rawValue) · \(s.elapsed)s"
        let titleText = "[ALIEN SCAN] TRACK: \(s.targetName ?? "target")"
        let ruleWidth = min(columns, huntWidth)
        let padCount = max(1, ruleWidth - visibleCount(titleText) - status.count)
        let lockState = s.isManualTracking ? Style.wrap(" [LOCKED]", Style.brightGreen) : ""
        let lineRule = Style.wrap(String(repeating: "-", count: ruleWidth), Style.cyan)

        var lines: [String] = [
            Style.wrap(titleText + String(repeating: " ", count: padCount) + status, Style.cyan),
            lineRule,
            "",
            "  target: \(address)\(lockState)",
            ""
        ]

        lines += focusMeterLines(
            focus: s.focusAsset,
            at: s.at,
            readings: s.focusReadings,
            headline: "TRACK",
            isManualTracking: s.isManualTracking,
            columns: columns,
            mode: mode,
            density: density
        )

        if let issue = s.radioIssue {
            lines.append("  \(issue)")
        }

        if let est = s.estimate {
            let estimate = "trilateration: (\(fmt(est.x)), \(fmt(est.y))) conf \(percent(est.confidence)) from \(est.sources) anchors"
            lines.append(Style.wrap("  \(estimate)", Style.dim))
        }

        if let focus = s.focusAsset {
            let distance = formatDistance(estimatedDistanceMeters(from: focus.bestRSSI))
            let sector = sectorTag(for: focus.identity, sources: Set(focus.sources.keys))
            lines.append("  focus: \(distance)m · sector \(sector)")
        }

        lines.append("")
        lines.append(Style.wrap("  nearby high-confidence assets", Style.cyan))

        if s.potentialAssets.isEmpty {
            lines.append("    (none yet, waiting for RSSI convergence)")
        } else {
            let shown = s.potentialAssets.prefix(idealTrackRows(rows: rows, columns: columns, mode: mode, density: density))
            for (i, asset) in shown.enumerated() {
                lines.append(assetLine(
                    i: i,
                    asset: asset,
                    now: s.at,
                    redact: redact,
                    isHighlighted: interactive && asset.identity == highlightedIdentity,
                    columns: columns,
                    mode: mode,
                    density: density
                ))
            }
        }

        lines.append("")
        lines.append(huntFooter(interactive: interactive, mode: mode, density: density, columns: columns))
        return lines
    }

    private static func survey(
        _ s: Snapshot,
        columns: Int,
        rows: Int,
        density: TinyDensity,
        redact: Bool,
        interactive: Bool,
        highlightedIdentity: String?
    ) -> [String] {
        let mode = hudMode(columns)
        let ruleWidth = min(columns, 88)
        let lineRule = String(repeating: "-", count: ruleWidth)

        var lines = [
            Style.wrap("[ALIEN SCANNER] MULTI-SOURCE SURVEY", Style.cyan),
            Style.wrap("Live assets: \(s.deviceCount) · potential: \(s.potentialAssets.count) · elapsed \(s.elapsed)s", Style.dim),
            lineRule,
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
        lines += focusMeterLines(
            focus: s.focusAsset,
            at: s.at,
            readings: s.focusReadings,
            headline: "FOCUS",
            isManualTracking: s.isManualTracking,
            columns: columns,
            mode: mode,
            density: density
        )

        lines.append("")
        lines.append(Style.wrap("  top candidates", Style.cyan))
        lines.append(topCandidateHeader(columns: columns, mode: mode, density: density))

        guard !s.assets.isEmpty else {
            lines.append("  (nothing yet — give it a few seconds)")
            lines.append("")
            lines.append(interactive ? huntFooter(interactive: interactive, mode: mode, density: density, columns: columns) : "Ctrl-C to stop.")
            return lines
        }

        let shown = s.potentialAssets.isEmpty ? s.assets.prefix(16) : s.potentialAssets.prefix(16)
        let limit = idealCandidateRows(rows: rows, columns: columns, mode: mode, density: density)
        let visibleRows = Array(shown.prefix(limit))
        for (i, asset) in visibleRows.enumerated() {
            lines.append(assetLine(
                i: i,
                asset: asset,
                now: s.at,
                redact: redact,
                isHighlighted: interactive && asset.identity == highlightedIdentity,
                columns: columns,
                mode: mode,
                density: density
            ))
        }
        lines.append("")
        lines.append(huntFooter(interactive: interactive, mode: mode, density: density, columns: columns))
        return lines
    }

    private static func focusMeterLines(focus: TrackedAsset?, at: Date,
                                      readings: [Reading], headline: String,
                                      isManualTracking: Bool,
                                      columns: Int,
                                      mode: HudMode,
                                      density: TinyDensity) -> [String] {
        let rangeWidth = mode == .tiny ? max(10, min(32, columns - 20)) : max(12, min(40, columns - 20))
        let barWidth = mode == .tiny ? max(12, min(26, columns - 30)) : max(20, min(meterBarWidth, columns - 30))
        let sparkSamples = mode == .tiny ? max(8, min(24, columns - 15)) : max(12, min(44, columns - 15))

        var out: [String] = [Style.wrap("  \(headline) METER", Style.cyan)]
        if isManualTracking {
            out.append(Style.wrap("  status: locked to selected target", Style.green))
        }

        guard let focus = focus else {
            out.append("  waiting for a stable asset…")
            return out + [""]
        }

        let sourceTags = focus.sources.keys.map(\.rawValue).sorted().joined(separator: ",")
        let conf = percent(focus.confidence(now: at))
        let age = Int(at.timeIntervalSince(focus.last).rounded())
        let stale = age > 7 ? Style.wrap("  stale", Style.amber) : ""
        let distance = formatDistance(estimatedDistanceMeters(from: focus.bestRSSI))
        let sector = sectorTag(for: focus.identity, sources: Set(focus.sources.keys))
        out.append("  \(focus.label) · \(sourceTags) · conf \(conf)")
        out.append("  dist \(distance)m · sector \(sector) · age \(age)s\(stale)")

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
            Style.wrap("\(margin)sectors: \(sectorDial(active: sectorIndex(for: focus.identity)))", Style.dim),
            Style.wrap("\(margin)compass: \(sectorCompass(active: sectorIndex(for: focus.identity)))", Style.dim),
            "\(margin)range:   \(distanceNeedle(estimatedDistanceMeters(from: focus.bestRSSI), width: rangeWidth))",
            "",
            margin + Style.wrap(bar(live, width: barWidth, fill: "█", empty: "░"), tone),
            "",
            margin + Style.wrap(sparkline(sampleHistory.suffix(sparkSamples)), Style.dim),
            Style.wrap("\(margin)spark · via \(last.source) · refreshed \(ageText)s ago", Style.dim),
            Style.wrap("\(margin)peak/min \(peakText) · asset \(focus.bestRSSI) dBm", Style.dim),
            ""
        ]

        if mode == .tiny {
            out = Array(out.prefix(tinyMeterLines(density: density)))
            out.append("")
        }

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

    private static func sectorIndex(for identity: String) -> Int {
        let sum = identity.utf8.reduce(0) { acc, b in acc + Int(b) }
        return sectors.isEmpty ? 0 : sum % sectors.count
    }

    private static func sectorCompass(active: Int) -> String {
        guard !sectors.isEmpty else { return "--" }
        return sectors.indices.map { idx in
            if idx == active % sectors.count {
                return "[\(sectors[idx])]"
            }
            return " \(sectors[idx]) "
        }.joined(separator: " ")
    }

    private static func distanceNeedle(_ distance: Double, width: Int = 30) -> String {
        let maxMeters = 12.0
        let clamped = max(0.0, min(maxMeters, distance))
        let fill = Int((1.0 - (clamped / maxMeters)) * Double(width))
        let empty = max(0, width - fill)
        return String(repeating: "█", count: fill) + String(repeating: "░", count: empty)
    }

    private static func sectorTag(for identity: String, sources: Set<SignalSource>) -> String {
        guard !sectors.isEmpty else { return "--" }
        if !sources.isEmpty {
            let sourceBias = sources.map(\.rawValue).joined(separator: "+")
            return sectors[sectorIndex(for: "\(identity)|\(sourceBias)")]
        }
        return sectors[sectorIndex(for: identity)]
    }

    private static func sectorDial(active: Int) -> String {
        guard !sectors.isEmpty else { return "--" }
        let fixed = sectors.enumerated().map { idx, value in
            idx == active % sectors.count ? "[\(value)]" : " \(value) "
        }
        return fixed.joined(separator: " ")
    }

    private static func topCandidateHeader(columns: Int, mode: HudMode, density: TinyDensity) -> String {
        switch mode {
        case .wide, .standard:
            let cols = assetColumns(columns: columns)
            return "  #  \(fit("label", cols.labelWidth, alignment: .left)) " +
                "\(fit("src", cols.sourceWidth, alignment: .left)) " +
                "\(fit("rssi", cols.rssiWidth, alignment: .right)) " +
                "\(fit("conf", cols.confWidth, alignment: .right)) " +
                "\(fit("dist", cols.distWidth, alignment: .right)) " +
                "\(fit("sect", cols.sectorWidth, alignment: .right)) age"
        case .compact:
            return "  #  \(fit("label", 18, alignment: .left)) \(fit("rssi", 6, alignment: .right)) \(fit("dist", 7, alignment: .right)) \(fit("sect", 3, alignment: .right)) age"
        case .tiny:
            let cols = tinyColumns(columns: columns, density: density)
            return "  #  \(fit("label", cols.labelWidth, alignment: .left)) " +
                "\(fit("rssi", cols.rssiWidth, alignment: .right)) " +
                "\(fit(cols.ageLabel, cols.ageWidth, alignment: .right))"
        }
    }

    private static func assetLine(
        i: Int,
        asset: TrackedAsset,
        now: Date,
        redact: Bool,
        isHighlighted: Bool,
        columns: Int,
        mode: HudMode,
        density: TinyDensity
    ) -> String {
        let marker = isHighlighted ? ">" : " "
        let conf = percent(asset.confidence(now: now))
        let distance = formatDistance(estimatedDistanceMeters(from: asset.bestRSSI))
        let sector = sectorTag(for: asset.identity, sources: Set(asset.sources.keys))
        let age = Int(now.timeIntervalSince(asset.last).rounded())
        let stale = now.timeIntervalSince(asset.last) > 7
        let ageText = "\(age)s" + (stale ? " stale" : "")

        switch mode {
        case .wide, .standard:
            let cols = assetColumns(columns: columns)
            let label = redact ? redactLabel(asset.label, maxLen: cols.labelWidth) : fit(asset.label, cols.labelWidth, alignment: .left)
            let sources = asset.sources.keys
                .map(\.rawValue)
                .sorted()
                .joined(separator: ",")
            let sourceText = fit(String(sources), cols.sourceWidth, alignment: .left)

            return "  \(marker) \(fit(String(i + 1), 2)). \(label) \(sourceText) " +
                " \(fit(String(asset.bestRSSI), cols.rssiWidth, alignment: .right)) " +
                "\(fit(conf, cols.confWidth, alignment: .right)) " +
                "\(fit("\(distance)m", cols.distWidth, alignment: .right)) " +
                "\(fit(sector, cols.sectorWidth, alignment: .right)) \(ageText)"

        case .compact:
            let label = redact ? redactLabel(asset.label, maxLen: 18) : fit(asset.label, 18, alignment: .left)
            return "  \(marker) \(fit(String(i + 1), 2)). \(label) " +
                "\(fit(String(asset.bestRSSI), 6, alignment: .right)) " +
                "\(fit("\(distance)m", 7, alignment: .right)) " +
                "\(fit(sector, 3, alignment: .right)) \(ageText)"

        case .tiny:
            let cols = tinyColumns(columns: columns, density: density)
            let label = redact ? redactLabel(asset.label, maxLen: cols.labelWidth) : fit(asset.label, cols.labelWidth, alignment: .left)
            return "  \(marker) \(fit(String(i + 1), 2)). \(label) " +
                "\(fit(String(asset.bestRSSI), cols.rssiWidth, alignment: .right)) " +
                "\(fit(tinyAgeText(age, stale: stale, density: density), cols.ageWidth, alignment: .right))"
        }
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    private static func percent(_ v: Double) -> String {
        String(format: "%3.0f%%", v * 100)
    }

    private static func redactLabel(_ label: String, maxLen: Int) -> String {
        if maxLen < 2 { return String(label.prefix(maxLen)) }
        return fit("█" + String(label.dropFirst()), maxLen)
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

    private static func huntFooter(interactive: Bool, mode: HudMode, density: TinyDensity, columns: Int) -> String {
        guard interactive else {
            return "q or Ctrl-C to stop."
        }

        switch mode {
        case .wide, .standard:
            return menuLine(
                options: [
                    "  MENU: up(k) / down(j), enter lock, c clear, q/ Ctrl-C to stop",
                    "  MENU: k/j move, enter lock, c clear, q/ Ctrl-C to stop",
                    "  MENU: [U][D]=move, [E]=lock, [C]=clear, [Q]=quit",
                    menuSymbols(columns: columns, compact: true, density: density)
                ],
                columns: columns
            )
        case .compact:
            return menuLine(
                options: [
                    "  MENU: k/j move, enter lock, c clear, q/ Ctrl-C to stop",
                    "  MENU: [U][D] [E] [C] [Q]",
                    menuSymbols(columns: columns, compact: true, density: density)
                ],
                columns: columns
            )
        case .tiny:
            return menuSymbols(columns: columns, compact: true, density: density)
        }
    }

    private static func menuLine(options: [String], columns: Int) -> String {
        return options.first { $0.count <= columns } ?? options.last!
    }

    private static func menuSymbols(columns: Int, compact: Bool, density: TinyDensity) -> String {
        if compact {
            let compactSymbols = [
                "[U][D] [E] [C] [Q]",
                "[U][D][E][C][Q]",
                " U  D  E  C  Q ",
                "U D E C Q",
                "U D E Q",
                "U Q"
            ]
            return compactSymbols.first(where: { $0.count <= columns }) ?? compactSymbols.last!
        }

        let normalSymbols = [
            "  [U]=up [D]=down [E]=lock [C]=clear [Q]=quit",
            "  [U][D] [E] [C] [Q]",
            "[U][D][E][C][Q]",
            " U  D  E  C  Q ",
            "U D E C Q",
            "U D E Q",
            "U Q"
        ]
        let compactSymbols = [
            "[U][D] [E] [C] [Q]",
            "[U][D][E][C][Q]",
            " U  D  E  C  Q ",
            "U D E C Q",
            "U D E Q",
            "U Q"
        ]

        switch density {
        case .normal:
            return menuLine(options: normalSymbols, columns: columns)
        case .compact:
            return menuLine(options: compactSymbols, columns: columns)
        case .ultra:
            return menuLine(options: ["[U][D] [E] [C] [Q]", "[U][D][E][C][Q]", "U/D E C Q", "U D Q", "UQ"], columns: columns)
        }
    }

    private static func hudMode(_ columns: Int) -> HudMode {
        if columns >= 96 {
            return .wide
        }
        if columns >= 74 {
            return .standard
        }
        if columns >= 62 {
            return .compact
        }
        return .tiny
    }

    private static func terminalSize() -> (columns: Int, rows: Int) {
        let envCols = Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "") ?? 0
        let envRows = Int(ProcessInfo.processInfo.environment["LINES"] ?? "") ?? 0

        var wins = winsize()
        var width = max(0, envCols)
        var height = max(0, envRows)
        #if canImport(Darwin)
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &wins) == 0, wins.ws_col > 0 {
            width = Int(wins.ws_col)
            height = Int(wins.ws_row)
        }
        #else
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &wins) == 0, wins.ws_col > 0 {
            width = Int(wins.ws_col)
            height = Int(wins.ws_row)
        }
        #endif

        if width == 0 {
            width = defaultTerminalColumns
        }
        if height == 0 {
            height = defaultTerminalRows
        }

        let terminalColumns = max(0, width)
        let terminalRows = max(0, height)

        if terminalColumns > 0 && terminalRows > 0 {
            return (terminalColumns, terminalRows)
        }
        if terminalColumns > 0 {
            return (terminalColumns, 30)
        }
        if terminalRows > 0 {
            return (100, terminalRows)
        }
        return (100, 30)
    }

    private static func idealTrackRows(rows: Int, columns: Int, mode: HudMode, density: TinyDensity) -> Int {
        switch mode {
        case .wide:
            return max(2, min(10, rows - 14))
        case .standard:
            return max(2, min(8, rows - 16))
        case .compact:
            return max(2, min(6, rows - 18))
        case .tiny:
            return tinyTrackRows(rows: rows, density: density)
        }
    }

    private static func idealCandidateRows(rows: Int, columns: Int, mode: HudMode, density: TinyDensity) -> Int {
        switch mode {
        case .wide:
            return max(5, min(16, rows - 22))
        case .standard:
            return max(5, min(14, rows - 24))
        case .compact:
            return max(4, min(12, rows - 25))
        case .tiny:
            return tinyCandidateRows(rows: rows, density: density)
        }
    }

    private static func tinyDensity(columns: Int, rows: Int) -> TinyDensity {
        if columns <= 46 || rows <= 22 {
            return .ultra
        }
        if columns <= 55 || rows <= 25 {
            return .compact
        }
        return .normal
    }

    private static func tinyColumns(columns: Int, density: TinyDensity) -> (labelWidth: Int, rssiWidth: Int, ageWidth: Int, ageLabel: String) {
        let rssiWidth = density == .normal ? 6 : 5
        let ageWidth = density == .normal ? 5 : 4
        let ageLabel = density == .normal ? "age" : "A"
        let minLabel = density == .normal ? 10 : 8
        let fixed = 8 + rssiWidth + 1 + ageWidth
        let labelWidth = columns > fixed ? columns - fixed : minLabel

        return (
            labelWidth: max(minLabel, min(labelWidth, density == .normal ? 14 : 11)),
            rssiWidth: rssiWidth,
            ageWidth: ageWidth,
            ageLabel: ageLabel
        )
    }

    private static func tinyAgeText(_ seconds: Int, stale: Bool, density: TinyDensity) -> String {
        let staleSuffix = stale ? (density == .normal ? "*" : "#") : ""
        return "\(seconds)s\(staleSuffix)"
    }

    private static func tinyMeterLines(density: TinyDensity) -> Int {
        switch density {
        case .normal:
            return 8
        case .compact:
            return 7
        case .ultra:
            return 6
        }
    }

    private static func tinyTrackRows(rows: Int, density: TinyDensity) -> Int {
        let maxRows = density == .normal ? 3 : (density == .compact ? 2 : 1)
        let base = density == .normal ? 16 : (density == .compact ? 17 : 19)
        let available = max(0, rows - base)
        return max(1, min(maxRows, available))
    }

    private static func tinyCandidateRows(rows: Int, density: TinyDensity) -> Int {
        let maxRows = density == .normal ? 8 : (density == .compact ? 6 : 4)
        let base = density == .normal ? 18 : (density == .compact ? 20 : 22)
        let available = max(0, rows - base)
        return max(1, min(maxRows, available))
    }

    private struct AssetColumnPlan {
        let labelWidth: Int
        let sourceWidth: Int
        let rssiWidth: Int
        let confWidth: Int
        let distWidth: Int
        let sectorWidth: Int
    }

    private static func assetColumns(columns: Int) -> AssetColumnPlan {
        let reserved = 2 /*prefix and idx*/
            + 1 /*sp*/
            + 1 /*dot*/
            + 1 /*space after index*/
            + 1 /*separator*/
            + 2 /*rssi gap*/
            + 2 /*conf gap*/
            + 2 /*dist gap*/
            + 2 /*sect gap*/
            + 1 /*stale/age*/
            + 8 /*age column*/

        let minLabel = minAssetColumn
        let minSource = minSourceColumn
        let dynamic = max(0, columns - reserved - 6 - 6 - distanceColumn - sectorColumn)
        let targetLabel = max(minLabel, min(defaultAssetColumn, dynamic * 5 / 8))
        let targetSource = max(minSource, dynamic - targetLabel)

        return AssetColumnPlan(
            labelWidth: targetLabel,
            sourceWidth: targetSource,
            rssiWidth: 6,
            confWidth: 6,
            distWidth: distanceColumn,
            sectorWidth: sectorColumn
        )
    }

    private enum Align {
        case left, right
    }

    private static func fit(_ value: String, _ width: Int, alignment: Align = .left) -> String {
        if width <= 0 { return "" }
        let truncated = value.count > width ? String(value.prefix(width)) : value
        switch alignment {
        case .left:
            return truncated.padding(toLength: width, withPad: " ", startingAt: 0)
        case .right:
            return String(repeating: " ", count: max(0, width - truncated.count)) + truncated
        }
    }

    private static func visibleCount(_ value: String) -> Int {
        var count = 0
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "\u{1B}" {
                let next = value.index(after: index)
                if next < value.endIndex && value[next] == "[" {
                    var end = next
                    while end < value.endIndex && value[end] != "m" {
                        end = value.index(after: end)
                    }
                    if end < value.endIndex {
                        index = value.index(after: end)
                        continue
                    }
                }
            }
            count += 1
            index = value.index(after: index)
        }
        return count
    }

    private static func clampLine(_ text: String, to columns: Int) -> String {
        if columns <= 0 { return "" }
        var out = ""
        var visible = 0
        var index = text.startIndex
        var styleOpen = false

        while index < text.endIndex && visible < columns {
            let char = text[index]
            if char == "\u{1B}" {
                let next = text.index(after: index)
                if next < text.endIndex && text[next] == "[" {
                    var end = next
                    while end < text.endIndex && text[end] != "m" {
                        end = text.index(after: end)
                    }
                    if end < text.endIndex {
                        let sequence = text[index...end]
                        out += sequence
                        let payload = String(text[text.index(after: next)..<end])
                        if shouldResetStyle(payload) {
                            styleOpen = false
                        } else {
                            styleOpen = true
                        }
                        index = text.index(after: end)
                        continue
                    }
                }
            }

            out.append(char)
            visible += 1
            index = text.index(after: index)
        }

        if styleOpen {
            out += "\u{1B}[0m"
        }
        return out
    }

    private static func shouldResetStyle(_ payload: String) -> Bool {
        let codes = payload
            .split(separator: ";")
            .compactMap { Int($0) }

        guard !codes.isEmpty else { return false }
        return codes.contains(0) || codes.contains(39) || codes.contains(49)
    }
}

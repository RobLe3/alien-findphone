import Foundation

struct RSSIHistoryGraph {
    static let defaultWindow: TimeInterval = 30
    static let defaultMinimumRSSI = -100
    static let defaultMaximumRSSI = -40
    static let defaultPlotHeight = 5

    static let asciiGraphCharacters: Set<Character> = Set(" .:-+/\\@|")

    static func render(
        readings: [Reading],
        now: Date,
        currentRSSI: Int,
        plotWidth: Int,
        plotHeight: Int = defaultPlotHeight,
        window: TimeInterval = defaultWindow
    ) -> [String] {
        guard plotWidth > 0, plotHeight > 1 else {
            return []
        }

        let medians = bucketedMedians(
            readings: readings,
            now: now,
            currentRSSI: currentRSSI,
            plotWidth: plotWidth,
            window: max(window, 0.001)
        )

        guard !medians.allSatisfy({ $0 == nil }) else {
            return emptyHistoryRows(plotWidth: plotWidth, plotHeight: plotHeight)
        }

        let labelWidth = axisLabelWidth(plotHeight: plotHeight)
        let emptyRow = Array(repeating: Character(" "), count: plotWidth)
        var canvas = Array(repeating: emptyRow, count: plotHeight)
        var pointRows = Array(repeating: Optional<Int>.none, count: plotWidth)

        for column in 0..<plotWidth {
            if let value = medians[column] {
                pointRows[column] = graphRow(
                    for: value,
                    minimumRSSI: defaultMinimumRSSI,
                    maximumRSSI: defaultMaximumRSSI,
                    height: plotHeight
                )
            }
        }

        for column in 0..<plotWidth {
            guard let row = pointRows[column] else { continue }

            let marker = (column == plotWidth - 1) ? "@" : "*"
            canvas[row][column] = Character(marker)

            guard column > 0,
                  let previousRow = pointRows[column - 1] else {
                continue
            }

            let previousColumn = column - 1
            if previousColumn < 0 { continue }

            let delta = row - previousRow
            let connectorColumn = previousColumn
            let connector: Character

            if delta == 0 {
                connector = "-"
            } else if delta < 0 {
                connector = "/"
            } else {
                connector = "\\"
            }

            if abs(delta) > 1 {
                let centerRow = max(0, min(plotHeight - 1, previousRow))
                canvas[centerRow][connectorColumn] = "|"
            } else {
                canvas[previousRow][connectorColumn] = connector
            }
        }

        return canvas.enumerated().map { index, line in
            let label = axisLabel(for: index, plotHeight: plotHeight)
            return label.padding(toLength: labelWidth, withPad: " ", startingAt: 0) + String(line)
        }
    }

    static func asciiSparkline(
        _ readings: ArraySlice<Reading>,
        width: Int,
        now: Date = Date(),
        currentRSSI: Int,
        window: TimeInterval = defaultWindow
    ) -> String {
        guard width > 0 else { return "" }

        let medians = bucketedMedians(
            readings: Array(readings),
            now: now,
            currentRSSI: currentRSSI,
            plotWidth: width,
            window: max(window, 0.001)
        )

        let ramp = Array(" .:-+*#%@")

        let mapped = medians.enumerated().map { index, value in
            guard let value else {
                return " "
            }

            let clamped = min(defaultMaximumRSSI, max(defaultMinimumRSSI, value))
            let ratio = Double(clamped - defaultMinimumRSSI) / Double(defaultMaximumRSSI - defaultMinimumRSSI)
            let valueIndex = Int((ratio * Double(ramp.count - 1)).rounded())
            let safe = max(0, min(ramp.count - 1, valueIndex))
            return String(ramp[safe])
        }

        if mapped.isEmpty {
            return ""
        }

        var output = mapped
        output[output.count - 1] = "@"
        return output.joined()
    }

    static func graphRow(
        for rssi: Int,
        minimumRSSI: Int = defaultMinimumRSSI,
        maximumRSSI: Int = defaultMaximumRSSI,
        height: Int
    ) -> Int {
        guard height > 1 else { return 0 }

        let clamped = max(minimumRSSI, min(maximumRSSI, rssi))
        let span = maximumRSSI - minimumRSSI
        guard span != 0 else { return 0 }

        let ratio = Double(clamped - minimumRSSI) / Double(span)
        let row = Int(((Double(height - 1) * (1.0 - ratio)).rounded()))
        return max(0, min(height - 1, row))
    }

    static func axisLabel(for row: Int, plotHeight: Int) -> String {
        guard plotHeight > 1 else { return "" }
        let midpoint = (defaultMinimumRSSI + defaultMaximumRSSI) / 2
        if row == 0 {
            return "\(defaultMaximumRSSI) |"
        }
        if row == plotHeight - 1 {
            return "\(defaultMinimumRSSI)+"
        }
        if row == plotHeight / 2 {
            return "\(midpoint) |"
        }
        return ""
    }

    static func axisLabelWidth(plotHeight: Int) -> Int {
        let labels = [
            "\(defaultMaximumRSSI) |",
            "\(defaultMinimumRSSI)+",
            "\((defaultMinimumRSSI + defaultMaximumRSSI) / 2) |",
        ]
        return labels.map { $0.count }.max() ?? 0
    }

    static func timeCaption(for window: TimeInterval, graphWidth: Int) -> String {
        let left = "\(Int(window))s ago"
        let right = "now"

        if graphWidth <= left.count + right.count {
            return left
        }

        let gap = max(1, graphWidth - left.count - right.count)
        return left + String(repeating: " ", count: gap) + right
    }

    static func bucketedMedians(
        readings: [Reading],
        now: Date,
        currentRSSI: Int,
        plotWidth: Int,
        window: TimeInterval
    ) -> [Int?] {
        guard plotWidth > 0 else { return [] }

        let tolerance = 0.001
        let bucketSpan = window / Double(plotWidth)
        let nowTime = now.timeIntervalSinceReferenceDate
        var buckets = Array(repeating: [Int](), count: plotWidth)

        for reading in readings {
            let age = nowTime - reading.at.timeIntervalSinceReferenceDate
            guard age >= -tolerance, age <= window + tolerance else {
                continue
            }

            let position = max(0.0, window - age)
            let rawIndex = Int(floor(position / bucketSpan))
            let index = min(plotWidth - 1, max(0, rawIndex))
            buckets[index].append(reading.rssi)
        }

        buckets[plotWidth - 1].append(currentRSSI)

        return buckets.map { bucket in
            guard !bucket.isEmpty else { return nil }
            let sorted = bucket.sorted()
            return sorted[sorted.count / 2]
        }
    }

    private static func emptyHistoryRows(plotWidth: Int, plotHeight: Int) -> [String] {
        let labelWidth = axisLabelWidth(plotHeight: plotHeight)
        let message = "no recent signal history"
        let mid = plotHeight / 2

        return (0..<plotHeight).map { row in
            let label = axisLabel(for: row, plotHeight: plotHeight)
                .padding(toLength: labelWidth, withPad: " ", startingAt: 0)

            var plot = String(repeating: " ", count: plotWidth)
            if row == mid {
                let text = String(message.prefix(plotWidth))
                let start = max(0, (plotWidth - text.count) / 2)
                let end = min(plotWidth, start + text.count)
                plot.replaceSubrange(
                    plot.index(plot.startIndex, offsetBy: start)..<plot.index(plot.startIndex, offsetBy: end),
                    with: text
                )
            }
            return label + plot
        }
    }
}

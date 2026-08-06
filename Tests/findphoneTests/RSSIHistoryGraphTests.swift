#if canImport(Darwin) && canImport(XCTest)
import Foundation
import XCTest

@testable import findphone

final class RSSIHistoryGraphTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testEmptyHistoryHasNoInventedPoints() {
        let rows = RSSIHistoryGraph.render(
            readings: [],
            now: now,
            currentRSSI: -82,
            plotWidth: 20,
            plotHeight: 5,
            window: 0.001
        )

        XCTAssertEqual(rows.count, 5)

        let plot = graphArea(from: rows, plotWidth: 20)
        let flattened = plot.flatMap { $0 }
        let stars = flattened.filter { $0 == "*" }
        XCTAssertEqual(stars.count, 0)
        XCTAssertEqual(flattened.filter { $0 == "@" }.count, 1)
    }

    func testFixedDimensionsAreHonored() {
        let data: [(Int, Int)] = [(12, 3), (24, 5), (40, 5)]

        for (width, height) in data {
            let rows = RSSIHistoryGraph.render(
                readings: [sample(-70, age: 0)],
                now: now,
                currentRSSI: -70,
                plotWidth: width,
                plotHeight: height,
                window: 30
            )

            XCTAssertEqual(rows.count, height)

            let expected = RSSIHistoryGraph.axisLabelWidth(plotHeight: height) + width
            for row in rows {
                XCTAssertLessThanOrEqual(stripAnsi(row).count, expected)
            }
        }
    }

    func testGraphRowMapsStrongestSignalToTopRow() {
        XCTAssertEqual(
            RSSIHistoryGraph.graphRow(
                for: -40,
                minimumRSSI: RSSIHistoryGraph.defaultMinimumRSSI,
                maximumRSSI: RSSIHistoryGraph.defaultMaximumRSSI,
                height: RSSIHistoryGraph.defaultPlotHeight
            ),
            0
        )
    }

    func testGraphRowMapsWeakestSignalToBottomRow() {
        XCTAssertEqual(
            RSSIHistoryGraph.graphRow(
                for: -100,
                minimumRSSI: RSSIHistoryGraph.defaultMinimumRSSI,
                maximumRSSI: RSSIHistoryGraph.defaultMaximumRSSI,
                height: RSSIHistoryGraph.defaultPlotHeight
            ),
            4
        )
    }

    func testGraphRowMapsMidpointToCenter() {
        XCTAssertEqual(
            RSSIHistoryGraph.graphRow(
                for: -70,
                minimumRSSI: RSSIHistoryGraph.defaultMinimumRSSI,
                maximumRSSI: RSSIHistoryGraph.defaultMaximumRSSI,
                height: RSSIHistoryGraph.defaultPlotHeight
            ),
            2
        )
    }

    func testGraphRowClampsOutsideScale() {
        XCTAssertEqual(
            RSSIHistoryGraph.graphRow(
                for: -20,
                minimumRSSI: RSSIHistoryGraph.defaultMinimumRSSI,
                maximumRSSI: RSSIHistoryGraph.defaultMaximumRSSI,
                height: RSSIHistoryGraph.defaultPlotHeight
            ),
            0
        )

        XCTAssertEqual(
            RSSIHistoryGraph.graphRow(
                for: -120,
                minimumRSSI: RSSIHistoryGraph.defaultMinimumRSSI,
                maximumRSSI: RSSIHistoryGraph.defaultMaximumRSSI,
                height: RSSIHistoryGraph.defaultPlotHeight
            ),
            4
        )
    }

    func testChronologicalDirectionPreservesTimeOrder() {
        let readings: [Reading] = [
            sample(-90, age: 29),
            sample(-80, age: 1),
        ]

        let medians = RSSIHistoryGraph.bucketedMedians(
            readings: readings,
            now: now,
            currentRSSI: -80,
            plotWidth: 20,
            window: 30
        )

        let occupied = medians.enumerated().compactMap { bucket -> Int? in
            bucket.element == nil ? nil : bucket.offset
        }

        XCTAssertGreaterThanOrEqual(occupied.count, 2)
        XCTAssertEqual(occupied, occupied.sorted())
        XCTAssertLessThan(occupied.first ?? 0, occupied.last ?? 0)
    }

    func testCurrentValueIsRightmostMarker() {
        let rows = RSSIHistoryGraph.render(
            readings: [
                sample(-90, age: 10),
                sample(-88, age: 6),
                sample(-86, age: 2),
            ],
            now: now,
            currentRSSI: -82,
            plotWidth: 12,
            plotHeight: 5,
            window: 30
        )

        let plot = graphArea(from: rows, plotWidth: 12)
        var markerColumn: Int?
        var markerRow: Int?

        for row in 0..<plot.count {
            if let col = plot[row].firstIndex(of: "@") {
                markerColumn = col
                markerRow = row
                break
            }
        }

        XCTAssertNotNil(markerColumn)
        XCTAssertEqual(markerColumn, 11)

        if let markerRow {
            XCTAssertEqual(
                markerRow,
                RSSIHistoryGraph.graphRow(
                    for: -82,
                    minimumRSSI: RSSIHistoryGraph.defaultMinimumRSSI,
                    maximumRSSI: RSSIHistoryGraph.defaultMaximumRSSI,
                    height: 5
                )
            )
        }
    }

    func testTimeBucketingUsesMedianWithinBucket() {
        let readings: [Reading] = [
            sample(-90, age: 15),
            sample(-80, age: 15),
            sample(-70, age: 15),
        ]

        let medians = RSSIHistoryGraph.bucketedMedians(
            readings: readings,
            now: now,
            currentRSSI: -70,
            plotWidth: 30,
            window: 30
        )

        let rowIndex = 15
        let expectedMedian = median([-90, -80, -70])
        XCTAssertEqual(medians[rowIndex], expectedMedian)
    }

    func testIrregularSamplingBucketPositions() {
        let readings: [Reading] = [
            sample(-90, age: 18), sample(-84, age: 18), sample(-82, age: 18),
            sample(-66, age: 3), sample(-68, age: 2.8), sample(-70, age: 2.6), sample(-71, age: 2.4),
            sample(-72, age: 2.2),
        ]

        let medians = RSSIHistoryGraph.bucketedMedians(
            readings: readings,
            now: now,
            currentRSSI: -72,
            plotWidth: 20,
            window: 20
        )

        let occupied = medians.enumerated().compactMap { $0.element == nil ? nil : $0.offset }
        XCTAssertEqual(occupied, occupied.sorted())
        XCTAssertLessThanOrEqual(occupied.count, 3)
    }

    func testMissingHistoryGapsDoNotCreateConnector() {
        let rows = RSSIHistoryGraph.render(
            readings: [
                sample(-65, age: 29),
                sample(-67, age: 10),
            ],
            now: now,
            currentRSSI: -67,
            plotWidth: 12,
            plotHeight: 5,
            window: 30
        )

        let plot = graphArea(from: rows, plotWidth: 12)
        let columns = (0..<12).filter { col in
            plot.contains { $0[col] != " " }
        }

        XCTAssertEqual(columns.first, 0)
        XCTAssertEqual(columns.last, 11)
        XCTAssertTrue((columns.dropFirst().dropLast()).contains(where: { $0 > 1 }))

        // Ensure there is at least one interior column with no visible plotting data.
        var foundEmpty = false
        for col in 1..<11 {
            if plot.allSatisfy({ $0[col] == " " }) {
                foundEmpty = true
                break
            }
        }
        XCTAssertTrue(foundEmpty)
    }

    func testConstantSignalRendersFlat() {
        let readings = stride(from: 0, through: 20, by: 2).map { age in
            sample(-70, age: TimeInterval(age))
        }

        let medians = RSSIHistoryGraph.bucketedMedians(
            readings: readings,
            now: now,
            currentRSSI: -70,
            plotWidth: 20,
            window: 30
        )

        let rows = medians.compactMap { row in
            row.map {
                RSSIHistoryGraph.graphRow(
                    for: $0,
                    minimumRSSI: RSSIHistoryGraph.defaultMinimumRSSI,
                    maximumRSSI: RSSIHistoryGraph.defaultMaximumRSSI,
                    height: RSSIHistoryGraph.defaultPlotHeight
                )
            }
        }

        XCTAssertEqual(Set(rows).count, 1)
    }

    func testRisingSequenceRendersUpward() {
        let medians = RSSIHistoryGraph.bucketedMedians(
            readings: [
                sample(-90, age: 20),
                sample(-85, age: 16),
                sample(-80, age: 12),
                sample(-75, age: 8),
                sample(-70, age: 4),
                sample(-65, age: 0),
            ],
            now: now,
            currentRSSI: -65,
            plotWidth: 20,
            window: 20
        )

        let rows = medians.compactMap { row in
            row.map {
                RSSIHistoryGraph.graphRow(
                    for: $0,
                    minimumRSSI: RSSIHistoryGraph.defaultMinimumRSSI,
                    maximumRSSI: RSSIHistoryGraph.defaultMaximumRSSI,
                    height: RSSIHistoryGraph.defaultPlotHeight
                )
            }
        }

        for pair in zip(rows.dropLast(), rows.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0, pair.1)
        }
    }

    func testFallingSequenceRendersDownward() {
        let medians = RSSIHistoryGraph.bucketedMedians(
            readings: [
                sample(-65, age: 20),
                sample(-70, age: 16),
                sample(-75, age: 12),
                sample(-80, age: 8),
                sample(-85, age: 4),
                sample(-90, age: 0),
            ],
            now: now,
            currentRSSI: -90,
            plotWidth: 20,
            window: 20
        )

        let rows = medians.compactMap { row in
            row.map {
                RSSIHistoryGraph.graphRow(
                    for: $0,
                    minimumRSSI: RSSIHistoryGraph.defaultMinimumRSSI,
                    maximumRSSI: RSSIHistoryGraph.defaultMaximumRSSI,
                    height: RSSIHistoryGraph.defaultPlotHeight
                )
            }
        }

        for pair in zip(rows.dropLast(), rows.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0, pair.1)
        }
    }

    func testAsciiOnlyGraphOutput() {
        let rows = RSSIHistoryGraph.render(
            readings: [sample(-80, age: 0), sample(-78, age: 1), sample(-76, age: 2)],
            now: now,
            currentRSSI: -74,
            plotWidth: 16,
            plotHeight: 5,
            window: 30
        )

        let allowed: Set<Character> = Set(" .:/\\|+*-@")

        let plot = rows.flatMap { graphArea(from: [$0], plotWidth: 16)[0] }
        XCTAssertTrue(plot.allSatisfy { allowed.contains($0) })
    }

    func testWideModeUsesSideBySideGraphLayout() {
        let snapshot = makeSnapshot(
            live: -72,
            focusReadings: [sample(-72, age: 1), sample(-73, age: 2), sample(-70, age: 5)]
        )

        let lines = Display.renderLines(snapshot, columns: 120, rows: 40)
        let dBmLines = lines.filter { stripAnsi($0).contains("dBm") }
        XCTAssertFalse(dBmLines.isEmpty)

        let signalLine = dBmLines.first(where: { $0.contains("@") })
        XCTAssertNotNil(signalLine)
        if let signalLine {
            let plain = stripAnsi(signalLine)
            XCTAssertTrue(plain.contains("@"))
            XCTAssertFalse(plain.contains("hist:"))
            XCTAssertTrue(plain.contains("dBm"))
            XCTAssertTrue(plain.count <= 120)
        }

        XCTAssertFalse(lines.contains { stripAnsi($0).contains("hist:") })
    }

    func testStandardModeUsesSideBySideHistoryLayout() {
        let snapshot = makeSnapshot(
            live: -72,
            focusReadings: [sample(-72, age: 1), sample(-73, age: 2), sample(-70, age: 5)]
        )

        let lines = Display.renderLines(snapshot, columns: 74, rows: 40)
        let meterLine = lines.first { stripAnsi($0).contains("@") }
        XCTAssertNotNil(meterLine)
        if let meterLine {
            XCTAssertFalse(stripAnsi(meterLine).contains("hist:"))
            XCTAssertTrue(stripAnsi(meterLine).contains("dBm"))
        }
        XCTAssertTrue(lines.contains { stripAnsi($0).contains("-40") || stripAnsi($0).contains("-100") })
    }

    func testTinyModePreservesLineWidth() {
        let snapshot = makeSnapshot(
            live: -72,
            focusReadings: [sample(-72, age: 1), sample(-73, age: 2), sample(-70, age: 5)]
        )

        let lines = Display.renderLines(snapshot, columns: 56, rows: 20)
        let overflow = lines.enumerated().compactMap { index, line -> String? in
            let plain = stripAnsi(line)
            return plain.count > 56 ? "\(index):\(plain.count):\(plain)" : nil
        }
        if !overflow.isEmpty {
            XCTFail("overflowing lines: \(overflow.joined(separator: "; "))")
        }
        if !lines.contains(where: { stripAnsi($0).contains("dBm") }) {
            XCTFail("No line with dBm marker")
        }
    }

    func testGraphLineDoesNotOverflowColumns() {
        let snapshot = makeSnapshot(
            live: -72,
            focusReadings: [sample(-72, age: 1), sample(-73, age: 2), sample(-70, age: 5)]
        )

        for width in [120, 96, 80, 74, 68, 62, 56, 46] {
            let lines = Display.renderLines(snapshot, columns: width, rows: 30)
            for line in lines {
                XCTAssertLessThanOrEqual(visibleLength(stripAnsi(line)), width)
            }
        }
    }

    // MARK: - Helpers

    private func sample(_ rssi: Int, age: TimeInterval) -> Reading {
        Reading(rssi: rssi, at: now.addingTimeInterval(-age), source: SignalSource.bleAdvert.rawValue)
    }

    private func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func graphArea(from rows: [String], plotWidth: Int) -> [[Character]] {
        return rows.map { row in
            let plain = stripAnsi(row)
            let graphPart = plain.suffix(plotWidth)
            return Array(graphPart)
        }
    }

    private func stripAnsi(_ value: String) -> String {
        var text = value
        let pattern = #"\u{001B}\[[0-9;]*m"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }
        return text
    }

    private func visibleLength(_ value: String) -> Int {
        value.count
    }

    private func makeSnapshot(live: Int, focusReadings: [Reading]) -> Snapshot {
        let identity = "target-id"
        var focus = TrackedAsset(
            identity: identity,
            label: "Focus Device",
            rssi: live,
            at: now,
            source: .bleAdvert
        )

        focus.record(AssetSignal(
            source: .bleAdvert,
            identity: identity,
            label: focus.label,
            rssi: live,
            at: now
        ))

        return Snapshot(
            targetName: "test",
            address: "AB:CD:EF",
            at: now,
            elapsed: 0,
            readings: focusReadings,
            link: .live,
            radioIssue: nil,
            assets: [focus],
            potentialAssets: [focus],
            sourceDistribution: [.bleAdvert: focusReadings.count],
            deviceCount: 1,
            selectedIdentity: identity,
            isManualTracking: true,
            estimate: nil,
            focusAsset: focus,
            focusReadings: focusReadings
        )
    }
}

#endif

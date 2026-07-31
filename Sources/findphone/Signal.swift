import Foundation

struct Reading {
    let rssi: Int
    let at: Date
    let source: String
}

extension Array where Element == Reading {
    /// Readings are appended in time order, so a window is found by walking
    /// back from the end rather than scanning the whole history.
    func since(_ seconds: TimeInterval, now: Date) -> ArraySlice<Reading> {
        let cutoff = now.addingTimeInterval(-seconds)
        var i = endIndex
        while i > startIndex, self[i - 1].at >= cutoff { i -= 1 }
        return self[i...]
    }
}

extension Sequence where Element == Reading {
    /// Median rather than mean, so one reflected spike cannot yank the display
    /// several metres.
    var medianRSSI: Int? {
        let sorted = map(\.rssi).sorted()
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }

    var peakRSSI: Int? { lazy.map(\.rssi).max() }
}

enum Proximity {
    private static let bands: [(floor: Int, label: String)] = [
        (-45, "ARM'S REACH"),
        (-60, "same table"),
        (-72, "same room"),
        (-85, "far / behind something"),
        (.min, "very far or shielded"),
    ]

    static let labelWidth = bands.map(\.label.count).max() ?? 0

    static func describe(_ rssi: Int) -> String {
        bands.first { rssi >= $0.floor }?.label ?? "unknown"
    }

    /// Fraction of the useful -100..-30 dBm span, clamped to 0...1.
    static func fraction(_ rssi: Int) -> Double {
        (Double(max(-100, min(-30, rssi))) + 100.0) / 70.0
    }
}

func pad(_ s: String, _ width: Int) -> String {
    s.padding(toLength: width, withPad: " ", startingAt: 0)
}

func bar(_ rssi: Int, width: Int = 24) -> String {
    let filled = Int((Proximity.fraction(rssi) * Double(width)).rounded())
    return String(repeating: "#", count: filled)
        + String(repeating: ".", count: width - filled)
}

private let sparkLevels = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

func sparkline(_ readings: ArraySlice<Reading>) -> String {
    readings.map { sparkLevels[Int((Proximity.fraction($0.rssi) * 7.0).rounded())] }.joined()
}

import Foundation

/// A 3x5 block font, stretched horizontally so the reading stays legible at
/// arm's length while you are walking and not looking straight at the screen.
private let source: [Character: [String]] = [
    "0": ["███", "█ █", "█ █", "█ █", "███"],
    "1": ["  █", "  █", "  █", "  █", "  █"],
    "2": ["███", "  █", "███", "█  ", "███"],
    "3": ["███", "  █", "███", "  █", "███"],
    "4": ["█ █", "█ █", "███", "  █", "  █"],
    "5": ["███", "█  ", "███", "  █", "███"],
    "6": ["███", "█  ", "███", "█ █", "███"],
    "7": ["███", "  █", "  █", "  █", "  █"],
    "8": ["███", "█ █", "███", "█ █", "███"],
    "9": ["███", "█ █", "███", "  █", "███"],
    "-": ["   ", "   ", "███", "   ", "   "],
]

/// Stretched once at startup rather than on every frame.
private let glyphs = source.mapValues { rows in
    rows.map { $0.map { String(repeating: String($0), count: 2) }.joined() }
}

private let rowCount = 5

/// Where a rider like "dBm" sits so it stays vertically centred on the digits.
let bigTextMiddle = rowCount / 2

/// Rows are equal width by construction, so callers need no padding.
func bigNumber(_ text: String) -> [String] {
    let picked = text.compactMap { glyphs[$0] }
    return (0..<rowCount).map { row in picked.map { $0[row] }.joined(separator: "  ") }
}

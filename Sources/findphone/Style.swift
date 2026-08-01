import Foundation

/// ANSI styling, suppressed when stdout is not a terminal so piped output and
/// CI logs stay plain. Knows nothing about signals — callers pick the code.
enum Style {
    static let enabled = isatty(STDOUT_FILENO) == 1

    static let dim = "2"
    static let green = "92"
    static let brightGreen = "1;92"
    static let yellow = "93"
    static let amber = "33"
    static let red = "91"

    static func wrap(_ s: String, _ code: String) -> String {
        enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }
}

import Foundation
import Darwin

#if canImport(XCTest)
import XCTest
@testable import findphone

final class TerminalSelectionControllerTests: XCTestCase {
    func testInteractiveInputModePreservesOutputFlags() {
        var original = termios()
        original.c_oflag = tcflag_t(0xDEADBEEF)
        original.c_lflag = tcflag_t(ECHO | ICANON | ISIG | IEXTEN | 0x4000_0000)
        original.c_iflag = tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON | IXOFF | 0x4000_0000)

        withUnsafeMutableBytes(of: &original.c_cc) { raw in
            raw[raw.index(raw.startIndex, offsetBy: Int(VMIN))] = 7
            raw[raw.index(raw.startIndex, offsetBy: Int(VTIME))] = 7
        }

        let transformed = makeInteractiveInputMode(from: original)

        XCTAssertEqual(transformed.c_oflag, original.c_oflag)
        XCTAssertEqual(transformed.c_lflag & tcflag_t(ECHO | ICANON | ISIG | IEXTEN), 0)
        XCTAssertEqual(transformed.c_iflag & tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON | IXOFF), 0)

        let vmin = terminalControlByte(transformed, Int(VMIN))
        let vtime = terminalControlByte(transformed, Int(VTIME))
        XCTAssertEqual(vmin, 0)
        XCTAssertEqual(vtime, 1)
    }

    private func terminalControlByte(_ state: termios, _ index: Int) -> UInt8 {
        withUnsafeBytes(of: state.c_cc) { raw in
            raw[index]
        }
    }
}
#endif

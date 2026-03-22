import XCTest
import AppKit
@testable import Deckard

final class TerminalColorSchemeTests: XCTestCase {

    // MARK: - Helpers

    private func writeTempTheme(_ content: String) -> String {
        let path = NSTemporaryDirectory() + "deckard-test-\(UUID().uuidString).theme"
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private func assertColorApprox(_ color: NSColor, r: CGFloat, g: CGFloat, b: CGFloat,
                                   accuracy: CGFloat = 0.01, file: StaticString = #file, line: UInt = #line) {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB", file: file, line: line)
            return
        }
        var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
        rgb.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
        XCTAssertEqual(cr, r, accuracy: accuracy, "red mismatch", file: file, line: line)
        XCTAssertEqual(cg, g, accuracy: accuracy, "green mismatch", file: file, line: line)
        XCTAssertEqual(cb, b, accuracy: accuracy, "blue mismatch", file: file, line: line)
    }

    // MARK: - Full theme parsing (Dracula)

    func testParseDraculaTheme() {
        let content = """
        palette = 0=#21222c
        palette = 1=#ff5555
        palette = 2=#50fa7b
        palette = 3=#f1fa8c
        palette = 4=#bd93f9
        palette = 5=#ff79c6
        palette = 6=#8be9fd
        palette = 7=#f8f8f2
        palette = 8=#6272a4
        palette = 9=#ff6e6e
        palette = 10=#69ff94
        palette = 11=#ffffa5
        palette = 12=#d6acff
        palette = 13=#ff92df
        palette = 14=#a4ffff
        palette = 15=#ffffff
        background = #282a36
        foreground = #f8f8f2
        cursor-color = #f8f8f2
        cursor-text = #282a36
        selection-background = #44475a
        selection-foreground = #ffffff
        """
        let path = writeTempTheme(content)
        let scheme = TerminalColorScheme.parse(from: path)

        XCTAssertNotNil(scheme)
        guard let s = scheme else { return }

        // Background: #282a36 → r=40/255, g=42/255, b=54/255
        assertColorApprox(s.background, r: 40/255, g: 42/255, b: 54/255)
        // Foreground: #f8f8f2
        assertColorApprox(s.foreground, r: 248/255, g: 248/255, b: 242/255)

        XCTAssertEqual(s.palette.count, 16)
        XCTAssertNotNil(s.cursorColor)
        XCTAssertNotNil(s.cursorTextColor)
        XCTAssertNotNil(s.selectionBackground)
    }

    // MARK: - Palette extraction

    func testPaletteExtraction16Colors() {
        var lines = "background = #000000\nforeground = #ffffff\n"
        for i in 0..<16 {
            let hex = String(format: "%02x%02x%02x", i * 16, i * 8, i * 4)
            lines += "palette = \(i)=#\(hex)\n"
        }
        let path = writeTempTheme(lines)
        let scheme = TerminalColorScheme.parse(from: path)

        XCTAssertNotNil(scheme)
        XCTAssertEqual(scheme?.palette.count, 16)

        // Verify first color: #000000
        if let first = scheme?.palette[0] {
            assertColorApprox(first, r: 0, g: 0, b: 0)
        }
    }

    func testMissingPaletteEntryUsesDefault() {
        // Only define palette entries 0 and 1, rest should be filled from defaults
        let content = """
        background = #000000
        foreground = #ffffff
        palette = 0=#ff0000
        palette = 1=#00ff00
        """
        let path = writeTempTheme(content)
        let scheme = TerminalColorScheme.parse(from: path)

        XCTAssertNotNil(scheme)
        XCTAssertEqual(scheme?.palette.count, 16)

        // Index 0 should be our override
        if let c = scheme?.palette[0] {
            assertColorApprox(c, r: 1, g: 0, b: 0)
        }
    }

    // MARK: - Hex parsing

    func testHexWithHash() {
        let content = "background = #ff0000\nforeground = #00ff00\n"
        let path = writeTempTheme(content)
        let scheme = TerminalColorScheme.parse(from: path)

        XCTAssertNotNil(scheme)
        if let bg = scheme?.background {
            assertColorApprox(bg, r: 1, g: 0, b: 0)
        }
    }

    func testHexWithoutHash() {
        let content = "background = ff0000\nforeground = 00ff00\n"
        let path = writeTempTheme(content)
        let scheme = TerminalColorScheme.parse(from: path)

        XCTAssertNotNil(scheme)
        if let bg = scheme?.background {
            assertColorApprox(bg, r: 1, g: 0, b: 0)
        }
    }

    // MARK: - Cursor and selection extraction

    func testCursorAndSelectionExtraction() {
        let content = """
        background = #000000
        foreground = #ffffff
        cursor-color = #ff0000
        cursor-text = #00ff00
        selection-background = #0000ff
        """
        let path = writeTempTheme(content)
        let scheme = TerminalColorScheme.parse(from: path)

        XCTAssertNotNil(scheme?.cursorColor)
        XCTAssertNotNil(scheme?.cursorTextColor)
        XCTAssertNotNil(scheme?.selectionBackground)

        if let cc = scheme?.cursorColor {
            assertColorApprox(cc, r: 1, g: 0, b: 0)
        }
        if let ct = scheme?.cursorTextColor {
            assertColorApprox(ct, r: 0, g: 1, b: 0)
        }
        if let sb = scheme?.selectionBackground {
            assertColorApprox(sb, r: 0, g: 0, b: 1)
        }
    }

    // MARK: - Missing required fields

    func testMissingBackgroundReturnsNil() {
        let content = "foreground = #ffffff\n"
        let path = writeTempTheme(content)
        XCTAssertNil(TerminalColorScheme.parse(from: path))
    }

    func testMissingForegroundReturnsNil() {
        let content = "background = #000000\n"
        let path = writeTempTheme(content)
        XCTAssertNil(TerminalColorScheme.parse(from: path))
    }

    // MARK: - Comments and blanks

    func testCommentsAndBlanksIgnored() {
        let content = """
        # This is a comment

        background = #000000

        # Another comment
        foreground = #ffffff
        """
        let path = writeTempTheme(content)
        let scheme = TerminalColorScheme.parse(from: path)
        XCTAssertNotNil(scheme)
    }

    // MARK: - Nonexistent file

    func testNonexistentFileReturnsNil() {
        XCTAssertNil(TerminalColorScheme.parse(from: "/nonexistent/path/theme.conf"))
    }

    // MARK: - Default scheme

    func testDefaultScheme() {
        let def = TerminalColorScheme.default
        XCTAssertNotNil(def.background)
        XCTAssertNotNil(def.foreground)
        XCTAssertTrue(def.palette.isEmpty)
        XCTAssertNil(def.cursorColor)
        XCTAssertNil(def.cursorTextColor)
        XCTAssertNil(def.selectionBackground)
    }

    // MARK: - Minimal theme

    func testMinimalTheme() {
        let content = "background = #000000\nforeground = #ffffff\n"
        let path = writeTempTheme(content)
        let scheme = TerminalColorScheme.parse(from: path)

        XCTAssertNotNil(scheme)
        XCTAssertNil(scheme?.cursorColor)
        XCTAssertNil(scheme?.selectionBackground)
        // Palette should still have 16 entries (defaults)
        XCTAssertEqual(scheme?.palette.count, 16)
    }
}

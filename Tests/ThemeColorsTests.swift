import XCTest
import AppKit
@testable import Deckard

final class ThemeColorsTests: XCTestCase {

    // MARK: - Luminance

    func testLuminanceBlack() {
        let black = NSColor(red: 0, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(black.luminance, 0, accuracy: 0.001)
    }

    func testLuminanceWhite() {
        let white = NSColor(red: 1, green: 1, blue: 1, alpha: 1)
        XCTAssertEqual(white.luminance, 1, accuracy: 0.001)
    }

    func testLuminanceRed() {
        let red = NSColor(red: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(red.luminance, 0.299, accuracy: 0.001)
    }

    func testLuminanceGreen() {
        let green = NSColor(red: 0, green: 1, blue: 0, alpha: 1)
        XCTAssertEqual(green.luminance, 0.587, accuracy: 0.001)
    }

    func testLuminanceBlue() {
        let blue = NSColor(red: 0, green: 0, blue: 1, alpha: 1)
        XCTAssertEqual(blue.luminance, 0.114, accuracy: 0.001)
    }

    // MARK: - isDark

    func testIsDarkForDarkBackground() {
        let dark = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        let colors = ThemeColors(background: dark, foreground: .white)
        XCTAssertTrue(colors.isDark)
    }

    func testIsDarkForLightBackground() {
        let light = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        let colors = ThemeColors(background: light, foreground: .black)
        XCTAssertFalse(colors.isDark)
    }

    func testIsDarkThresholdExactlyHalf() {
        // luminance = 0.5 → isDark should be true (<=0.5)
        // 0.299*r + 0.587*g + 0.114*b = 0.5
        // Use a grey where all channels are equal: 0.5/1.0 = 0.5
        let mid = NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let colors = ThemeColors(background: mid, foreground: .white)
        XCTAssertTrue(colors.isDark, "Luminance of exactly 0.5 should be considered dark")
    }

    // MARK: - adjustedBrightness

    func testAdjustedBrightnessClampsAtOne() {
        let bright = NSColor(hue: 0, saturation: 0, brightness: 0.98, alpha: 1)
        let adjusted = bright.adjustedBrightness(by: 0.1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        adjusted.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        XCTAssertEqual(b, 1.0, accuracy: 0.001)
    }

    func testAdjustedBrightnessClampsAtZero() {
        let dim = NSColor(hue: 0, saturation: 0, brightness: 0.02, alpha: 1)
        let adjusted = dim.adjustedBrightness(by: -0.1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        adjusted.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        XCTAssertEqual(b, 0.0, accuracy: 0.001)
    }

    func testAdjustedBrightnessPositiveDelta() {
        let base = NSColor(hue: 0.5, saturation: 0.5, brightness: 0.5, alpha: 1)
        let adjusted = base.adjustedBrightness(by: 0.1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        adjusted.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        XCTAssertEqual(b, 0.6, accuracy: 0.01)
    }

    // MARK: - Derived colors (dark theme)

    func testDarkThemeDerivedColors() {
        let bg = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        let fg = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        let colors = ThemeColors(background: bg, foreground: fg)

        XCTAssertTrue(colors.isDark)
        // primaryText should be the foreground
        XCTAssertEqual(colors.primaryText, fg)
        // secondaryText should have alpha 0.6
        XCTAssertEqual(colors.secondaryText.alphaComponent, 0.6, accuracy: 0.01)
        // selectedBackground should have alpha 0.12
        XCTAssertEqual(colors.selectedBackground.alphaComponent, 0.12, accuracy: 0.01)
    }

    // MARK: - Derived colors (light theme)

    func testLightThemeDerivedColors() {
        let bg = NSColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        let fg = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        let colors = ThemeColors(background: bg, foreground: fg)

        XCTAssertFalse(colors.isDark)
        // Light theme uses system colors
        XCTAssertEqual(colors.sidebarBackground, .windowBackgroundColor)
        XCTAssertEqual(colors.tabBarBackground, .windowBackgroundColor)
        XCTAssertEqual(colors.primaryText, .labelColor)
        XCTAssertEqual(colors.secondaryText, .secondaryLabelColor)
    }

    // MARK: - Default

    func testDefaultThemeColorsExist() {
        let def = ThemeColors.default
        XCTAssertNotNil(def.background)
        XCTAssertNotNil(def.foreground)
        XCTAssertNotNil(def.sidebarBackground)
        XCTAssertNotNil(def.tabBarBackground)
    }
}

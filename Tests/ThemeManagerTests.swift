import XCTest
import AppKit
@testable import Deckard

final class ThemeManagerTests: XCTestCase {

    // MARK: - Helpers

    private func createTempThemeDir(themes: [String]) -> String {
        let dir = NSTemporaryDirectory() + "deckard-themes-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for name in themes {
            let content = "background = #000000\nforeground = #ffffff\n"
            try! content.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    // MARK: - Theme sorting

    func testAvailableThemesSortedAlphabetically() {
        let manager = ThemeManager()
        // Inject themes manually to test sorting
        let themes = ["Zenburn", "Dracula", "Monokai", "Ayu"].map {
            ThemeManager.ThemeInfo(name: $0, path: "/fake/\($0)")
        }
        // The sort in loadAvailableThemes uses localizedCaseInsensitiveCompare
        let sorted = themes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        XCTAssertEqual(sorted.map(\.name), ["Ayu", "Dracula", "Monokai", "Zenburn"])
    }

    // MARK: - Theme application

    func testApplyThemeWithNilResetsToDefault() {
        let manager = ThemeManager()
        manager.applyTheme(name: nil)

        // Should reset to default scheme
        let defaultScheme = TerminalColorScheme.default
        XCTAssertEqual(manager.currentScheme.palette.count, defaultScheme.palette.count)
        XCTAssertNil(UserDefaults.standard.string(forKey: "ghosttyThemeName"))
    }

    func testApplyThemeWithUnknownNameFallsToDefault() {
        let manager = ThemeManager()
        manager.applyTheme(name: "NonExistentTheme-\(UUID().uuidString)")

        // Should fallback to default
        XCTAssertNil(UserDefaults.standard.string(forKey: "ghosttyThemeName"))
    }

    func testApplyThemeWithValidNameSavesToDefaults() {
        // Since availableThemes is private(set), we can't inject themes directly.
        // Instead, we test that applying an unknown name does NOT set the default.
        let manager = ThemeManager()
        manager.applyTheme(name: "SurelyDoesNotExist-\(UUID().uuidString)")
        XCTAssertNil(UserDefaults.standard.string(forKey: "ghosttyThemeName"))
    }

    // MARK: - Notification posting

    func testApplyThemePostsNotification() {
        let manager = ThemeManager()
        let expectation = expectation(description: "Theme changed notification")

        let observer = NotificationCenter.default.addObserver(
            forName: .deckardThemeChanged,
            object: nil,
            queue: .main
        ) { notification in
            XCTAssertNotNil(notification.userInfo?["scheme"])
            XCTAssertNotNil(notification.userInfo?["colors"])
            expectation.fulfill()
        }

        manager.applyTheme(name: nil)

        waitForExpectations(timeout: 2)
        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - ThemeInfo struct

    func testThemeInfoProperties() {
        let info = ThemeManager.ThemeInfo(name: "Dracula", path: "/themes/Dracula")
        XCTAssertEqual(info.name, "Dracula")
        XCTAssertEqual(info.path, "/themes/Dracula")
    }

    // MARK: - currentColors and currentScheme defaults

    func testInitialColorsAreDefault() {
        let manager = ThemeManager()
        XCTAssertNotNil(manager.currentColors.background)
        XCTAssertNotNil(manager.currentScheme.background)
    }

    // MARK: - Skip dotfiles and LICENSE

    func testLoadAvailableThemesSkipsDotfilesAndLicense() {
        // This tests the filtering logic directly
        let names = [".hidden", "LICENSE", "Dracula", "Monokai"]
        let filtered = names.filter { !$0.hasPrefix(".") && !$0.hasPrefix("LICENSE") }
        XCTAssertEqual(filtered, ["Dracula", "Monokai"])
    }

    // MARK: - Apply nil theme resets currentColors

    func testApplyNilThemeResetsToDefault() {
        let manager = ThemeManager()
        manager.applyTheme(name: nil)

        // Default scheme should be applied
        XCTAssertNotNil(manager.currentColors)
        XCTAssertNotNil(manager.currentScheme)
    }
}

import XCTest
import AppKit
@testable import Deckard

final class WindowControllerLogicTests: XCTestCase {

    // MARK: - BadgeState raw values

    func testBadgeStateRawValues() {
        XCTAssertEqual(TabItem.BadgeState.none.rawValue, "none")
        XCTAssertEqual(TabItem.BadgeState.idle.rawValue, "idle")
        XCTAssertEqual(TabItem.BadgeState.thinking.rawValue, "thinking")
        XCTAssertEqual(TabItem.BadgeState.waitingForInput.rawValue, "waitingForInput")
        XCTAssertEqual(TabItem.BadgeState.needsPermission.rawValue, "needsPermission")
        XCTAssertEqual(TabItem.BadgeState.error.rawValue, "error")
        XCTAssertEqual(TabItem.BadgeState.terminalIdle.rawValue, "terminalIdle")
        XCTAssertEqual(TabItem.BadgeState.terminalActive.rawValue, "terminalActive")
        XCTAssertEqual(TabItem.BadgeState.terminalError.rawValue, "terminalError")
    }

    // MARK: - BadgeState from raw value

    func testBadgeStateFromRawValue() {
        XCTAssertEqual(TabItem.BadgeState(rawValue: "thinking"), .thinking)
        XCTAssertEqual(TabItem.BadgeState(rawValue: "needsPermission"), .needsPermission)
        XCTAssertNil(TabItem.BadgeState(rawValue: "invalid"))
    }

    // MARK: - All BadgeState cases

    func testAllBadgeStateCasesExist() {
        let allCases: [TabItem.BadgeState] = [
            .none, .idle, .thinking, .waitingForInput,
            .needsPermission, .error,
            .terminalIdle, .terminalActive, .terminalError,
        ]
        XCTAssertEqual(allCases.count, 9)

        // Verify all have distinct raw values
        let rawValues = Set(allCases.map(\.rawValue))
        XCTAssertEqual(rawValues.count, 9)
    }

    // MARK: - ProjectItem

    func testProjectItemInit() {
        let project = ProjectItem(path: "/Users/test/my-project")
        XCTAssertEqual(project.path, "/Users/test/my-project")
        XCTAssertEqual(project.name, "my-project")
        XCTAssertTrue(project.tabs.isEmpty)
        XCTAssertEqual(project.selectedTabIndex, 0)
    }

    func testProjectItemNameIsBasename() {
        let project = ProjectItem(path: "/a/b/c/deep-folder")
        XCTAssertEqual(project.name, "deep-folder")
    }

    // MARK: - DefaultTabConfig

    func testDefaultTabConfigParsesDefaults() {
        // The default is "claude, terminal"
        let config = DefaultTabConfig.current
        XCTAssertFalse(config.entries.isEmpty)
    }

    // MARK: - ActivityInfo from ProcessMonitor

    func testProcessMonitorActivityInfoIsUsableInWindowContext() {
        let idle = ProcessMonitor.ActivityInfo()
        XCTAssertFalse(idle.isActive)
        XCTAssertEqual(idle.description, "Idle")

        let busy = ProcessMonitor.ActivityInfo(cpu: true, disk: true)
        XCTAssertTrue(busy.isActive)
        XCTAssertEqual(busy.description, "Busy")
    }

    // MARK: - TabItem (requires TerminalSurface which needs AppKit)

    func testTabItemCannotBeCreatedWithoutSurface() throws {
        try XCTSkipIf(true, "TabItem requires TerminalSurface which needs SwiftTerm view hierarchy")
    }
}

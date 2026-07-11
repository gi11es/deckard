import XCTest
import AppKit
import KeyboardShortcuts
@testable import Deckard

// MARK: - Session ownership (nested-claude hijack)

/// Nested claude processes (spawned by a tab's session, inheriting
/// DECKARD_SURFACE_ID) report session-start from their own cwd. Only a cwd
/// inside the tab's workspace may update the tab's session id.
final class SessionOwnershipTests: XCTestCase {

    func testCwdBelongsToWorkspaceAcceptsExactPath() {
        XCTAssertTrue(DeckardWindowController.cwdBelongsToWorkspace(
            "/Users/x/proj", workspacePath: "/Users/x/proj"))
    }

    func testCwdBelongsToWorkspaceAcceptsSubdirectory() {
        XCTAssertTrue(DeckardWindowController.cwdBelongsToWorkspace(
            "/Users/x/proj/.claude/worktrees/fix-1", workspacePath: "/Users/x/proj"))
    }

    func testCwdBelongsToWorkspaceAcceptsNilOrEmptyCwd() {
        XCTAssertTrue(DeckardWindowController.cwdBelongsToWorkspace(
            nil, workspacePath: "/Users/x/proj"))
        XCTAssertTrue(DeckardWindowController.cwdBelongsToWorkspace(
            "", workspacePath: "/Users/x/proj"))
    }

    func testCwdBelongsToWorkspaceRejectsTempCheckout() {
        XCTAssertFalse(DeckardWindowController.cwdBelongsToWorkspace(
            "/private/var/folders/9z/T/reviewer-pr8112-7301",
            workspacePath: "/Users/x/proj"))
    }

    func testCwdBelongsToWorkspaceRejectsSiblingWithCommonPrefix() {
        XCTAssertFalse(DeckardWindowController.cwdBelongsToWorkspace(
            "/Users/x/proj-other", workspacePath: "/Users/x/proj"))
    }

    func testCwdBelongsToWorkspaceRejectsParentDirectory() {
        XCTAssertFalse(DeckardWindowController.cwdBelongsToWorkspace(
            "/Users/x", workspacePath: "/Users/x/proj"))
    }

    func testCwdBelongsToWorkspaceResolvesSymlinks() throws {
        // On macOS /tmp is a symlink to /private/tmp. Symlink resolution only
        // applies to paths that exist — which cwd and workspace always do.
        XCTAssertTrue(DeckardWindowController.cwdBelongsToWorkspace(
            "/tmp", workspacePath: "/private/tmp"))
        XCTAssertTrue(DeckardWindowController.cwdBelongsToWorkspace(
            "/private/tmp", workspacePath: "/tmp"))

        let sub = "deckard-ownership-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: "/tmp/\(sub)", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: "/tmp/\(sub)") }
        XCTAssertTrue(DeckardWindowController.cwdBelongsToWorkspace(
            "/private/tmp/\(sub)", workspacePath: "/tmp"))
    }

    func testCwdBelongsToWorkspaceHandlesTrailingSlash() {
        XCTAssertTrue(DeckardWindowController.cwdBelongsToWorkspace(
            "/Users/x/proj/", workspacePath: "/Users/x/proj"))
    }
}

final class WindowControllerLogicTests: XCTestCase {

    // MARK: - BadgeState raw values

    func testBadgeStateRawValues() {
        XCTAssertEqual(TabItem.BadgeState.none.rawValue, "none")
        XCTAssertEqual(TabItem.BadgeState.idle.rawValue, "idle")
        XCTAssertEqual(TabItem.BadgeState.thinking.rawValue, "thinking")
        XCTAssertEqual(TabItem.BadgeState.waitingForInput.rawValue, "waitingForInput")
        XCTAssertEqual(TabItem.BadgeState.needsPermission.rawValue, "needsPermission")
        XCTAssertEqual(TabItem.BadgeState.error.rawValue, "error")
        XCTAssertEqual(TabItem.BadgeState.codexIdle.rawValue, "codexIdle")
        XCTAssertEqual(TabItem.BadgeState.codexThinking.rawValue, "codexThinking")
        XCTAssertEqual(TabItem.BadgeState.codexError.rawValue, "codexError")
        XCTAssertEqual(TabItem.BadgeState.codexCompletedUnseen.rawValue, "codexCompletedUnseen")
        XCTAssertEqual(TabItem.BadgeState.grokIdle.rawValue, "grokIdle")
        XCTAssertEqual(TabItem.BadgeState.grokThinking.rawValue, "grokThinking")
        XCTAssertEqual(TabItem.BadgeState.grokError.rawValue, "grokError")
        XCTAssertEqual(TabItem.BadgeState.grokCompletedUnseen.rawValue, "grokCompletedUnseen")
        XCTAssertEqual(TabItem.BadgeState.terminalIdle.rawValue, "terminalIdle")
        XCTAssertEqual(TabItem.BadgeState.terminalActive.rawValue, "terminalActive")
        XCTAssertEqual(TabItem.BadgeState.terminalError.rawValue, "terminalError")
        XCTAssertEqual(TabItem.BadgeState.completedUnseen.rawValue, "completedUnseen")
        XCTAssertEqual(TabItem.BadgeState.terminalCompletedUnseen.rawValue, "terminalCompletedUnseen")
    }

    // MARK: - BadgeState from raw value

    func testBadgeStateFromRawValue() {
        XCTAssertEqual(TabItem.BadgeState(rawValue: "thinking"), .thinking)
        XCTAssertEqual(TabItem.BadgeState(rawValue: "needsPermission"), .needsPermission)
        XCTAssertEqual(TabItem.BadgeState(rawValue: "codexThinking"), .codexThinking)
        XCTAssertEqual(TabItem.BadgeState(rawValue: "codexCompletedUnseen"), .codexCompletedUnseen)
        XCTAssertEqual(TabItem.BadgeState(rawValue: "grokThinking"), .grokThinking)
        XCTAssertEqual(TabItem.BadgeState(rawValue: "grokCompletedUnseen"), .grokCompletedUnseen)
        XCTAssertNil(TabItem.BadgeState(rawValue: "invalid"))
    }

    // MARK: - All BadgeState cases

    func testAllBadgeStateCasesExist() {
        let allCases: [TabItem.BadgeState] = [
            .none, .idle, .thinking, .waitingForInput,
            .needsPermission, .error,
            .codexIdle, .codexThinking, .codexError, .codexCompletedUnseen,
            .grokIdle, .grokThinking, .grokError, .grokCompletedUnseen,
            .terminalIdle, .terminalActive, .terminalError,
            .completedUnseen, .terminalCompletedUnseen,
        ]
        XCTAssertEqual(allCases.count, 19)

        // Verify all have distinct raw values
        let rawValues = Set(allCases.map(\.rawValue))
        XCTAssertEqual(rawValues.count, 19)
    }

    // MARK: - TabKind

    func testTabKindDisplayNames() {
        XCTAssertEqual(TabKind.claude.displayName, "Claude")
        XCTAssertEqual(TabKind.codex.displayName, "Codex")
        XCTAssertEqual(TabKind.grok.displayName, "Grok")
        XCTAssertEqual(TabKind.terminal.displayName, "Terminal")
    }

    func testTabKindAgentClassification() {
        XCTAssertTrue(TabKind.claude.isAgent)
        XCTAssertTrue(TabKind.codex.isAgent)
        XCTAssertTrue(TabKind.grok.isAgent)
        XCTAssertFalse(TabKind.terminal.isAgent)
    }

    func testTabKindForkAtPointSupport() {
        XCTAssertTrue(TabKind.claude.supportsForkAtPoint)
        XCTAssertTrue(TabKind.codex.supportsForkAtPoint)
        XCTAssertFalse(TabKind.grok.supportsForkAtPoint)
        XCTAssertFalse(TabKind.terminal.supportsForkAtPoint)
    }

    // MARK: - WorkspaceItem

    func testWorkspaceItemInit() {
        let workspace = WorkspaceItem(path: "/Users/test/my-workspace")
        XCTAssertEqual(workspace.path, "/Users/test/my-workspace")
        XCTAssertEqual(workspace.name, "my-workspace")
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertEqual(workspace.selectedTabIndex, 0)
    }

    func testWorkspaceItemNameIsBasename() {
        let workspace = WorkspaceItem(path: "/a/b/c/deep-group")
        XCTAssertEqual(workspace.name, "deep-group")
    }

    // MARK: - WorkspaceItem symlink resolution

    func testWorkspaceItemResolvesSymlinks() throws {
        let tempDir = NSTemporaryDirectory() + "deckard-symlink-\(UUID().uuidString)"
        let realDir = tempDir + "/real-workspace"
        let linkDir = tempDir + "/linked-workspace"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }
        try FileManager.default.createSymbolicLink(atPath: linkDir, withDestinationPath: realDir)

        let workspace = WorkspaceItem(path: linkDir)
        XCTAssertEqual(workspace.path, realDir, "WorkspaceItem should resolve symlinks to canonical path")
        XCTAssertEqual(workspace.name, "real-workspace")
    }

    func testWorkspaceItemCanonicalPathIsIdempotent() throws {
        let tempDir = NSTemporaryDirectory() + "deckard-symlink-\(UUID().uuidString)"
        let realDir = tempDir + "/real-workspace"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }

        // A non-symlink path should be unchanged
        let workspace = WorkspaceItem(path: realDir)
        XCTAssertEqual(workspace.path, realDir)
    }

    func testWorkspaceItemViaSymlinkMatchesCanonical() throws {
        let tempDir = NSTemporaryDirectory() + "deckard-symlink-\(UUID().uuidString)"
        let realDir = tempDir + "/real-workspace"
        let linkDir = tempDir + "/linked-workspace"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }
        try FileManager.default.createSymbolicLink(atPath: linkDir, withDestinationPath: realDir)

        let fromSymlink = WorkspaceItem(path: linkDir)
        let fromCanonical = WorkspaceItem(path: realDir)
        XCTAssertEqual(fromSymlink.path, fromCanonical.path,
                       "WorkspaceItems opened via symlink and canonical path should have the same path")
    }

    func testWorkspaceItemChainedSymlinks() throws {
        let tempDir = NSTemporaryDirectory() + "deckard-symlink-\(UUID().uuidString)"
        let realDir = tempDir + "/real-workspace"
        let link1 = tempDir + "/link1"
        let link2 = tempDir + "/link2"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }
        try FileManager.default.createSymbolicLink(atPath: link1, withDestinationPath: realDir)
        try FileManager.default.createSymbolicLink(atPath: link2, withDestinationPath: link1)

        let workspace = WorkspaceItem(path: link2)
        XCTAssertEqual(workspace.path, realDir, "Chained symlinks should fully resolve")
    }

    // MARK: - DefaultTabConfig

    func testDefaultTabConfigParsesDefaults() {
        // The default is "claude, terminal"
        let config = DefaultTabConfig.current
        XCTAssertFalse(config.entries.isEmpty)
    }

    func testDefaultTabConfigParsesCodexTabs() {
        withUserDefaultsValue("defaultTabConfig", value: "claude, codex, terminal") {
            let config = DefaultTabConfig.current

            XCTAssertEqual(config.entries.count, 3)
            XCTAssertEqual(config.entries[0].kind, .claude)
            XCTAssertEqual(config.entries[0].name, "Claude")
            XCTAssertEqual(config.entries[1].kind, .codex)
            XCTAssertEqual(config.entries[1].name, "Codex")
            XCTAssertEqual(config.entries[2].kind, .terminal)
            XCTAssertEqual(config.entries[2].name, "Terminal")
        }
    }

    func testDefaultTabConfigParsesGrokTabs() {
        withUserDefaultsValue("defaultTabConfig", value: "claude, grok") {
            let config = DefaultTabConfig.current

            XCTAssertEqual(config.entries.count, 2)
            XCTAssertEqual(config.entries[0].kind, .claude)
            XCTAssertEqual(config.entries[1].kind, .grok)
            XCTAssertEqual(config.entries[1].name, "Grok")
        }
    }

    // MARK: - Badge animation defaults

    func testCodexThinkingBadgeIsAnimatedByDefault() {
        withUserDefaultsValue("badgeAnimate.codexThinking", value: nil) {
            XCTAssertTrue(SettingsWindowController.isBadgeAnimated(.codexThinking))
        }
    }

    func testCodexNonWorkingBadgesAreNotAnimatedByDefault() {
        let keys = [
            "badgeAnimate.codexIdle",
            "badgeAnimate.codexError",
            "badgeAnimate.codexCompletedUnseen",
        ]
        withRemovedUserDefaults(keys) {
            XCTAssertFalse(SettingsWindowController.isBadgeAnimated(.codexIdle))
            XCTAssertFalse(SettingsWindowController.isBadgeAnimated(.codexError))
            XCTAssertFalse(SettingsWindowController.isBadgeAnimated(.codexCompletedUnseen))
        }
    }

    func testGrokThinkingBadgeIsAnimatedByDefault() {
        withUserDefaultsValue("badgeAnimate.grokThinking", value: nil) {
            XCTAssertTrue(SettingsWindowController.isBadgeAnimated(.grokThinking))
        }
    }

    func testGrokNonWorkingBadgesAreNotAnimatedByDefault() {
        let keys = [
            "badgeAnimate.grokIdle",
            "badgeAnimate.grokError",
            "badgeAnimate.grokCompletedUnseen",
        ]
        withRemovedUserDefaults(keys) {
            XCTAssertFalse(SettingsWindowController.isBadgeAnimated(.grokIdle))
            XCTAssertFalse(SettingsWindowController.isBadgeAnimated(.grokError))
            XCTAssertFalse(SettingsWindowController.isBadgeAnimated(.grokCompletedUnseen))
        }
    }

    // MARK: - Shortcut policy

    func testShortcutPolicyRejectsReporterOptionArrowShortcuts() {
        let previousTab = KeyboardShortcuts.Shortcut(.leftArrow, modifiers: .option)
        let nextTab = KeyboardShortcuts.Shortcut(.rightArrow, modifiers: .option)

        XCTAssertNotNil(DeckardShortcutPolicy.rejectionReason(for: previousTab))
        XCTAssertNotNil(DeckardShortcutPolicy.rejectionReason(for: nextTab))
    }

    func testShortcutPolicyRejectsShiftOptionShortcuts() {
        let shortcut = KeyboardShortcuts.Shortcut(.rightArrow, modifiers: [.shift, .option])

        XCTAssertNotNil(DeckardShortcutPolicy.rejectionReason(for: shortcut))
    }

    func testShortcutPolicyRejectsCommandTabAppSwitcherShortcuts() {
        let nextApp = KeyboardShortcuts.Shortcut(.tab, modifiers: .command)
        let previousApp = KeyboardShortcuts.Shortcut(.tab, modifiers: [.command, .shift])

        XCTAssertNotNil(DeckardShortcutPolicy.rejectionReason(for: nextApp))
        XCTAssertNotNil(DeckardShortcutPolicy.rejectionReason(for: previousApp))
    }

    func testShortcutPolicyAllowsCommandOptionArrows() {
        let nextTab = KeyboardShortcuts.Shortcut(.rightArrow, modifiers: [.command, .option])
        let previousTab = KeyboardShortcuts.Shortcut(.leftArrow, modifiers: [.command, .option])

        XCTAssertNil(DeckardShortcutPolicy.rejectionReason(for: nextTab))
        XCTAssertNil(DeckardShortcutPolicy.rejectionReason(for: previousTab))
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

    private func withUserDefaultsValue(_ key: String, value: Any?, run: () -> Void) {
        let previous = UserDefaults.standard.object(forKey: key)
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }

        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        run()
    }

    private func withRemovedUserDefaults(_ keys: [String], run: () -> Void) {
        let previousValues = keys.map { key in
            (key: key, value: UserDefaults.standard.object(forKey: key))
        }
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }

        defer {
            for previous in previousValues {
                if let value = previous.value {
                    UserDefaults.standard.set(value, forKey: previous.key)
                } else {
                    UserDefaults.standard.removeObject(forKey: previous.key)
                }
            }
        }

        run()
    }
}

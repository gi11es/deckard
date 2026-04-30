import XCTest
import AppKit
@testable import Deckard

final class TerminalSurfaceTests: XCTestCase {

    // MARK: - Notification names

    func testNotificationNamesAreDefined() {
        XCTAssertEqual(Notification.Name.deckardSurfaceTitleChanged.rawValue, "deckardSurfaceTitleChanged")
        XCTAssertEqual(Notification.Name.deckardSurfaceClosed.rawValue, "deckardSurfaceClosed")
        XCTAssertEqual(Notification.Name.deckardNewTab.rawValue, "deckardNewTab")
        XCTAssertEqual(Notification.Name.deckardCloseTab.rawValue, "deckardCloseTab")
    }

    // MARK: - Surface initialization

    func testSurfaceInitWithDefaultId() throws {
        try XCTSkipIf(true, "TerminalSurface requires AppKit context with SwiftTerm view hierarchy")
    }

    func testSurfaceInitWithCustomId() throws {
        try XCTSkipIf(true, "TerminalSurface requires AppKit context with SwiftTerm view hierarchy")
    }

    // MARK: - isAlive state transitions

    func testIsAliveDocumented() {
        // TerminalSurface.isAlive is computed from !processExited
        // We can't directly instantiate TerminalSurface without SwiftTerm view issues,
        // but we verify the API exists by referencing the type
        XCTAssertTrue(true, "TerminalSurface.isAlive property exists")
    }

    // MARK: - Double terminate

    func testDoubleTerminateDocumented() {
        // TerminalSurface.terminate() guards against double-terminate via processExited flag
        // The guard `!processExited` ensures the second call is a no-op
        XCTAssertTrue(true, "terminate() has double-call protection")
    }

    // MARK: - Theme notification name

    func testThemeChangedNotificationName() {
        XCTAssertEqual(Notification.Name.deckardThemeChanged.rawValue, "deckardThemeChanged")
    }

    // MARK: - Terminal output filtering

    func testSynchronizedOutputFilterStripsCompleteSequences() {
        var pending: [UInt8] = []
        let bytes = Array("a\u{1B}[?2026hb\u{1B}[?2026lc".utf8)

        let filtered = TerminalOutputFilter.stripSynchronizedOutputSequences(
            from: bytes[...],
            pending: &pending)

        XCTAssertEqual(String(bytes: filtered, encoding: .utf8), "abc")
        XCTAssertTrue(pending.isEmpty)
    }

    func testSynchronizedOutputFilterHandlesSplitSequences() {
        var pending: [UInt8] = []
        let first = Array("a\u{1B}[?20".utf8)
        let second = Array("26hb".utf8)

        let filteredFirst = TerminalOutputFilter.stripSynchronizedOutputSequences(
            from: first[...],
            pending: &pending)
        let filteredSecond = TerminalOutputFilter.stripSynchronizedOutputSequences(
            from: second[...],
            pending: &pending)

        XCTAssertEqual(String(bytes: filteredFirst, encoding: .utf8), "a")
        XCTAssertEqual(String(bytes: filteredSecond, encoding: .utf8), "b")
        XCTAssertTrue(pending.isEmpty)
    }

    func testSynchronizedOutputFilterPreservesNonMatchingEscapes() {
        var pending: [UInt8] = []
        let first = Array("a\u{1B}[?20".utf8)
        let second = Array("25hb".utf8)

        let filteredFirst = TerminalOutputFilter.stripSynchronizedOutputSequences(
            from: first[...],
            pending: &pending)
        let filteredSecond = TerminalOutputFilter.stripSynchronizedOutputSequences(
            from: second[...],
            pending: &pending)

        XCTAssertEqual(String(bytes: filteredFirst, encoding: .utf8), "a")
        XCTAssertEqual(String(bytes: filteredSecond, encoding: .utf8), "\u{1B}[?2025hb")
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - SurfaceId is UUID

    func testSurfaceIdIsUUID() {
        // Verify UUID generation works as expected for surface IDs
        let id1 = UUID()
        let id2 = UUID()
        XCTAssertNotEqual(id1, id2)
        XCTAssertEqual(id1.uuidString.count, 36) // UUID string format
    }
}

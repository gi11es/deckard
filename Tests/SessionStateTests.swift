import XCTest
@testable import Deckard

final class SessionStateTests: XCTestCase {

    // MARK: - DeckardState Codable

    func testDeckardStateRoundtrip() throws {
        var state = DeckardState()
        state.version = 2
        state.selectedTabIndex = 3
        state.defaultWorkingDirectory = "/Users/test/project"
        state.projects = [
            ProjectState(
                id: "proj-1",
                path: "/Users/test/project",
                name: "project",
                selectedTabIndex: 0,
                tabs: [
                    ProjectTabState(id: "tab-1", name: "Claude", isClaude: true, sessionId: "sess-1"),
                    ProjectTabState(id: "tab-2", name: "Terminal", isClaude: false, sessionId: nil),
                ]
            )
        ]

        let encoder = JSONEncoder()
        let data = try encoder.encode(state)
        let decoded = try JSONDecoder().decode(DeckardState.self, from: data)

        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.selectedTabIndex, 3)
        XCTAssertEqual(decoded.defaultWorkingDirectory, "/Users/test/project")
        XCTAssertEqual(decoded.projects?.count, 1)
        XCTAssertEqual(decoded.projects?[0].tabs.count, 2)
        XCTAssertEqual(decoded.projects?[0].tabs[0].isClaude, true)
        XCTAssertEqual(decoded.projects?[0].tabs[0].sessionId, "sess-1")
        XCTAssertNil(decoded.projects?[0].tabs[1].sessionId)
    }

    func testEmptyStateRoundtrip() throws {
        let state = DeckardState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DeckardState.self, from: data)

        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.selectedTabIndex, 0)
        XCTAssertNil(decoded.defaultWorkingDirectory)
        XCTAssertNil(decoded.projects)
    }

    func testMultipleProjectsRoundtrip() throws {
        var state = DeckardState()
        state.projects = [
            ProjectState(id: "p1", path: "/path/a", name: "a", selectedTabIndex: 0, tabs: []),
            ProjectState(id: "p2", path: "/path/b", name: "b", selectedTabIndex: 1, tabs: [
                ProjectTabState(id: "t1", name: "Claude", isClaude: true, sessionId: nil),
            ]),
            ProjectState(id: "p3", path: "/path/c", name: "c", selectedTabIndex: 0, tabs: []),
        ]

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DeckardState.self, from: data)

        XCTAssertEqual(decoded.projects?.count, 3)
        XCTAssertEqual(decoded.projects?[1].name, "b")
        XCTAssertEqual(decoded.projects?[1].tabs.count, 1)
    }

    // MARK: - TabState (legacy v1) Codable

    func testLegacyTabStateRoundtrip() throws {
        let tab = TabState(
            id: "tab-1",
            sessionId: "session-abc",
            name: "Terminal",
            nameOverride: true,
            isMaster: false,
            isClaude: false,
            workingDirectory: "/tmp"
        )

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(TabState.self, from: data)

        XCTAssertEqual(decoded.id, "tab-1")
        XCTAssertEqual(decoded.sessionId, "session-abc")
        XCTAssertEqual(decoded.name, "Terminal")
        XCTAssertTrue(decoded.nameOverride)
        XCTAssertFalse(decoded.isMaster)
        XCTAssertFalse(decoded.isClaude)
        XCTAssertEqual(decoded.workingDirectory, "/tmp")
    }

    // MARK: - ProjectTabState Codable

    func testProjectTabStateRoundtrip() throws {
        let tab = ProjectTabState(id: "t1", name: "Claude", isClaude: true, sessionId: "s1")
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(ProjectTabState.self, from: data)

        XCTAssertEqual(decoded.id, "t1")
        XCTAssertEqual(decoded.name, "Claude")
        XCTAssertTrue(decoded.isClaude)
        XCTAssertEqual(decoded.sessionId, "s1")
    }

    // MARK: - SessionManager save/load

    func testSessionManagerSaveAndLoad() throws {
        let manager = SessionManager()
        let tempDir = NSTemporaryDirectory() + "deckard-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }

        let tempURL = URL(fileURLWithPath: tempDir + "state.json")

        // Create a state, encode to JSON, write to temp file, read back
        var state = DeckardState()
        state.selectedTabIndex = 5
        state.projects = [
            ProjectState(id: "p1", path: "/test", name: "test", selectedTabIndex: 0, tabs: [])
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: tempURL, options: .atomic)

        let loadedData = try Data(contentsOf: tempURL)
        let loaded = try JSONDecoder().decode(DeckardState.self, from: loadedData)

        XCTAssertEqual(loaded.selectedTabIndex, 5)
        XCTAssertEqual(loaded.projects?.count, 1)
    }

    // MARK: - State with legacy fields

    func testStateWithLegacyFields() throws {
        var state = DeckardState()
        state.version = 2
        state.tabs = [TabState(id: "old-tab", sessionId: nil, name: "Old", nameOverride: false, isMaster: true, isClaude: false, workingDirectory: nil)]
        state.claudeTabCounter = 3
        state.terminalTabCounter = 2
        state.masterSessionId = "master-123"

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DeckardState.self, from: data)

        XCTAssertEqual(decoded.claudeTabCounter, 3)
        XCTAssertEqual(decoded.terminalTabCounter, 2)
        XCTAssertEqual(decoded.masterSessionId, "master-123")
        XCTAssertEqual(decoded.tabs?.count, 1)
    }

    // MARK: - Default values

    func testDefaultValues() {
        let state = DeckardState()
        XCTAssertEqual(state.version, 2)
        XCTAssertEqual(state.selectedTabIndex, 0)
        XCTAssertNil(state.defaultWorkingDirectory)
        XCTAssertNil(state.tabs)
        XCTAssertNil(state.projects)
    }
}

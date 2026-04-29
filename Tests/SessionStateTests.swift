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
                    ProjectTabState(id: "tab-2", name: "Codex", kind: .codex, sessionId: "codex-1"),
                    ProjectTabState(id: "tab-3", name: "Terminal", isClaude: false, sessionId: nil),
                ],
                defaultArgs: "--permission-mode acceptEdits",
                defaultCodexArgs: "--ask-for-approval never --sandbox workspace-write"
            )
        ]

        let encoder = JSONEncoder()
        let data = try encoder.encode(state)
        let decoded = try JSONDecoder().decode(DeckardState.self, from: data)

        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.selectedTabIndex, 3)
        XCTAssertEqual(decoded.defaultWorkingDirectory, "/Users/test/project")
        XCTAssertEqual(decoded.projects?.count, 1)
        XCTAssertEqual(decoded.projects?[0].tabs.count, 3)
        XCTAssertEqual(decoded.projects?[0].tabs[0].isClaude, true)
        XCTAssertEqual(decoded.projects?[0].tabs[0].sessionId, "sess-1")
        XCTAssertEqual(decoded.projects?[0].tabs[1].kind, .codex)
        XCTAssertEqual(decoded.projects?[0].tabs[1].isClaude, false)
        XCTAssertEqual(decoded.projects?[0].tabs[1].sessionId, "codex-1")
        XCTAssertEqual(decoded.projects?[0].tabs[2].kind, .terminal)
        XCTAssertNil(decoded.projects?[0].tabs[2].sessionId)
        XCTAssertEqual(decoded.projects?[0].defaultArgs, "--permission-mode acceptEdits")
        XCTAssertEqual(decoded.projects?[0].defaultCodexArgs, "--ask-for-approval never --sandbox workspace-write")
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
        XCTAssertEqual(decoded.kind, .claude)
        XCTAssertTrue(decoded.isClaude)
        XCTAssertEqual(decoded.sessionId, "s1")
    }

    func testProjectTabStateCodexRoundtrip() throws {
        let tab = ProjectTabState(
            id: "t-codex",
            name: "Codex",
            kind: .codex,
            sessionId: "codex-session",
            tmuxSessionName: "deckard-codex"
        )

        let data = try JSONEncoder().encode(tab)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let decoded = try JSONDecoder().decode(ProjectTabState.self, from: data)

        XCTAssertEqual(json?["kind"] as? String, "codex")
        XCTAssertEqual(json?["isClaude"] as? Bool, false)
        XCTAssertEqual(decoded.id, "t-codex")
        XCTAssertEqual(decoded.name, "Codex")
        XCTAssertEqual(decoded.kind, .codex)
        XCTAssertFalse(decoded.isClaude)
        XCTAssertEqual(decoded.sessionId, "codex-session")
        XCTAssertEqual(decoded.tmuxSessionName, "deckard-codex")
    }

    func testProjectTabStateDecodesCodexKindEvenWhenLegacyIsClaudeIsFalse() throws {
        let json = """
        {"id": "tab-codex", "name": "Codex", "kind": "codex", "isClaude": false, "sessionId": "codex-1"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProjectTabState.self, from: json)

        XCTAssertEqual(decoded.kind, .codex)
        XCTAssertFalse(decoded.isClaude)
        XCTAssertEqual(decoded.sessionId, "codex-1")
    }

    func testProjectTabStateLegacyClaudeDecodeWithoutKind() throws {
        let json = """
        {"id": "tab-claude", "name": "Claude", "isClaude": true, "sessionId": "claude-1"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProjectTabState.self, from: json)

        XCTAssertEqual(decoded.kind, .claude)
        XCTAssertTrue(decoded.isClaude)
        XCTAssertEqual(decoded.sessionId, "claude-1")
    }

    func testSessionCacheKeySeparatesCodexFromClaude() {
        XCTAssertEqual(SessionManager.sessionCacheKey(sessionId: "shared-id", kind: .claude), "shared-id")
        XCTAssertEqual(SessionManager.sessionCacheKey(sessionId: "shared-id", kind: .codex), "codex:shared-id")
        XCTAssertEqual(SessionManager.sessionCacheKey(sessionId: "shared-id", kind: .terminal), "terminal:shared-id")
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

    // MARK: - Symlink path restoration

    func testProjectStatePathSurvivesRoundtripViaProjectItem() throws {
        // Simulate: save state with canonical path, restore via ProjectItem
        let tempDir = NSTemporaryDirectory() + "deckard-state-\(UUID().uuidString)"
        let realDir = tempDir + "/real-project"
        let linkDir = tempDir + "/linked-project"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }
        try FileManager.default.createSymbolicLink(atPath: linkDir, withDestinationPath: realDir)

        // Save state using symlink path (as old Deckard would)
        var state = DeckardState()
        state.projects = [
            ProjectState(id: "p1", path: linkDir, name: "linked-project",
                         selectedTabIndex: 0, tabs: [
                ProjectTabState(id: "t1", name: "Claude", isClaude: true, sessionId: "sess-1")
            ])
        ]

        // Round-trip through JSON (simulates state.json persistence)
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(DeckardState.self, from: data)

        // Simulate restoreOrCreateInitial: ProjectItem resolves the path
        let ps = restored.projects![0]
        let project = ProjectItem(path: ps.path)

        // The resolved path should match the canonical path
        XCTAssertEqual(project.path, realDir,
                       "ProjectItem should resolve symlink from old state.json")

        // Sidebar folder restoration resolves ps.path before comparison
        let resolvedPsPath = (ps.path as NSString).resolvingSymlinksInPath
        XCTAssertEqual(project.path, resolvedPsPath,
                       "Resolved ps.path should match ProjectItem.path for sidebar folder mapping")
    }

    func testProjectStateSavedWithCanonicalPath() throws {
        // When captureState() saves a project that was opened via symlink,
        // the path should be canonical (because ProjectItem.init resolves)
        let tempDir = NSTemporaryDirectory() + "deckard-state-\(UUID().uuidString)"
        let realDir = tempDir + "/real-project"
        let linkDir = tempDir + "/linked-project"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }
        try FileManager.default.createSymbolicLink(atPath: linkDir, withDestinationPath: realDir)

        let project = ProjectItem(path: linkDir)
        // Simulate what captureState() does
        let saved = ProjectState(
            id: project.id.uuidString,
            path: project.path,
            name: project.name,
            selectedTabIndex: 0,
            tabs: []
        )

        XCTAssertEqual(saved.path, realDir,
                       "Saved ProjectState should contain canonical path, not symlink")
    }

    func testOldAndNewStatePathsMatchAfterResolution() throws {
        // Simulate migration: old state has symlink path, new code resolves it
        let tempDir = NSTemporaryDirectory() + "deckard-state-\(UUID().uuidString)"
        let realDir = tempDir + "/real-project"
        let linkDir = tempDir + "/linked-project"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }
        try FileManager.default.createSymbolicLink(atPath: linkDir, withDestinationPath: realDir)

        // Old state (saved with symlink path)
        let oldProjectState = ProjectState(
            id: "p1", path: linkDir, name: "linked-project",
            selectedTabIndex: 0, tabs: []
        )

        // New ProjectItem (opened via symlink, but path is resolved)
        let project = ProjectItem(path: linkDir)

        // restoreSidebarFolders resolves ps.path before comparison
        let resolvedOldPath = (oldProjectState.path as NSString).resolvingSymlinksInPath
        XCTAssertEqual(project.path, resolvedOldPath,
                       "Migration: resolved old state path must match new ProjectItem.path")

        // New state (saved after fix) already has canonical path
        let newProjectState = ProjectState(
            id: "p2", path: project.path, name: project.name,
            selectedTabIndex: 0, tabs: []
        )
        XCTAssertEqual(project.path, newProjectState.path,
                       "Post-fix: saved path is already canonical, direct comparison works")
    }
}

import XCTest
@testable import Deckard

final class SidebarGroupTests: XCTestCase {

    // MARK: - SidebarGroupState Codable roundtrips

    func testSidebarGroupStateRoundtrip() throws {
        let state = SidebarGroupState(
            id: "folder-1",
            name: "My Folder",
            isCollapsed: true,
            projectIds: ["proj-a", "proj-b", "proj-c"]
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SidebarGroupState.self, from: data)

        XCTAssertEqual(decoded.id, "folder-1")
        XCTAssertEqual(decoded.name, "My Folder")
        XCTAssertTrue(decoded.isCollapsed)
        XCTAssertEqual(decoded.projectIds, ["proj-a", "proj-b", "proj-c"])
    }

    func testSidebarGroupStateEmptyProjectIds() throws {
        let state = SidebarGroupState(
            id: "folder-empty",
            name: "Empty Folder",
            isCollapsed: false,
            projectIds: []
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SidebarGroupState.self, from: data)

        XCTAssertEqual(decoded.id, "folder-empty")
        XCTAssertEqual(decoded.name, "Empty Folder")
        XCTAssertFalse(decoded.isCollapsed)
        XCTAssertEqual(decoded.projectIds, [])
    }

    // MARK: - SidebarOrderItem Codable roundtrips

    func testSidebarOrderItemGroupRoundtrip() throws {
        let item = SidebarOrderItem.group("folder-abc")

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(SidebarOrderItem.self, from: data)

        if case .group(let id) = decoded {
            XCTAssertEqual(id, "folder-abc")
        } else {
            XCTFail("Expected .folder case, got \(decoded)")
        }
    }

    func testSidebarOrderItemProjectRoundtrip() throws {
        let item = SidebarOrderItem.project("proj-xyz")

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(SidebarOrderItem.self, from: data)

        if case .project(let id) = decoded {
            XCTAssertEqual(id, "proj-xyz")
        } else {
            XCTFail("Expected .project case, got \(decoded)")
        }
    }

    func testSidebarOrderItemInvalidTypeThrows() throws {
        let json = """
        {"type": "unknown", "id": "some-id"}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(SidebarOrderItem.self, from: json)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                XCTFail("Expected DecodingError.dataCorrupted, got \(error)")
                return
            }
            XCTAssertTrue(context.debugDescription.contains("Unknown sidebar order item type"))
        }
    }

    func testSidebarOrderItemEncodedShape() throws {
        // Verify the JSON shape is {"type": "group", "id": "..."}
        let item = SidebarOrderItem.group("f1")
        let data = try JSONEncoder().encode(item)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: String]

        XCTAssertEqual(dict?["type"], "group")
        XCTAssertEqual(dict?["id"], "f1")
    }

    func testSidebarOrderItemProjectEncodedShape() throws {
        let item = SidebarOrderItem.project("p1")
        let data = try JSONEncoder().encode(item)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: String]

        XCTAssertEqual(dict?["type"], "project")
        XCTAssertEqual(dict?["id"], "p1")
    }

    // MARK: - DeckardState with folders

    func testDeckardStateWithGroupsRoundtrip() throws {
        var state = DeckardState()
        state.sidebarGroups = [
            SidebarGroupState(id: "f1", name: "Work", isCollapsed: false, projectIds: ["p1", "p2"]),
            SidebarGroupState(id: "f2", name: "Personal", isCollapsed: true, projectIds: ["p3"]),
        ]
        state.sidebarOrder = [
            .group("f1"),
            .project("p4"),
            .group("f2"),
        ]
        state.projects = [
            ProjectState(id: "p1", path: "/work/a", name: "a", selectedTabIndex: 0, tabs: []),
            ProjectState(id: "p2", path: "/work/b", name: "b", selectedTabIndex: 0, tabs: []),
            ProjectState(id: "p3", path: "/personal/c", name: "c", selectedTabIndex: 0, tabs: []),
            ProjectState(id: "p4", path: "/other/d", name: "d", selectedTabIndex: 0, tabs: []),
        ]

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DeckardState.self, from: data)

        XCTAssertEqual(decoded.sidebarGroups?.count, 2)
        XCTAssertEqual(decoded.sidebarGroups?[0].name, "Work")
        XCTAssertEqual(decoded.sidebarGroups?[0].projectIds, ["p1", "p2"])
        XCTAssertEqual(decoded.sidebarGroups?[1].name, "Personal")
        XCTAssertTrue(decoded.sidebarGroups?[1].isCollapsed == true)
        XCTAssertEqual(decoded.sidebarOrder?.count, 3)

        // Verify order items
        if case .group(let id) = decoded.sidebarOrder?[0] {
            XCTAssertEqual(id, "f1")
        } else {
            XCTFail("Expected .folder at index 0")
        }
        if case .project(let id) = decoded.sidebarOrder?[1] {
            XCTAssertEqual(id, "p4")
        } else {
            XCTFail("Expected .project at index 1")
        }
        if case .group(let id) = decoded.sidebarOrder?[2] {
            XCTAssertEqual(id, "f2")
        } else {
            XCTFail("Expected .folder at index 2")
        }
    }

    func testDeckardStateNilGroupsBackwardCompat() throws {
        // Simulate a v2 state without folder fields
        var state = DeckardState()
        state.projects = [
            ProjectState(id: "p1", path: "/test", name: "test", selectedTabIndex: 0, tabs: [])
        ]
        // sidebarGroups and sidebarOrder deliberately left nil

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DeckardState.self, from: data)

        XCTAssertNil(decoded.sidebarGroups)
        XCTAssertNil(decoded.sidebarOrder)
        XCTAssertEqual(decoded.projects?.count, 1)
    }

    func testDeckardStateMixedSidebarOrder() throws {
        var state = DeckardState()
        state.sidebarGroups = [
            SidebarGroupState(id: "f1", name: "Folder", isCollapsed: false, projectIds: [])
        ]
        state.sidebarOrder = [
            .project("p1"),
            .group("f1"),
            .project("p2"),
            .project("p3"),
            .group("f1"),  // duplicate folder reference (edge case)
            .project("p4"),
        ]

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DeckardState.self, from: data)

        XCTAssertEqual(decoded.sidebarOrder?.count, 6)

        // Verify alternating types
        if case .project = decoded.sidebarOrder?[0] {} else { XCTFail("Expected .project at 0") }
        if case .group = decoded.sidebarOrder?[1] {} else { XCTFail("Expected .folder at 1") }
        if case .project = decoded.sidebarOrder?[2] {} else { XCTFail("Expected .project at 2") }
        if case .project = decoded.sidebarOrder?[3] {} else { XCTFail("Expected .project at 3") }
        if case .group = decoded.sidebarOrder?[4] {} else { XCTFail("Expected .folder at 4") }
        if case .project = decoded.sidebarOrder?[5] {} else { XCTFail("Expected .project at 5") }
    }

    func testDeckardStateEmptyFoldersAndOrder() throws {
        var state = DeckardState()
        state.sidebarGroups = []
        state.sidebarOrder = []

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DeckardState.self, from: data)

        XCTAssertEqual(decoded.sidebarGroups?.count, 0)
        XCTAssertEqual(decoded.sidebarOrder?.count, 0)
    }

    // MARK: - SidebarGroup data model

    func testSidebarGroupInitDefaults() {
        let folder = SidebarGroup(name: "Test Folder")

        XCTAssertEqual(folder.name, "Test Folder")
        XCTAssertFalse(folder.isCollapsed)
        XCTAssertEqual(folder.projectIds, [])
        XCTAssertNotEqual(folder.id, UUID()) // has a valid UUID
    }

    func testSidebarGroupProjectIdsAddRemove() {
        let folder = SidebarGroup(name: "Folder")
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        folder.projectIds.append(id1)
        folder.projectIds.append(id2)
        folder.projectIds.append(id3)
        XCTAssertEqual(folder.projectIds.count, 3)
        XCTAssertEqual(folder.projectIds, [id1, id2, id3])

        folder.projectIds.removeAll { $0 == id2 }
        XCTAssertEqual(folder.projectIds.count, 2)
        XCTAssertEqual(folder.projectIds, [id1, id3])

        folder.projectIds.removeAll()
        XCTAssertEqual(folder.projectIds.count, 0)
    }

    func testSidebarGroupIsCollapsedToggle() {
        let folder = SidebarGroup(name: "Folder")
        XCTAssertFalse(folder.isCollapsed)

        folder.isCollapsed.toggle()
        XCTAssertTrue(folder.isCollapsed)

        folder.isCollapsed.toggle()
        XCTAssertFalse(folder.isCollapsed)
    }

    func testSidebarGroupFullInit() {
        let id = UUID()
        let pid1 = UUID()
        let pid2 = UUID()
        let folder = SidebarGroup(id: id, name: "Custom", isCollapsed: true, projectIds: [pid1, pid2])

        XCTAssertEqual(folder.id, id)
        XCTAssertEqual(folder.name, "Custom")
        XCTAssertTrue(folder.isCollapsed)
        XCTAssertEqual(folder.projectIds, [pid1, pid2])
    }

    // MARK: - SidebarItem enum

    func testSidebarItemFolderCase() {
        let folder = SidebarGroup(name: "Test")
        let item = SidebarItem.group(folder)

        if case .group(let f) = item {
            XCTAssertTrue(f === folder) // same reference
            XCTAssertEqual(f.name, "Test")
        } else {
            XCTFail("Expected .folder case")
        }
    }

    func testSidebarItemProjectCase() {
        let projectId = UUID()
        let item = SidebarItem.project(projectId)

        if case .project(let id) = item {
            XCTAssertEqual(id, projectId)
        } else {
            XCTFail("Expected .project case")
        }
    }

    func testSidebarItemFolderMutationThroughReference() {
        let folder = SidebarGroup(name: "Before")
        let item = SidebarItem.group(folder)

        // Mutating the folder should be visible through the enum
        folder.name = "After"

        if case .group(let f) = item {
            XCTAssertEqual(f.name, "After")
        } else {
            XCTFail("Expected .folder case")
        }
    }

    // MARK: - ProjectTabState with tmuxSessionName

    func testProjectTabStateWithTmuxSessionName() throws {
        let tab = ProjectTabState(
            id: "tab-1",
            name: "Terminal",
            isClaude: false,
            sessionId: "sess-1",
            tmuxSessionName: "deckard-main-1"
        )

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(ProjectTabState.self, from: data)

        XCTAssertEqual(decoded.id, "tab-1")
        XCTAssertEqual(decoded.name, "Terminal")
        XCTAssertFalse(decoded.isClaude)
        XCTAssertEqual(decoded.sessionId, "sess-1")
        XCTAssertEqual(decoded.tmuxSessionName, "deckard-main-1")
    }

    func testProjectTabStateWithNilTmuxSessionName() throws {
        let tab = ProjectTabState(
            id: "tab-2",
            name: "Claude",
            isClaude: true,
            sessionId: "sess-2",
            tmuxSessionName: nil
        )

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(ProjectTabState.self, from: data)

        XCTAssertEqual(decoded.id, "tab-2")
        XCTAssertEqual(decoded.name, "Claude")
        XCTAssertTrue(decoded.isClaude)
        XCTAssertEqual(decoded.sessionId, "sess-2")
        XCTAssertNil(decoded.tmuxSessionName)
    }

    func testProjectTabStateBackwardCompatNoTmuxField() throws {
        // Simulate JSON without tmuxSessionName field (old format)
        let json = """
        {"id": "tab-3", "name": "Terminal", "isClaude": false}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProjectTabState.self, from: json)

        XCTAssertEqual(decoded.id, "tab-3")
        XCTAssertEqual(decoded.name, "Terminal")
        XCTAssertFalse(decoded.isClaude)
        XCTAssertNil(decoded.sessionId)
        XCTAssertNil(decoded.tmuxSessionName)
    }

    // MARK: - SidebarGroupState edge cases

    func testSidebarGroupStateSpecialCharactersInName() throws {
        let state = SidebarGroupState(
            id: "f-special",
            name: "Work / Personal (2024) & More \u{1F4C1}",
            isCollapsed: false,
            projectIds: ["p1"]
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SidebarGroupState.self, from: data)

        XCTAssertEqual(decoded.name, "Work / Personal (2024) & More \u{1F4C1}")
    }

    func testSidebarGroupStateManyProjectIds() throws {
        let ids = (0..<100).map { "proj-\($0)" }
        let state = SidebarGroupState(
            id: "f-large",
            name: "Large Folder",
            isCollapsed: false,
            projectIds: ids
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SidebarGroupState.self, from: data)

        XCTAssertEqual(decoded.projectIds.count, 100)
        XCTAssertEqual(decoded.projectIds.first, "proj-0")
        XCTAssertEqual(decoded.projectIds.last, "proj-99")
    }

    // MARK: - SidebarOrderItem array roundtrip

    func testSidebarOrderItemArrayRoundtrip() throws {
        let items: [SidebarOrderItem] = [
            .group("f1"),
            .project("p1"),
            .project("p2"),
            .group("f2"),
            .project("p3"),
        ]

        let data = try JSONEncoder().encode(items)
        let decoded = try JSONDecoder().decode([SidebarOrderItem].self, from: data)

        XCTAssertEqual(decoded.count, 5)

        if case .group(let id) = decoded[0] { XCTAssertEqual(id, "f1") }
        else { XCTFail("Expected .folder at 0") }

        if case .project(let id) = decoded[1] { XCTAssertEqual(id, "p1") }
        else { XCTFail("Expected .project at 1") }

        if case .project(let id) = decoded[2] { XCTAssertEqual(id, "p2") }
        else { XCTFail("Expected .project at 2") }

        if case .group(let id) = decoded[3] { XCTAssertEqual(id, "f2") }
        else { XCTFail("Expected .folder at 3") }

        if case .project(let id) = decoded[4] { XCTAssertEqual(id, "p3") }
        else { XCTFail("Expected .project at 4") }
    }

    // MARK: - Legacy v2 state.json migration

    func testLegacySidebarFoldersKeyDecodesAsGroups() throws {
        // v2 state.json wrote sidebar groups under the key "sidebarFolders".
        // The new decoder must accept that key and surface them as sidebarGroups.
        let json = """
        {
            "version": 2,
            "selectedTabIndex": 0,
            "sidebarFolders": [
                {"id": "f1", "name": "Work", "isCollapsed": false, "projectIds": ["p1"]}
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DeckardState.self, from: json)
        XCTAssertEqual(decoded.sidebarGroups?.count, 1)
        XCTAssertEqual(decoded.sidebarGroups?.first?.name, "Work")
        XCTAssertEqual(decoded.sidebarGroups?.first?.projectIds, ["p1"])
    }

    func testLegacyFolderDiscriminatorDecodesAsGroup() throws {
        // v2 sidebarOrder items used {"type": "folder", "id": "..."}.
        // The new decoder must accept that and surface as .group.
        let json = """
        [
            {"type": "folder", "id": "f1"},
            {"type": "project", "id": "p1"},
            {"type": "folder", "id": "f2"}
        ]
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([SidebarOrderItem].self, from: json)
        XCTAssertEqual(decoded.count, 3)
        if case .group(let id) = decoded[0] { XCTAssertEqual(id, "f1") }
        else { XCTFail("Expected .group at 0") }
        if case .project(let id) = decoded[1] { XCTAssertEqual(id, "p1") }
        else { XCTFail("Expected .project at 1") }
        if case .group(let id) = decoded[2] { XCTAssertEqual(id, "f2") }
        else { XCTFail("Expected .group at 2") }
    }

    func testEncoderWritesNewKeysOnly() throws {
        // After a roundtrip, the JSON must use the new keys (sidebarGroups, "group"),
        // never the legacy ones — otherwise downgrade would silently work and obscure
        // when the migration happened.
        var state = DeckardState()
        state.sidebarGroups = [SidebarGroupState(id: "f1", name: "g", isCollapsed: false, projectIds: [])]
        state.sidebarOrder = [.group("f1")]

        let data = try JSONEncoder().encode(state)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"sidebarGroups\""))
        XCTAssertFalse(json.contains("\"sidebarFolders\""))
        XCTAssertTrue(json.contains("\"group\""))
        // Sanity: the discriminator value "folder" should not appear in encoded output.
        // (We can't assert it's totally absent because group names could include the word,
        // so check the specific key/value pair shape.)
        XCTAssertFalse(json.contains("\"type\":\"folder\""))
        XCTAssertFalse(json.contains("\"type\" : \"folder\""))
    }
}

import XCTest
@testable import Deckard

final class SidebarGroupTests: XCTestCase {

    // MARK: - SidebarGroupState Codable roundtrips

    func testSidebarGroupStateRoundtrip() throws {
        let state = SidebarGroupState(
            id: "group-1",
            name: "My Group",
            isCollapsed: true,
            workspaceIds: ["proj-a", "proj-b", "proj-c"]
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SidebarGroupState.self, from: data)

        XCTAssertEqual(decoded.id, "group-1")
        XCTAssertEqual(decoded.name, "My Group")
        XCTAssertTrue(decoded.isCollapsed)
        XCTAssertEqual(decoded.workspaceIds, ["proj-a", "proj-b", "proj-c"])
    }

    func testSidebarGroupStateEmptyWorkspaceIds() throws {
        let state = SidebarGroupState(
            id: "group-empty",
            name: "Empty Group",
            isCollapsed: false,
            workspaceIds: []
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SidebarGroupState.self, from: data)

        XCTAssertEqual(decoded.id, "group-empty")
        XCTAssertEqual(decoded.name, "Empty Group")
        XCTAssertFalse(decoded.isCollapsed)
        XCTAssertEqual(decoded.workspaceIds, [])
    }

    // MARK: - SidebarOrderItem Codable roundtrips

    func testSidebarOrderItemGroupRoundtrip() throws {
        let item = SidebarOrderItem.group("group-abc")

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(SidebarOrderItem.self, from: data)

        if case .group(let id) = decoded {
            XCTAssertEqual(id, "group-abc")
        } else {
            XCTFail("Expected .group case, got \(decoded)")
        }
    }

    func testSidebarOrderItemWorkspaceRoundtrip() throws {
        let item = SidebarOrderItem.workspace("proj-xyz")

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(SidebarOrderItem.self, from: data)

        if case .workspace(let id) = decoded {
            XCTAssertEqual(id, "proj-xyz")
        } else {
            XCTFail("Expected .workspace case, got \(decoded)")
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

    func testSidebarOrderItemWorkspaceEncodedShape() throws {
        let item = SidebarOrderItem.workspace("p1")
        let data = try JSONEncoder().encode(item)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: String]

        XCTAssertEqual(dict?["type"], "project")
        XCTAssertEqual(dict?["id"], "p1")
    }

    // MARK: - DeckardState with groups

    func testDeckardStateWithGroupsRoundtrip() throws {
        var state = DeckardState()
        state.sidebarGroups = [
            SidebarGroupState(id: "f1", name: "Work", isCollapsed: false, workspaceIds: ["p1", "p2"]),
            SidebarGroupState(id: "f2", name: "Personal", isCollapsed: true, workspaceIds: ["p3"]),
        ]
        state.sidebarOrder = [
            .group("f1"),
            .workspace("p4"),
            .group("f2"),
        ]
        state.workspaces = [
            WorkspaceState(id: "p1", path: "/work/a", name: "a", selectedTabIndex: 0, tabs: []),
            WorkspaceState(id: "p2", path: "/work/b", name: "b", selectedTabIndex: 0, tabs: []),
            WorkspaceState(id: "p3", path: "/personal/c", name: "c", selectedTabIndex: 0, tabs: []),
            WorkspaceState(id: "p4", path: "/other/d", name: "d", selectedTabIndex: 0, tabs: []),
        ]

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DeckardState.self, from: data)

        XCTAssertEqual(decoded.sidebarGroups?.count, 2)
        XCTAssertEqual(decoded.sidebarGroups?[0].name, "Work")
        XCTAssertEqual(decoded.sidebarGroups?[0].workspaceIds, ["p1", "p2"])
        XCTAssertEqual(decoded.sidebarGroups?[1].name, "Personal")
        XCTAssertTrue(decoded.sidebarGroups?[1].isCollapsed == true)
        XCTAssertEqual(decoded.sidebarOrder?.count, 3)

        // Verify order items
        if case .group(let id) = decoded.sidebarOrder?[0] {
            XCTAssertEqual(id, "f1")
        } else {
            XCTFail("Expected .group at index 0")
        }
        if case .workspace(let id) = decoded.sidebarOrder?[1] {
            XCTAssertEqual(id, "p4")
        } else {
            XCTFail("Expected .workspace at index 1")
        }
        if case .group(let id) = decoded.sidebarOrder?[2] {
            XCTAssertEqual(id, "f2")
        } else {
            XCTFail("Expected .group at index 2")
        }
    }

    func testDeckardStateNilGroupsBackwardCompat() throws {
        // Simulate a v2 state without group fields
        var state = DeckardState()
        state.workspaces = [
            WorkspaceState(id: "p1", path: "/test", name: "test", selectedTabIndex: 0, tabs: [])
        ]
        // sidebarGroups and sidebarOrder deliberately left nil

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DeckardState.self, from: data)

        XCTAssertNil(decoded.sidebarGroups)
        XCTAssertNil(decoded.sidebarOrder)
        XCTAssertEqual(decoded.workspaces?.count, 1)
    }

    func testDeckardStateMixedSidebarOrder() throws {
        var state = DeckardState()
        state.sidebarGroups = [
            SidebarGroupState(id: "f1", name: "Group", isCollapsed: false, workspaceIds: [])
        ]
        state.sidebarOrder = [
            .workspace("p1"),
            .group("f1"),
            .workspace("p2"),
            .workspace("p3"),
            .group("f1"),  // duplicate group reference (edge case)
            .workspace("p4"),
        ]

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DeckardState.self, from: data)

        XCTAssertEqual(decoded.sidebarOrder?.count, 6)

        // Verify alternating types
        if case .workspace = decoded.sidebarOrder?[0] {} else { XCTFail("Expected .workspace at 0") }
        if case .group = decoded.sidebarOrder?[1] {} else { XCTFail("Expected .group at 1") }
        if case .workspace = decoded.sidebarOrder?[2] {} else { XCTFail("Expected .workspace at 2") }
        if case .workspace = decoded.sidebarOrder?[3] {} else { XCTFail("Expected .workspace at 3") }
        if case .group = decoded.sidebarOrder?[4] {} else { XCTFail("Expected .group at 4") }
        if case .workspace = decoded.sidebarOrder?[5] {} else { XCTFail("Expected .workspace at 5") }
    }

    func testDeckardStateEmptyGroupsAndOrder() throws {
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
        let group = SidebarGroup(name: "Test Group")

        XCTAssertEqual(group.name, "Test Group")
        XCTAssertFalse(group.isCollapsed)
        XCTAssertEqual(group.workspaceIds, [])
        XCTAssertNotEqual(group.id, UUID()) // has a valid UUID
    }

    func testSidebarGroupWorkspaceIdsAddRemove() {
        let group = SidebarGroup(name: "Group")
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        group.workspaceIds.append(id1)
        group.workspaceIds.append(id2)
        group.workspaceIds.append(id3)
        XCTAssertEqual(group.workspaceIds.count, 3)
        XCTAssertEqual(group.workspaceIds, [id1, id2, id3])

        group.workspaceIds.removeAll { $0 == id2 }
        XCTAssertEqual(group.workspaceIds.count, 2)
        XCTAssertEqual(group.workspaceIds, [id1, id3])

        group.workspaceIds.removeAll()
        XCTAssertEqual(group.workspaceIds.count, 0)
    }

    func testSidebarGroupIsCollapsedToggle() {
        let group = SidebarGroup(name: "Group")
        XCTAssertFalse(group.isCollapsed)

        group.isCollapsed.toggle()
        XCTAssertTrue(group.isCollapsed)

        group.isCollapsed.toggle()
        XCTAssertFalse(group.isCollapsed)
    }

    func testSidebarGroupFullInit() {
        let id = UUID()
        let pid1 = UUID()
        let pid2 = UUID()
        let group = SidebarGroup(id: id, name: "Custom", isCollapsed: true, workspaceIds: [pid1, pid2])

        XCTAssertEqual(group.id, id)
        XCTAssertEqual(group.name, "Custom")
        XCTAssertTrue(group.isCollapsed)
        XCTAssertEqual(group.workspaceIds, [pid1, pid2])
    }

    // MARK: - SidebarItem enum

    func testSidebarItemGroupCase() {
        let group = SidebarGroup(name: "Test")
        let item = SidebarItem.group(group)

        if case .group(let f) = item {
            XCTAssertTrue(f === group) // same reference
            XCTAssertEqual(f.name, "Test")
        } else {
            XCTFail("Expected .group case")
        }
    }

    func testSidebarItemWorkspaceCase() {
        let workspaceId = UUID()
        let item = SidebarItem.workspace(workspaceId)

        if case .workspace(let id) = item {
            XCTAssertEqual(id, workspaceId)
        } else {
            XCTFail("Expected .workspace case")
        }
    }

    func testSidebarItemGroupMutationThroughReference() {
        let group = SidebarGroup(name: "Before")
        let item = SidebarItem.group(group)

        // Mutating the group should be visible through the enum
        group.name = "After"

        if case .group(let f) = item {
            XCTAssertEqual(f.name, "After")
        } else {
            XCTFail("Expected .group case")
        }
    }

    // MARK: - WorkspaceTabState with tmuxSessionName

    func testWorkspaceTabStateWithTmuxSessionName() throws {
        let tab = WorkspaceTabState(
            id: "tab-1",
            name: "Terminal",
            isClaude: false,
            sessionId: "sess-1",
            tmuxSessionName: "deckard-main-1"
        )

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(WorkspaceTabState.self, from: data)

        XCTAssertEqual(decoded.id, "tab-1")
        XCTAssertEqual(decoded.name, "Terminal")
        XCTAssertFalse(decoded.isClaude)
        XCTAssertEqual(decoded.sessionId, "sess-1")
        XCTAssertEqual(decoded.tmuxSessionName, "deckard-main-1")
    }

    func testWorkspaceTabStateWithNilTmuxSessionName() throws {
        let tab = WorkspaceTabState(
            id: "tab-2",
            name: "Claude",
            isClaude: true,
            sessionId: "sess-2",
            tmuxSessionName: nil
        )

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(WorkspaceTabState.self, from: data)

        XCTAssertEqual(decoded.id, "tab-2")
        XCTAssertEqual(decoded.name, "Claude")
        XCTAssertTrue(decoded.isClaude)
        XCTAssertEqual(decoded.sessionId, "sess-2")
        XCTAssertNil(decoded.tmuxSessionName)
    }

    func testWorkspaceTabStateBackwardCompatNoTmuxField() throws {
        // Simulate JSON without tmuxSessionName field (old format)
        let json = """
        {"id": "tab-3", "name": "Terminal", "isClaude": false}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(WorkspaceTabState.self, from: json)

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
            workspaceIds: ["p1"]
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SidebarGroupState.self, from: data)

        XCTAssertEqual(decoded.name, "Work / Personal (2024) & More \u{1F4C1}")
    }

    func testSidebarGroupStateManyWorkspaceIds() throws {
        let ids = (0..<100).map { "proj-\($0)" }
        let state = SidebarGroupState(
            id: "f-large",
            name: "Large Group",
            isCollapsed: false,
            workspaceIds: ids
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SidebarGroupState.self, from: data)

        XCTAssertEqual(decoded.workspaceIds.count, 100)
        XCTAssertEqual(decoded.workspaceIds.first, "proj-0")
        XCTAssertEqual(decoded.workspaceIds.last, "proj-99")
    }

    // MARK: - SidebarOrderItem array roundtrip

    func testSidebarOrderItemArrayRoundtrip() throws {
        let items: [SidebarOrderItem] = [
            .group("f1"),
            .workspace("p1"),
            .workspace("p2"),
            .group("f2"),
            .workspace("p3"),
        ]

        let data = try JSONEncoder().encode(items)
        let decoded = try JSONDecoder().decode([SidebarOrderItem].self, from: data)

        XCTAssertEqual(decoded.count, 5)

        if case .group(let id) = decoded[0] { XCTAssertEqual(id, "f1") }
        else { XCTFail("Expected .group at 0") }

        if case .workspace(let id) = decoded[1] { XCTAssertEqual(id, "p1") }
        else { XCTFail("Expected .workspace at 1") }

        if case .workspace(let id) = decoded[2] { XCTAssertEqual(id, "p2") }
        else { XCTFail("Expected .workspace at 2") }

        if case .group(let id) = decoded[3] { XCTAssertEqual(id, "f2") }
        else { XCTFail("Expected .group at 3") }

        if case .workspace(let id) = decoded[4] { XCTAssertEqual(id, "p3") }
        else { XCTFail("Expected .workspace at 4") }
    }

    // MARK: - Legacy v2 state.json migration

    func testLegacySidebarFoldersKeyDecodesAsGroups() throws {
        // v2 state.json wrote sidebar groups under the outer key "sidebarFolders"
        // and members under the inner key "projectIds". Both legacy keys must
        // decode cleanly into the new sidebarGroups/workspaceIds shape.
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
        XCTAssertEqual(decoded.sidebarGroups?.first?.workspaceIds, ["p1"])
    }

    func testLegacyProjectsKeyDecodesAsWorkspaces() throws {
        // v2 state.json wrote workspaces under the outer key "projects".
        let json = """
        {
            "version": 2,
            "selectedTabIndex": 1,
            "projects": [
                {"id": "p1", "path": "/work/a", "name": "a", "selectedTabIndex": 0, "tabs": []},
                {"id": "p2", "path": "/work/b", "name": "b", "selectedTabIndex": 0, "tabs": []}
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DeckardState.self, from: json)
        XCTAssertEqual(decoded.workspaces?.count, 2)
        XCTAssertEqual(decoded.workspaces?[0].name, "a")
        XCTAssertEqual(decoded.workspaces?[1].path, "/work/b")
    }

    func testFullV2StateRoundtripsToV3OnEncode() throws {
        // A complete v2 state.json — every legacy key combined — decodes cleanly
        // and re-encodes using only the new keys. This is the actual upgrade path.
        let v2json = """
        {
            "version": 2,
            "selectedTabIndex": 0,
            "projects": [
                {"id": "p1", "path": "/a", "name": "a", "selectedTabIndex": 0, "tabs": []}
            ],
            "sidebarFolders": [
                {"id": "f1", "name": "Work", "isCollapsed": false, "projectIds": ["p1"]}
            ],
            "sidebarOrder": [
                {"type": "folder", "id": "f1"}
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DeckardState.self, from: v2json)
        let reencoded = try JSONEncoder().encode(decoded)
        let reencodedString = String(data: reencoded, encoding: .utf8) ?? ""

        XCTAssertTrue(reencodedString.contains("\"workspaces\""))
        XCTAssertTrue(reencodedString.contains("\"sidebarGroups\""))
        XCTAssertTrue(reencodedString.contains("\"workspaceIds\""))
        // sidebarOrder discriminator was migrated from "folder" to "group"
        XCTAssertTrue(reencodedString.contains("\"type\":\"group\""))
        XCTAssertFalse(reencodedString.contains("\"projects\""))
        XCTAssertFalse(reencodedString.contains("\"sidebarFolders\""))
        XCTAssertFalse(reencodedString.contains("\"projectIds\""))
        XCTAssertFalse(reencodedString.contains("\"type\":\"folder\""))
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
        if case .workspace(let id) = decoded[1] { XCTAssertEqual(id, "p1") }
        else { XCTFail("Expected .workspace at 1") }
        if case .group(let id) = decoded[2] { XCTAssertEqual(id, "f2") }
        else { XCTFail("Expected .group at 2") }
    }

    func testEncoderWritesNewKeysOnly() throws {
        // After a roundtrip, the JSON must use the new keys (sidebarGroups, "group"
        // discriminator), never the legacy ones — otherwise downgrade would silently
        // work and obscure when the migration happened.
        var state = DeckardState()
        state.sidebarGroups = [SidebarGroupState(id: "f1", name: "g", isCollapsed: false, workspaceIds: [])]
        state.sidebarOrder = [.group("f1")]

        let data = try JSONEncoder().encode(state)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"sidebarGroups\""))
        XCTAssertFalse(json.contains("\"sidebarFolders\""))
        XCTAssertTrue(json.contains("\"type\":\"group\""))
        // The legacy "folder" discriminator must not appear in encoded output.
        XCTAssertFalse(json.contains("\"type\":\"folder\""))
        XCTAssertFalse(json.contains("\"type\" : \"folder\""))
    }
}

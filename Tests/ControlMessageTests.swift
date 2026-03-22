import XCTest
@testable import Deckard

final class ControlMessageTests: XCTestCase {

    // MARK: - ControlMessage Decoding

    func testDecodePingCommand() throws {
        let json = """
        {"command": "ping"}
        """
        let msg = try JSONDecoder().decode(ControlMessage.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(msg.command, "ping")
        XCTAssertNil(msg.surfaceId)
        XCTAssertNil(msg.pid)
    }

    func testDecodeRegisterPid() throws {
        let json = """
        {"command": "register-pid", "surfaceId": "ABC-123", "pid": 12345}
        """
        let msg = try JSONDecoder().decode(ControlMessage.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(msg.command, "register-pid")
        XCTAssertEqual(msg.surfaceId, "ABC-123")
        XCTAssertEqual(msg.pid, 12345)
    }

    func testDecodeHookStop() throws {
        let json = """
        {"command": "hook.stop", "surfaceId": "surf-1"}
        """
        let msg = try JSONDecoder().decode(ControlMessage.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(msg.command, "hook.stop")
        XCTAssertEqual(msg.surfaceId, "surf-1")
    }

    func testDecodeHookSessionStart() throws {
        let json = """
        {"command": "hook.session-start", "surfaceId": "surf-1", "sessionId": "sess-abc"}
        """
        let msg = try JSONDecoder().decode(ControlMessage.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(msg.command, "hook.session-start")
        XCTAssertEqual(msg.sessionId, "sess-abc")
    }

    func testDecodeListTabs() throws {
        let json = """
        {"command": "list-tabs"}
        """
        let msg = try JSONDecoder().decode(ControlMessage.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(msg.command, "list-tabs")
    }

    func testDecodeRenameTab() throws {
        let json = """
        {"command": "rename-tab", "tabId": "tab-123", "name": "My Tab"}
        """
        let msg = try JSONDecoder().decode(ControlMessage.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(msg.command, "rename-tab")
        XCTAssertEqual(msg.tabId, "tab-123")
        XCTAssertEqual(msg.name, "My Tab")
    }

    func testDecodeCreateTab() throws {
        let json = """
        {"command": "create-tab", "workingDirectory": "/Users/test/project"}
        """
        let msg = try JSONDecoder().decode(ControlMessage.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(msg.command, "create-tab")
        XCTAssertEqual(msg.workingDirectory, "/Users/test/project")
    }

    func testDecodeHookNotification() throws {
        let json = """
        {"command": "hook.notification", "surfaceId": "surf-1", "notificationType": "permission_required", "message": "Approve?"}
        """
        let msg = try JSONDecoder().decode(ControlMessage.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(msg.command, "hook.notification")
        XCTAssertEqual(msg.notificationType, "permission_required")
        XCTAssertEqual(msg.message, "Approve?")
    }

    // MARK: - ControlResponse Encoding

    func testEncodeSuccessResponse() throws {
        let resp = ControlResponse(ok: true)
        let data = try JSONEncoder().encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertNil(json["error"])
    }

    func testEncodeErrorResponse() throws {
        let resp = ControlResponse(ok: false, error: "unknown command")
        let data = try JSONEncoder().encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["error"] as? String, "unknown command")
    }

    func testEncodeResponseWithMessage() throws {
        let resp = ControlResponse(ok: true, message: "pong")
        let data = try JSONEncoder().encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["message"] as? String, "pong")
    }

    func testEncodeResponseWithTabs() throws {
        let tabs = [
            TabInfo(id: "t1", name: "Claude", isClaude: true, isMaster: false, sessionId: "s1", badgeState: "thinking", workingDirectory: "/test"),
            TabInfo(id: "t2", name: "Terminal", isClaude: false, isMaster: false, sessionId: nil, badgeState: "none", workingDirectory: nil),
        ]
        let resp = ControlResponse(ok: true, tabs: tabs)
        let data = try JSONEncoder().encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let tabsArray = json["tabs"] as! [[String: Any]]
        XCTAssertEqual(tabsArray.count, 2)
        XCTAssertEqual(tabsArray[0]["name"] as? String, "Claude")
        XCTAssertEqual(tabsArray[0]["isClaude"] as? Bool, true)
        XCTAssertEqual(tabsArray[1]["isClaude"] as? Bool, false)
    }

    // MARK: - TabInfo Roundtrip

    func testTabInfoRoundtrip() throws {
        let tab = TabInfo(id: "t1", name: "Claude", isClaude: true, isMaster: true, sessionId: "sess-1", badgeState: "thinking", workingDirectory: "/home")
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(TabInfo.self, from: data)

        XCTAssertEqual(decoded.id, "t1")
        XCTAssertEqual(decoded.name, "Claude")
        XCTAssertTrue(decoded.isClaude)
        XCTAssertTrue(decoded.isMaster)
        XCTAssertEqual(decoded.sessionId, "sess-1")
        XCTAssertEqual(decoded.badgeState, "thinking")
        XCTAssertEqual(decoded.workingDirectory, "/home")
    }

    // MARK: - Optional fields

    func testControlMessageOptionalFields() throws {
        let json = """
        {"command": "focus-tab", "tabId": "abc"}
        """
        let msg = try JSONDecoder().decode(ControlMessage.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(msg.command, "focus-tab")
        XCTAssertEqual(msg.tabId, "abc")
        XCTAssertNil(msg.surfaceId)
        XCTAssertNil(msg.sessionId)
        XCTAssertNil(msg.pid)
        XCTAssertNil(msg.notificationType)
        XCTAssertNil(msg.message)
        XCTAssertNil(msg.workingDirectory)
        XCTAssertNil(msg.name)
        XCTAssertNil(msg.key)
        XCTAssertNil(msg.value)
    }
}

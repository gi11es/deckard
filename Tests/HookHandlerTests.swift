import XCTest
@testable import Deckard

final class HookHandlerTests: XCTestCase {

    private var handler: HookHandler!

    override func setUp() {
        super.setUp()
        handler = HookHandler()
        // No window controller attached — tests verify message routing and response format
    }

    override func tearDown() {
        handler = nil
        super.tearDown()
    }

    // MARK: - Ping

    func testPingReturnsPong() {
        let msg = ControlMessage(command: "ping")
        let expectation = expectation(description: "ping reply")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.message, "pong")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - Register PID

    func testRegisterPidReturnsOk() {
        let msg = ControlMessage(command: "register-pid", surfaceId: "surf-1", pid: 12345)
        let expectation = expectation(description: "register-pid reply")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - Hook.stop

    func testHookStopReturnsOk() {
        let msg = ControlMessage(command: "hook.stop", surfaceId: "surf-1")
        let expectation = expectation(description: "hook.stop reply")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - Hook.stop-failure

    func testHookStopFailureReturnsOk() {
        let msg = ControlMessage(command: "hook.stop-failure", surfaceId: "surf-1")
        let expectation = expectation(description: "hook.stop-failure reply")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - Hook.session-start

    func testHookSessionStartReturnsOk() {
        var msg = ControlMessage(command: "hook.session-start")
        msg.surfaceId = "surf-1"
        msg.sessionId = "sess-abc"

        let expectation = expectation(description: "hook.session-start reply")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - List tabs (no window controller)

    func testListTabsWithoutControllerReturnsEmptyTabs() {
        let msg = ControlMessage(command: "list-tabs")
        let expectation = expectation(description: "list-tabs reply")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.tabs?.count ?? 0, 0)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - Rename tab

    func testRenameTabReturnsOk() {
        var msg = ControlMessage(command: "rename-tab")
        msg.tabId = "tab-1"
        msg.name = "New Name"

        let expectation = expectation(description: "rename-tab reply")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - Close tab

    func testCloseTabReturnsOk() {
        var msg = ControlMessage(command: "close-tab")
        msg.tabId = "tab-1"

        let expectation = expectation(description: "close-tab reply")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - Focus tab

    func testFocusTabReturnsOk() {
        var msg = ControlMessage(command: "focus-tab")
        msg.tabId = UUID().uuidString

        let expectation = expectation(description: "focus-tab reply")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - Unknown command

    func testUnknownCommandReturnsError() {
        let msg = ControlMessage(command: "unknown-command-xyz")
        let expectation = expectation(description: "unknown command reply")

        handler.handle(msg) { response in
            XCTAssertFalse(response.ok)
            XCTAssertNotNil(response.error)
            XCTAssertTrue(response.error?.contains("unknown command") == true)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - Hook notification

    func testHookNotificationReturnsOk() {
        var msg = ControlMessage(command: "hook.notification")
        msg.surfaceId = "surf-1"
        msg.notificationType = "permission_required"

        let expectation = expectation(description: "hook.notification reply")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - Hook user-prompt-submit

    func testHookUserPromptSubmitReturnsOk() {
        var msg = ControlMessage(command: "hook.user-prompt-submit")
        msg.surfaceId = "surf-1"

        let expectation = expectation(description: "hook.user-prompt-submit reply")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - Hook pre-tool-use

    func testHookPreToolUseReturnsOk() {
        var msg = ControlMessage(command: "hook.pre-tool-use")
        msg.surfaceId = "surf-1"

        let expectation = expectation(description: "hook.pre-tool-use reply")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - Hook post-tool-use

    func testHookPostToolUseReturnsOk() {
        let msg = ControlMessage(command: "hook.post-tool-use")
        let expectation = expectation(description: "hook.post-tool-use reply")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    // MARK: - Rate limit forwarding

    func testHookStopWithRateLimitsForwardsToQuotaMonitor() {
        QuotaMonitor.shared.resetForTesting()

        var msg = ControlMessage(command: "hook.stop")
        msg.surfaceId = "surf-1"
        msg.fiveHourUsed = 72.0
        msg.fiveHourResetsAt = 1774466400
        msg.sevenDayUsed = 35.0
        msg.sevenDayResetsAt = 1774900800

        let expectation = expectation(description: "hook.stop with rate limits")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)

        let snapshot = QuotaMonitor.shared.latest
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.fiveHourUsed, 72.0)
        XCTAssertEqual(snapshot?.sevenDayUsed, 35.0)
        XCTAssertNotNil(snapshot?.fiveHourResetsAt)
        XCTAssertNotNil(snapshot?.sevenDayResetsAt)
    }

    func testHookStopWithoutRateLimitsDoesNotClearQuotaMonitor() {
        QuotaMonitor.shared.resetForTesting()
        QuotaMonitor.shared.update(fiveHourUsed: 50.0, fiveHourResetsAt: nil,
                                   sevenDayUsed: 20.0, sevenDayResetsAt: nil)

        let msg = ControlMessage(command: "hook.stop", surfaceId: "surf-1")
        let expectation = expectation(description: "hook.stop without rate limits")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)

        // QuotaMonitor should still have the previous values
        XCTAssertEqual(QuotaMonitor.shared.latest?.fiveHourUsed, 50.0)
    }

    // MARK: - Create tab

    func testCreateTabReturnsOk() {
        var msg = ControlMessage(command: "create-tab")
        msg.workingDirectory = "/Users/test/workspace"

        let expectation = expectation(description: "create-tab reply")

        handler.handle(msg) { response in
            XCTAssertTrue(response.ok)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }
}

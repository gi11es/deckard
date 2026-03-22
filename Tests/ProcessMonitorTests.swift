import XCTest
@testable import Deckard

final class ProcessMonitorTests: XCTestCase {

    // MARK: - ActivityInfo.isActive

    func testActivityInfoIdleByDefault() {
        let info = ProcessMonitor.ActivityInfo()
        XCTAssertFalse(info.isActive)
    }

    func testActivityInfoCpuActive() {
        let info = ProcessMonitor.ActivityInfo(cpu: true, disk: false)
        XCTAssertTrue(info.isActive)
    }

    func testActivityInfoDiskActive() {
        let info = ProcessMonitor.ActivityInfo(cpu: false, disk: true)
        XCTAssertTrue(info.isActive)
    }

    func testActivityInfoBothActive() {
        let info = ProcessMonitor.ActivityInfo(cpu: true, disk: true)
        XCTAssertTrue(info.isActive)
    }

    func testActivityInfoNeitherActive() {
        let info = ProcessMonitor.ActivityInfo(cpu: false, disk: false)
        XCTAssertFalse(info.isActive)
    }

    // MARK: - ActivityInfo.description

    func testActivityInfoDescriptionBusy() {
        let info = ProcessMonitor.ActivityInfo(cpu: true, disk: false)
        XCTAssertEqual(info.description, "Busy")
    }

    func testActivityInfoDescriptionIdle() {
        let info = ProcessMonitor.ActivityInfo(cpu: false, disk: false)
        XCTAssertEqual(info.description, "Idle")
    }

    // MARK: - ActivityInfo Equality

    func testActivityInfoEquality() {
        let a = ProcessMonitor.ActivityInfo(cpu: true, disk: false)
        let b = ProcessMonitor.ActivityInfo(cpu: true, disk: false)
        XCTAssertEqual(a, b)
    }

    func testActivityInfoInequality() {
        let a = ProcessMonitor.ActivityInfo(cpu: true, disk: false)
        let b = ProcessMonitor.ActivityInfo(cpu: false, disk: true)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Register shell PID

    func testRegisterShellPidStoresMapping() {
        let monitor = ProcessMonitor.shared
        let surfaceId = UUID().uuidString

        // Register a PID — this just stores the mapping, shouldn't crash
        monitor.registerShellPid(99999, forSurface: surfaceId)

        // Poll with empty tabs should not crash
        let results = monitor.poll(tabs: [])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Poll with no tabs

    func testPollWithNoTabsReturnsEmpty() {
        let monitor = ProcessMonitor.shared
        let results = monitor.poll(tabs: [])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - TabInfo construction

    func testTabInfoConstruction() {
        let uuid = UUID()
        let tabInfo = ProcessMonitor.TabInfo(
            surfaceId: uuid,
            isClaude: true,
            name: "Claude",
            projectPath: "/Users/test/project"
        )

        XCTAssertEqual(tabInfo.surfaceId, uuid)
        XCTAssertTrue(tabInfo.isClaude)
        XCTAssertEqual(tabInfo.name, "Claude")
        XCTAssertEqual(tabInfo.projectPath, "/Users/test/project")
    }
}

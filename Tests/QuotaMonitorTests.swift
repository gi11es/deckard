import XCTest
@testable import Deckard

final class QuotaMonitorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        QuotaMonitor.shared.resetForTesting()
    }

    override func tearDown() {
        QuotaMonitor.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Update stores snapshot

    func testUpdateStoresSnapshot() {
        QuotaMonitor.shared.update(
            fiveHourUsed: 72.0,
            fiveHourResetsAt: 1774466400,
            sevenDayUsed: 35.0,
            sevenDayResetsAt: 1774900800)

        let snap = QuotaMonitor.shared.latest
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.fiveHourUsed, 72.0)
        XCTAssertEqual(snap?.sevenDayUsed, 35.0)
        XCTAssertNotNil(snap?.fiveHourResetsAt)
        XCTAssertNotNil(snap?.sevenDayResetsAt)
        XCTAssertNotNil(snap?.lastUpdated)
    }

    // MARK: - Update posts notification

    func testUpdatePostsNotification() {
        let expectation = expectation(forNotification: QuotaMonitor.quotaDidChange, object: QuotaMonitor.shared)

        QuotaMonitor.shared.update(
            fiveHourUsed: 10.0,
            fiveHourResetsAt: nil,
            sevenDayUsed: nil,
            sevenDayResetsAt: nil)

        waitForExpectations(timeout: 2)
    }

    // MARK: - Partial update merges

    func testPartialUpdateMerges() {
        QuotaMonitor.shared.update(
            fiveHourUsed: 50.0,
            fiveHourResetsAt: 1774466400,
            sevenDayUsed: 20.0,
            sevenDayResetsAt: 1774900800)

        // Partial update — only five-hour changes
        QuotaMonitor.shared.update(
            fiveHourUsed: 60.0,
            fiveHourResetsAt: nil,
            sevenDayUsed: nil,
            sevenDayResetsAt: nil)

        let snap = QuotaMonitor.shared.latest
        XCTAssertEqual(snap?.fiveHourUsed, 60.0)
        // Seven-day should still be from the first update
        XCTAssertEqual(snap?.sevenDayUsed, 20.0)
        // ResetsAt should be preserved (not overwritten with nil)
        XCTAssertNotNil(snap?.fiveHourResetsAt)
        XCTAssertNotNil(snap?.sevenDayResetsAt)
    }

    // MARK: - Sparkline ring buffer

    func testSparklineStartsEmpty() {
        XCTAssertTrue(QuotaMonitor.shared.sparklineData.isEmpty)
    }

    // MARK: - Reset for testing

    func testResetClearsAllState() {
        QuotaMonitor.shared.update(
            fiveHourUsed: 99.0,
            fiveHourResetsAt: 1774466400,
            sevenDayUsed: 99.0,
            sevenDayResetsAt: 1774900800)

        QuotaMonitor.shared.resetForTesting()

        XCTAssertNil(QuotaMonitor.shared.latest)
        XCTAssertNil(QuotaMonitor.shared.tokenRate)
        XCTAssertTrue(QuotaMonitor.shared.sparklineData.isEmpty)
    }

    // MARK: - Compute token rate with no files

    func testComputeTokenRateWithNonexistentPathReturnsNil() {
        let rate = QuotaMonitor.shared.computeTokenRate(workspacePaths: ["/nonexistent/path"])
        XCTAssertNil(rate)
    }
}

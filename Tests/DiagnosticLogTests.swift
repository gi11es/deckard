import XCTest
@testable import Deckard

final class DiagnosticLogTests: XCTestCase {

    // MARK: - Log file existence

    func testDiagnosticLogSharedExists() {
        // DiagnosticLog.shared should be accessible and not crash
        let log = DiagnosticLog.shared
        XCTAssertNotNil(log)
    }

    // MARK: - Log writes to file

    func testLogWritesMarkerString() {
        let marker = "TEST-MARKER-\(UUID().uuidString)"
        DiagnosticLog.shared.log("test", marker)

        // Wait for async write
        let expectation = expectation(description: "log write")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3)

        // Read the log file
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logURL = appSupport.appendingPathComponent("Deckard/diagnostic.log")

        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            XCTFail("Could not read diagnostic log file")
            return
        }
        XCTAssertTrue(content.contains(marker), "Log should contain the marker string")
    }

    // MARK: - Log format

    func testLogFormatIncludesCategoryAndBuildTag() {
        let category = "testcat-\(UUID().uuidString.prefix(8))"
        let message = "testmsg-\(UUID().uuidString.prefix(8))"
        DiagnosticLog.shared.log(category, message)

        let expectation = expectation(description: "log write")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logURL = appSupport.appendingPathComponent("Deckard/diagnostic.log")

        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            XCTFail("Could not read diagnostic log file")
            return
        }

        // Find the line containing our message
        let lines = content.components(separatedBy: "\n")
        let matchingLine = lines.first { $0.contains(message) }
        XCTAssertNotNil(matchingLine, "Should find line with message")

        if let line = matchingLine {
            XCTAssertTrue(line.contains("[\(category)]"), "Line should contain category in brackets")
            // Format: [timestamp] [category] [buildTag] message
            XCTAssertTrue(line.contains("[v"), "Line should contain build tag starting with [v")
        }
    }

    // MARK: - Multiple log entries

    func testMultipleLogEntries() {
        let id = UUID().uuidString.prefix(8)
        let msg1 = "multi-1-\(id)"
        let msg2 = "multi-2-\(id)"

        DiagnosticLog.shared.log("test", msg1)
        DiagnosticLog.shared.log("test", msg2)

        let expectation = expectation(description: "log writes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logURL = appSupport.appendingPathComponent("Deckard/diagnostic.log")

        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            XCTFail("Could not read diagnostic log")
            return
        }

        XCTAssertTrue(content.contains(msg1))
        XCTAssertTrue(content.contains(msg2))
    }
}

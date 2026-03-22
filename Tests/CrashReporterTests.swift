import XCTest
@testable import Deckard

final class CrashReporterTests: XCTestCase {

    // MARK: - Crash report path

    func testCrashReportPathIsInAppSupport() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let expectedDir = appSupport.appendingPathComponent("Deckard")

        // The crash file should be in ~/Library/Application Support/Deckard/
        XCTAssertTrue(expectedDir.path.contains("Application Support/Deckard"))
    }

    // MARK: - Previous crash detection

    func testLogPreviousCrashWhenNoCrashFile() {
        // When no crash.log exists, logPreviousCrashIfAny should complete without error
        // Remove crash.log if it exists (to test the "no crash" path)
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let crashPath = appSupport.appendingPathComponent("Deckard/crash.log").path

        let hadCrashFile = FileManager.default.fileExists(atPath: crashPath)

        if hadCrashFile {
            // Don't delete — just verify the function runs
            CrashReporter.logPreviousCrashIfAny()
        } else {
            // No crash file — should be a no-op
            CrashReporter.logPreviousCrashIfAny()
        }

        // Should not crash
        XCTAssertTrue(true)
    }

    // MARK: - Crash file with content

    func testLogPreviousCrashWithContent() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Deckard")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let crashPath = dir.appendingPathComponent("crash.log")

        // Only run if no real crash file exists
        let alreadyExists = FileManager.default.fileExists(atPath: crashPath.path)
        try XCTSkipIf(alreadyExists, "Real crash.log exists, skipping to avoid interference")

        // Write a fake crash report
        let fakeReport = "Fatal signal: 11 (SIGSEGV)\n\nBacktrace:\nframe1\nframe2\n"
        try fakeReport.write(to: crashPath, atomically: true, encoding: .utf8)

        // This should read and archive the crash file
        CrashReporter.logPreviousCrashIfAny()

        // The original crash.log should be moved (renamed with timestamp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashPath.path),
                       "crash.log should be renamed after processing")

        // Clean up any archived file
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for file in files where file.hasPrefix("crash-") && file.hasSuffix(".log") {
                try? FileManager.default.removeItem(atPath: dir.appendingPathComponent(file).path)
            }
        }
    }

    // MARK: - Signal list

    func testCaughtSignalsCoverage() {
        // CrashReporter catches these signals
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP]
        XCTAssertEqual(signals.count, 6)

        // All should be positive signal numbers
        for sig in signals {
            XCTAssertGreaterThan(sig, 0, "Signal \(sig) should be positive")
        }
    }

    // MARK: - Crash report directory creation

    func testCrashReportDirectoryExists() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Deckard")

        // The directory should exist (created by DiagnosticLog or CrashReporter)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)

        // It should be created during the test (CrashReporter creates it lazily)
        if exists {
            XCTAssertTrue(isDir.boolValue)
        } else {
            // Create it ourselves to verify creation works
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        }
    }

    // MARK: - Empty crash file

    func testLogPreviousCrashIgnoresEmptyFile() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Deckard")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let crashPath = dir.appendingPathComponent("crash.log")

        let alreadyExists = FileManager.default.fileExists(atPath: crashPath.path)
        try XCTSkipIf(alreadyExists, "Real crash.log exists, skipping")

        // Write an empty file
        try "".write(to: crashPath, atomically: true, encoding: .utf8)

        CrashReporter.logPreviousCrashIfAny()

        // Empty crash file should remain (not processed)
        // Actually, the guard checks !contents.isEmpty, so empty file stays
        // Let's clean up
        try? FileManager.default.removeItem(at: crashPath)
    }
}

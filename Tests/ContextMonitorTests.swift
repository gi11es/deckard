import XCTest
@testable import Deckard

final class ContextMonitorTests: XCTestCase {

    // MARK: - ContextUsage.percentage

    func testPercentageCalculation() {
        let usage = ContextMonitor.ContextUsage(
            model: "claude-sonnet-4-6",
            inputTokens: 50_000,
            cacheReadTokens: 50_000,
            contextLimit: 200_000
        )

        XCTAssertEqual(usage.contextUsed, 100_000)
        XCTAssertEqual(usage.percentage, 50.0, accuracy: 0.01)
    }

    func testPercentageAtZero() {
        let usage = ContextMonitor.ContextUsage(
            model: "claude-sonnet-4-6",
            inputTokens: 0,
            cacheReadTokens: 0,
            contextLimit: 200_000
        )

        XCTAssertEqual(usage.contextUsed, 0)
        XCTAssertEqual(usage.percentage, 0.0, accuracy: 0.01)
    }

    func testPercentageAt100() {
        let usage = ContextMonitor.ContextUsage(
            model: "claude-sonnet-4-6",
            inputTokens: 100_000,
            cacheReadTokens: 100_000,
            contextLimit: 200_000
        )

        XCTAssertEqual(usage.percentage, 100.0, accuracy: 0.01)
    }

    func testPercentageWithZeroLimit() {
        let usage = ContextMonitor.ContextUsage(
            model: "unknown",
            inputTokens: 50_000,
            cacheReadTokens: 0,
            contextLimit: 0
        )

        XCTAssertEqual(usage.percentage, 0.0)
    }

    func testPercentageOverflow() {
        let usage = ContextMonitor.ContextUsage(
            model: "claude-sonnet-4-6",
            inputTokens: 200_000,
            cacheReadTokens: 100_000,
            contextLimit: 200_000
        )

        XCTAssertGreaterThan(usage.percentage, 100.0)
    }

    // MARK: - Context used computation

    func testContextUsedSum() {
        let usage = ContextMonitor.ContextUsage(
            model: "claude-opus-4-6",
            inputTokens: 30_000,
            cacheReadTokens: 70_000,
            contextLimit: 1_000_000
        )

        XCTAssertEqual(usage.contextUsed, 100_000)
    }

    // MARK: - Model info

    func testOpusModelUsage() {
        let usage = ContextMonitor.ContextUsage(
            model: "claude-opus-4-6",
            inputTokens: 500_000,
            cacheReadTokens: 0,
            contextLimit: 1_000_000
        )

        XCTAssertEqual(usage.percentage, 50.0, accuracy: 0.01)
    }

    // MARK: - parseUsage (pure JSONL parsing)

    func testParseUsageFlatFormat() {
        let line = """
        {"type":"assistant","message":{"model":"claude-opus-4-6","usage":{"input_tokens":500000,"cache_read_input_tokens":300000}}}
        """
        let usage = ContextMonitor.shared.parseUsage(from: line)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.model, "claude-opus-4-6")
        XCTAssertEqual(usage?.inputTokens, 500_000)
        XCTAssertEqual(usage?.cacheReadTokens, 300_000)
        XCTAssertEqual(usage?.contextLimit, 1_000_000)
        XCTAssertEqual(usage?.contextUsed, 800_000)
    }

    func testParseUsageNestedFormat() {
        let line = """
        {"type":"assistant","message":{"message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100000,"cache_read_input_tokens":50000}}}}
        """
        let usage = ContextMonitor.shared.parseUsage(from: line)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.model, "claude-sonnet-4-6")
        XCTAssertEqual(usage?.inputTokens, 100_000)
        XCTAssertEqual(usage?.cacheReadTokens, 50_000)
        XCTAssertEqual(usage?.contextLimit, 1_000_000)
    }

    func testParseUsageSkipsZeroTokenEntries() {
        // Zero-token entry followed by a real one — should return the real one
        let content = """
        {"type":"assistant","message":{"model":"claude-opus-4-6","usage":{"input_tokens":80000,"cache_read_input_tokens":20000}}}
        {"type":"assistant","message":{"model":"claude-opus-4-6","usage":{"input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let usage = ContextMonitor.shared.parseUsage(from: content)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.inputTokens, 80_000)
    }

    func testParseUsageReturnsLastEntry() {
        // Two valid entries — should return the last one (most recent)
        let content = """
        {"type":"assistant","message":{"model":"claude-opus-4-6","usage":{"input_tokens":50000,"cache_read_input_tokens":10000}}}
        {"type":"assistant","message":{"model":"claude-opus-4-6","usage":{"input_tokens":90000,"cache_read_input_tokens":30000}}}
        """
        let usage = ContextMonitor.shared.parseUsage(from: content)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.inputTokens, 90_000)
        XCTAssertEqual(usage?.cacheReadTokens, 30_000)
    }

    // MARK: - Codex activity parsing

    func testParseCodexActivityInfoReportsStartedTaskBusy() {
        let content = """
        {"timestamp":"2026-04-28T19:55:08.554Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-04-28T19:55:08.763Z","type":"event_msg","payload":{"type":"token_count"}}
        """

        let activity = ContextMonitor.shared.parseCodexActivityInfo(from: content)

        XCTAssertEqual(activity?.isBusy, true)
        XCTAssertEqual(activity?.isError, false)
    }

    func testParseCodexActivityInfoTreatsTurnAbortedAsIdle() {
        let content = """
        {"timestamp":"2026-04-28T19:55:08.554Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-04-28T19:55:10.124Z","type":"event_msg","payload":{"type":"turn_aborted"}}
        """

        let activity = ContextMonitor.shared.parseCodexActivityInfo(from: content)

        XCTAssertEqual(activity?.isBusy, false)
        XCTAssertEqual(activity?.isError, false)
    }

    func testParseCodexActivityInfoTreatsErrorAsError() {
        let content = """
        {"timestamp":"2026-04-28T19:55:08.554Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-04-28T19:55:10.124Z","type":"event_msg","payload":{"type":"error"}}
        """

        let activity = ContextMonitor.shared.parseCodexActivityInfo(from: content)

        XCTAssertEqual(activity?.isBusy, false)
        XCTAssertEqual(activity?.isError, true)
    }

    func testParseCodexUsageReadsQuotaAndTokenRateButDoesNotReportContext() throws {
        let now = try XCTUnwrap(codexDate("2026-04-28T12:42:05.267Z"))
        let content = """
        {"timestamp":"2026-04-28T12:41:05.267Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":48536,"cached_input_tokens":23296,"output_tokens":940,"reasoning_output_tokens":241,"total_tokens":49476},"last_token_usage":{"input_tokens":35145,"cached_input_tokens":11648,"output_tokens":419,"reasoning_output_tokens":139,"total_tokens":35564},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_at":1777398056},"secondary":{"used_percent":3.25,"window_minutes":10080,"resets_at":1777984856}}}}
        """

        let usage = ContextMonitor.shared.parseCodexUsage(from: content, now: now)

        XCTAssertNil(usage?.context)
        XCTAssertEqual(usage?.quotaSnapshot?.fiveHourUsed, 12.5)
        XCTAssertEqual(usage?.quotaSnapshot?.sevenDayUsed, 3.25)
        XCTAssertEqual(try XCTUnwrap(usage?.tokenRate?.tokensPerMinute), 558, accuracy: 0.01)
        XCTAssertEqual(usage?.sparklineData, [558.0])
    }

    func testParseCodexUsageAllowsRateLimitsWhenInfoIsNull() throws {
        let now = try XCTUnwrap(codexDate("2026-04-28T12:42:05.267Z"))
        let content = """
        {"timestamp":"2026-04-28T12:41:05.267Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1777398056},"secondary":{"used_percent":0.0,"window_minutes":10080,"resets_at":1777984856}}}}
        """

        let usage = ContextMonitor.shared.parseCodexUsage(from: content, now: now)

        XCTAssertNil(usage?.context)
        XCTAssertEqual(usage?.quotaSnapshot?.fiveHourUsed, 0.0)
        XCTAssertEqual(usage?.quotaSnapshot?.sevenDayUsed, 0.0)
        XCTAssertNotNil(usage?.quotaSnapshot?.fiveHourResetsAt)
        XCTAssertNil(usage?.tokenRate)
    }

    func testParseCodexAppServerQuotaResponseReadsCamelCaseRateLimits() throws {
        let now = try XCTUnwrap(codexDate("2026-04-28T12:42:05.267Z"))
        let data = try XCTUnwrap("""
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":12.5,"windowDurationMins":300,"resetsAt":1777398056},"secondary":{"usedPercent":3.25,"windowDurationMins":10080,"resetsAt":1777984856},"planType":"pro"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":25.0,"windowDurationMins":300,"resetsAt":1777399056},"secondary":{"usedPercent":6.5,"windowDurationMins":10080,"resetsAt":1777985856},"planType":"pro"}}}}
        """.data(using: .utf8))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let snapshot = ContextMonitor.shared.parseCodexAppServerQuotaResponse(response, now: now)

        XCTAssertEqual(snapshot?.fiveHourUsed, 25.0)
        XCTAssertEqual(snapshot?.sevenDayUsed, 6.5)
        XCTAssertEqual(snapshot?.lastUpdated, now)
        XCTAssertEqual(snapshot?.fiveHourResetsAt?.timeIntervalSince1970, 1777399056)
        XCTAssertEqual(snapshot?.sevenDayResetsAt?.timeIntervalSince1970, 1777985856)
    }

    func testParseCodexAppServerQuotaResponseAllowsNullSecondaryWindow() throws {
        let now = try XCTUnwrap(codexDate("2026-04-28T12:42:05.267Z"))
        let data = try XCTUnwrap("""
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":17.75,"windowDurationMins":300,"resetsAt":1777398056},"secondary":null,"planType":"pro"}}}
        """.data(using: .utf8))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let snapshot = ContextMonitor.shared.parseCodexAppServerQuotaResponse(response, now: now)

        XCTAssertEqual(snapshot?.fiveHourUsed, 17.75)
        XCTAssertEqual(snapshot?.sevenDayUsed, 0)
        XCTAssertNil(snapshot?.sevenDayResetsAt)
    }

    func testParseUsageNoUsageLines() {
        let content = """
        {"type":"user","message":{"content":"hello"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}
        """
        let usage = ContextMonitor.shared.parseUsage(from: content)
        XCTAssertNil(usage)
    }

    func testParseUsageEmptyContent() {
        XCTAssertNil(ContextMonitor.shared.parseUsage(from: ""))
    }

    func testParseUsageUnknownModelGetsDefaultLimit() {
        let line = """
        {"type":"assistant","message":{"model":"claude-unknown-99","usage":{"input_tokens":10000,"cache_read_input_tokens":5000}}}
        """
        let usage = ContextMonitor.shared.parseUsage(from: line)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.contextLimit, 1_000_000)
    }

    func testParseUsageIgnoresInvalidJSON() {
        let content = """
        not valid json at all
        {"type":"assistant","message":{"model":"claude-opus-4-6","usage":{"input_tokens":10000,"cache_read_input_tokens":5000}}}
        also not json
        """
        let usage = ContextMonitor.shared.parseUsage(from: content)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.inputTokens, 10_000)
    }

    // MARK: - getUsageFromFile (file I/O + progressive read)

    func testGetUsageFromFileBasic() throws {
        let path = makeTempJSONL(lines: [
            assistantUsageLine(model: "claude-haiku-4-5-20251001", input: 40_000, cacheRead: 10_000)
        ])
        let usage = ContextMonitor.shared.getUsageFromFile(at: path)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.inputTokens, 40_000)
        XCTAssertEqual(usage?.cacheReadTokens, 10_000)
        XCTAssertEqual(usage?.contextLimit, 200_000)
    }

    func testGetUsageFromFileNonexistent() {
        let usage = ContextMonitor.shared.getUsageFromFile(at: "/tmp/nonexistent-\(UUID().uuidString).jsonl")
        XCTAssertNil(usage)
    }

    func testGetUsageFromFileEmpty() throws {
        let path = makeTempJSONL(lines: [])
        let usage = ContextMonitor.shared.getUsageFromFile(at: path)
        XCTAssertNil(usage)
    }

    func testGetUsageFromFileWithLargePaddingBefore() throws {
        // Simulate a large session where the usage entry is far from the end.
        // Insert >256KB of padding after the usage entry, then verify the
        // progressive read (1MB fallback) finds it.
        let usageLine = assistantUsageLine(model: "claude-opus-4-6", input: 600_000, cacheRead: 200_000)
        // Each padding line is ~200 bytes; we need >256KB = ~1300 lines
        let paddingLine = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"\(String(repeating: "x", count: 180))\"}]}}"
        var lines = [usageLine]
        for _ in 0..<1400 {
            lines.append(paddingLine)
        }
        let path = makeTempJSONL(lines: lines)

        // Verify file is actually >256KB
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let fileSize = attrs[.size] as! UInt64
        XCTAssertGreaterThan(fileSize, 256 * 1024, "Test file should exceed 256KB to exercise fallback")

        let usage = ContextMonitor.shared.getUsageFromFile(at: path)
        XCTAssertNotNil(usage, "Should find usage via 1MB fallback read")
        XCTAssertEqual(usage?.inputTokens, 600_000)
        XCTAssertEqual(usage?.cacheReadTokens, 200_000)
        XCTAssertEqual(usage?.model, "claude-opus-4-6")
    }

    func testGetUsageFromFileNoUsageInFile() throws {
        let lines = [
            "{\"type\":\"user\",\"promptId\":\"p1\",\"message\":{\"content\":\"hello\"}}",
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}",
        ]
        let path = makeTempJSONL(lines: lines)
        let usage = ContextMonitor.shared.getUsageFromFile(at: path)
        XCTAssertNil(usage)
    }

    // MARK: - Caching behavior

    func testCacheFallsBackWhenFileLacksUsage() throws {
        let monitor = ContextMonitor()

        // First call: file has usage → populates cache
        let tempDir = NSTemporaryDirectory() + "deckard-cache-test-\(UUID().uuidString)"
        let encoded = tempDir.claudeProjectDirName
        let projectDir = NSHomeDirectory() + "/.claude/projects/\(encoded)"
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: projectDir) }

        let sessionId = "cache-test-\(UUID().uuidString)"
        let jsonlPath = projectDir + "/\(sessionId).jsonl"

        // Write file with usage
        let withUsage = assistantUsageLine(model: "claude-opus-4-6", input: 400_000, cacheRead: 100_000)
        try (withUsage + "\n").write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let usage1 = monitor.getUsage(sessionId: sessionId, projectPath: tempDir)
        XCTAssertNotNil(usage1)
        XCTAssertEqual(usage1?.inputTokens, 400_000)

        // Overwrite file with no usage lines
        let noUsage = "{\"type\":\"user\",\"promptId\":\"p1\",\"message\":{\"content\":\"hello\"}}\n"
        try noUsage.write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        // Second call: file lacks usage → should return cached value
        let usage2 = monitor.getUsage(sessionId: sessionId, projectPath: tempDir)
        XCTAssertNotNil(usage2, "Should return cached value when file lacks usage")
        XCTAssertEqual(usage2?.inputTokens, 400_000)
    }

    func testCacheUpdatesWhenNewUsageFound() throws {
        let monitor = ContextMonitor()

        let tempDir = NSTemporaryDirectory() + "deckard-cache-update-\(UUID().uuidString)"
        let encoded = tempDir.claudeProjectDirName
        let projectDir = NSHomeDirectory() + "/.claude/projects/\(encoded)"
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: projectDir) }

        let sessionId = "cache-update-\(UUID().uuidString)"
        let jsonlPath = projectDir + "/\(sessionId).jsonl"

        // First: smaller usage
        let line1 = assistantUsageLine(model: "claude-opus-4-6", input: 100_000, cacheRead: 50_000)
        try (line1 + "\n").write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let usage1 = monitor.getUsage(sessionId: sessionId, projectPath: tempDir)
        XCTAssertEqual(usage1?.inputTokens, 100_000)

        // Second: larger usage
        let line2 = assistantUsageLine(model: "claude-opus-4-6", input: 300_000, cacheRead: 200_000)
        try (line1 + "\n" + line2 + "\n").write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let usage2 = monitor.getUsage(sessionId: sessionId, projectPath: tempDir)
        XCTAssertEqual(usage2?.inputTokens, 300_000, "Cache should update to newest usage")
    }

    func testNoCacheForNeverSeenSession() {
        let monitor = ContextMonitor()
        let usage = monitor.getUsage(
            sessionId: "never-seen-\(UUID().uuidString)",
            projectPath: "/nonexistent/\(UUID().uuidString)")
        XCTAssertNil(usage, "No cache for a session never queried before")
    }

    // MARK: - Helpers

    private func assistantUsageLine(model: String, input: Int, cacheRead: Int) -> String {
        "{\"type\":\"assistant\",\"message\":{\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),\"cache_read_input_tokens\":\(cacheRead)}}}"
    }

    private func codexDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private func makeTempJSONL(lines: [String]) -> String {
        let path = NSTemporaryDirectory() + "deckard-test-\(UUID().uuidString).jsonl"
        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        FileManager.default.createFile(atPath: path, contents: content.data(using: .utf8))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    // MARK: - ContextMonitor shared instance

    func testSharedInstanceExists() {
        XCTAssertNotNil(ContextMonitor.shared)
    }

    // MARK: - listSessions with nonexistent path

    func testListSessionsNonexistentPath() {
        let sessions = ContextMonitor.shared.listSessions(
            forProjectPath: "/nonexistent/path/\(UUID().uuidString)"
        )
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - getUsage with nonexistent session

    func testGetUsageNonexistentSession() {
        let usage = ContextMonitor.shared.getUsage(
            sessionId: "nonexistent-\(UUID().uuidString)",
            projectPath: "/nonexistent/path/\(UUID().uuidString)"
        )
        XCTAssertNil(usage)
    }

    // MARK: - SessionInfo struct

    func testSessionInfoProperties() {
        let date = Date()
        let info = ContextMonitor.SessionInfo(
            sessionId: "sess-123",
            modificationDate: date,
            firstUserMessage: "Hello Claude",
            messageCount: 5
        )

        XCTAssertEqual(info.sessionId, "sess-123")
        XCTAssertEqual(info.modificationDate, date)
        XCTAssertEqual(info.firstUserMessage, "Hello Claude")
    }

    // MARK: - claudeProjectDirName symlink resolution

    func testClaudeProjectDirNameResolvesSymlinks() throws {
        let tempDir = NSTemporaryDirectory() + "deckard-dirname-\(UUID().uuidString)"
        let realDir = tempDir + "/real-project"
        let linkDir = tempDir + "/linked-project"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }
        try FileManager.default.createSymbolicLink(atPath: linkDir, withDestinationPath: realDir)

        XCTAssertEqual(linkDir.claudeProjectDirName, realDir.claudeProjectDirName,
                       "claudeProjectDirName should produce the same result for symlink and canonical path")
    }

    func testClaudeProjectDirNameEncodesSlashes() {
        let path = "/Users/test/my-project"
        XCTAssertEqual(path.claudeProjectDirName, "-Users-test-my-project")
        XCTAssertFalse(path.claudeProjectDirName.contains("/"))
    }

    func testClaudeProjectDirNameEncodesDotsUnderscoresAndOtherSpecials() {
        // The Claude CLI replaces every non-[A-Za-z0-9-] character with "-".
        // This includes ".", "_", and spaces — not just "/".
        let path = "/Volumes/Android/source/qcm8550_android13.0_ba01_r035"
        XCTAssertEqual(path.claudeProjectDirName,
                       "-Volumes-Android-source-qcm8550-android13-0-ba01-r035")

        let spaced = "/Users/test/My Project"
        XCTAssertEqual(spaced.claudeProjectDirName, "-Users-test-My-Project")
    }

    func testClaudeProjectDirNameIdempotentOnCanonicalPath() throws {
        let tempDir = NSTemporaryDirectory() + "deckard-dirname-\(UUID().uuidString)"
        let realDir = tempDir + "/project"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }

        // Calling on an already-canonical path should give the same result
        let dirName = realDir.claudeProjectDirName
        let resolvedFirst = (realDir as NSString).resolvingSymlinksInPath
        XCTAssertEqual(resolvedFirst.claudeProjectDirName, dirName,
                       "Double resolution should be idempotent")
    }

    func testClaudeProjectDirNameConsistentWithProjectItem() throws {
        let tempDir = NSTemporaryDirectory() + "deckard-dirname-\(UUID().uuidString)"
        let realDir = tempDir + "/real-project"
        let linkDir = tempDir + "/linked-project"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }
        try FileManager.default.createSymbolicLink(atPath: linkDir, withDestinationPath: realDir)

        // ProjectItem resolves symlinks; claudeProjectDirName should agree
        let project = ProjectItem(path: linkDir)
        let encoded = project.path.claudeProjectDirName
        XCTAssertEqual(encoded, realDir.claudeProjectDirName,
                       "ProjectItem.path and claudeProjectDirName should agree on canonical encoding")
    }
}

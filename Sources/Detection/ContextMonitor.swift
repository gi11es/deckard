import Foundation

extension String {
    /// Encodes a project path into the directory name Claude Code uses under `~/.claude/projects/`.
    /// Resolves symlinks first so the encoded name matches the canonical path the CLI uses.
    /// The CLI replaces every character that isn't `[A-Za-z0-9-]` with "-" — including "/", ".", "_", and spaces.
    var claudeProjectDirName: String {
        let resolved = (self as NSString).resolvingSymlinksInPath
        return resolved.replacingOccurrences(
            of: "[^A-Za-z0-9-]",
            with: "-",
            options: .regularExpression
        )
    }
}

/// Reads Claude Code and Codex session files to calculate session metadata and usage.
class ContextMonitor {
    static let shared = ContextMonitor()

    private let contextLimits: [String: Int] = [
        "claude-opus-4-6": 1_000_000,
        "claude-opus-4-7": 1_000_000,
        "claude-sonnet-4-6": 1_000_000,
        "claude-haiku-4-5": 200_000,
        "claude-haiku-4-5-20251001": 200_000,
    ]
    private let defaultLimit = 1_000_000

    struct ContextUsage {
        let model: String
        let inputTokens: Int
        let cacheReadTokens: Int
        let contextLimit: Int

        var contextUsed: Int { inputTokens + cacheReadTokens }
        var percentage: Double {
            guard contextLimit > 0 else { return 0 }
            return Double(contextUsed) / Double(contextLimit) * 100
        }

    }

    struct CodexActivityInfo {
        let isBusy: Bool
        let isError: Bool
        let timestamp: Date?
    }

    struct CodexUsageInfo {
        let context: ContextUsage?
        let quotaSnapshot: QuotaMonitor.QuotaSnapshot?
        let tokenRate: QuotaMonitor.TokenRate?
        let sparklineData: [Double]
    }

    struct SessionInfo {
        let sessionId: String
        let modificationDate: Date
        let firstUserMessage: String
        let messageCount: Int
        let kind: TabKind
        let filePath: URL?

        init(sessionId: String,
             modificationDate: Date,
             firstUserMessage: String,
             messageCount: Int,
             kind: TabKind = .claude,
             filePath: URL? = nil) {
            self.sessionId = sessionId
            self.modificationDate = modificationDate
            self.firstUserMessage = firstUserMessage
            self.messageCount = messageCount
            self.kind = kind
            self.filePath = filePath
        }
    }

    /// Lists all Claude sessions for a project, sorted by most recent first.
    func listSessions(forProjectPath projectPath: String) -> [SessionInfo] {
        let encoded = projectPath.claudeProjectDirName
        let dir = NSHomeDirectory() + "/.claude/projects/\(encoded)"
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        var results: [SessionInfo] = []

        for file in files where file.hasSuffix(".jsonl") {
            let sessionId = String(file.dropLast(6))
            let filePath = dir + "/" + file

            guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                  let modDate = attrs[.modificationDate] as? Date else { continue }

            var firstMessage = ""

            if let fh = FileHandle(forReadingAtPath: filePath) {
                let headData = fh.readData(ofLength: 8192)
                try? fh.close()

                if let headStr = String(data: headData, encoding: .utf8) {
                    for line in headStr.split(separator: "\n") {
                        guard let ld = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] else { continue }

                        let type = json["type"] as? String ?? ""
                        if type == "user" && firstMessage.isEmpty {
                            if let msg = json["message"] as? [String: Any] {
                                if let content = msg["content"] as? String {
                                    firstMessage = content
                                } else if let contentArr = msg["content"] as? [[String: Any]] {
                                    firstMessage = contentArr.first(where: { $0["type"] as? String == "text" })?["text"] as? String ?? ""
                                }
                            }
                            break
                        }
                    }
                }
            }

            firstMessage = firstMessage.split(separator: "\n").first.map(String.init) ?? ""
            firstMessage = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)

            results.append(SessionInfo(
                sessionId: sessionId,
                modificationDate: modDate,
                firstUserMessage: firstMessage,
                messageCount: 0,
                kind: .claude,
                filePath: URL(fileURLWithPath: filePath)
            ))
        }

        results.sort { $0.modificationDate > $1.modificationDate }
        return results
    }

    /// Lists Claude and Codex sessions for a project, sorted by most recent first.
    func listAllSessions(forProjectPath projectPath: String) -> [SessionInfo] {
        (listSessions(forProjectPath: projectPath) + listCodexSessions(forProjectPath: projectPath))
            .sorted { $0.modificationDate > $1.modificationDate }
    }

    /// Lists Codex sessions for a project by scanning ~/.codex/sessions.
    func listCodexSessions(forProjectPath projectPath: String) -> [SessionInfo] {
        let root = codexSessionsRoot
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        let resolvedProjectPath = (projectPath as NSString).resolvingSymlinksInPath
        var results: [SessionInfo] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let info = parseCodexSessionInfo(fileURL: fileURL, projectPath: resolvedProjectPath) else { continue }
            results.append(info)
        }

        results.sort { $0.modificationDate > $1.modificationDate }
        return results
    }

    private var codexSessionsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    private var codexStateDatabaseURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/state_5.sqlite")
    }

    func codexSessionFileURL(sessionId: String) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: codexSessionsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let fileURL as URL in enumerator
            where fileURL.pathExtension == "jsonl" && fileURL.lastPathComponent.contains(sessionId) {
            return fileURL
        }
        return nil
    }

    func latestCodexSession(forProjectPath projectPath: String, after date: Date, excluding excludedIds: Set<String> = []) -> SessionInfo? {
        listCodexSessions(forProjectPath: projectPath)
            .first { $0.modificationDate >= date && !excludedIds.contains($0.sessionId) }
    }

    func codexActivityInfo(sessionId: String) -> CodexActivityInfo? {
        guard let content = codexTailContent(sessionId: sessionId, maxBytes: 256 * 1024) else {
            return nil
        }

        var latest: CodexActivityInfo?
        for line in content.split(separator: "\n") {
            guard let json = parseJSONObject(line),
                  json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else { continue }

            let isBusy: Bool
            let isError: Bool
            switch payloadType {
            case "task_started":
                isBusy = true
                isError = false
            case "task_complete", "task_cancelled":
                isBusy = false
                isError = false
            case "task_failed":
                isBusy = false
                isError = true
            default:
                continue
            }

            let timestamp = (json["timestamp"] as? String).flatMap { codexTimestampFormatter.date(from: $0) }
            latest = CodexActivityInfo(isBusy: isBusy, isError: isError, timestamp: timestamp)
        }

        return latest
    }

    func getCodexUsage(sessionId: String) -> CodexUsageInfo? {
        guard let content = codexTailContent(sessionId: sessionId, maxBytes: 1024 * 1024) else {
            return nil
        }

        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        var context: ContextUsage?
        var quotaSnapshot: QuotaMonitor.QuotaSnapshot?
        var generatedEvents: [(timestamp: Date, tokens: Int)] = []

        for line in content.split(separator: "\n") {
            guard let json = parseJSONObject(line),
                  json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count" else { continue }

            let timestamp = (json["timestamp"] as? String).flatMap { codexTimestampFormatter.date(from: $0) }

            if let info = payload["info"] as? [String: Any],
               let lastUsage = info["last_token_usage"] as? [String: Any] {
                let contextWindow = codexInt(info["model_context_window"]) ?? 0
                let totalTokens = codexInt(lastUsage["total_tokens"])
                    ?? ((codexInt(lastUsage["input_tokens"]) ?? 0)
                        + (codexInt(lastUsage["output_tokens"]) ?? 0)
                        + (codexInt(lastUsage["reasoning_output_tokens"]) ?? 0))

                if contextWindow > 0, totalTokens > 0 {
                    context = ContextUsage(
                        model: "codex",
                        inputTokens: totalTokens,
                        cacheReadTokens: 0,
                        contextLimit: contextWindow)
                }

                if let timestamp, timestamp >= cutoff {
                    let generated = (codexInt(lastUsage["output_tokens"]) ?? 0)
                        + (codexInt(lastUsage["reasoning_output_tokens"]) ?? 0)
                    if generated > 0 {
                        generatedEvents.append((timestamp: timestamp, tokens: generated))
                    }
                }
            }

            if let rateLimits = payload["rate_limits"] as? [String: Any],
               let snapshot = codexQuotaSnapshot(from: rateLimits, timestamp: timestamp ?? now) {
                quotaSnapshot = snapshot
            }
        }

        let tokenRate = codexTokenRate(from: generatedEvents, now: now)
        let sparklineData = generatedEvents.suffix(30).map { Double($0.tokens) }

        guard context != nil || quotaSnapshot != nil || tokenRate != nil || !sparklineData.isEmpty else {
            return nil
        }

        return CodexUsageInfo(
            context: context,
            quotaSnapshot: quotaSnapshot,
            tokenRate: tokenRate,
            sparklineData: sparklineData)
    }

    private func parseCodexSessionInfo(fileURL: URL, projectPath: String) -> SessionInfo? {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return nil }

        var sessionId: String?
        var cwd: String?
        var firstUserMessage = ""
        var messageCount = 0
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var metaTimestamp: Date?

        for line in content.split(separator: "\n") {
            guard let json = parseJSONObject(line) else { continue }
            let type = json["type"] as? String ?? ""

            if type == "session_meta", let payload = json["payload"] as? [String: Any] {
                sessionId = payload["id"] as? String
                if let rawCwd = payload["cwd"] as? String {
                    cwd = (rawCwd as NSString).resolvingSymlinksInPath
                }
                if let ts = payload["timestamp"] as? String {
                    metaTimestamp = iso8601.date(from: ts)
                }
                continue
            }

            guard type == "response_item",
                  let payload = json["payload"] as? [String: Any],
                  let role = payload["role"] as? String,
                  role == "user",
                  let text = codexMessageText(from: payload),
                  !isSyntheticCodexUserMessage(text) else { continue }

            messageCount += 1
            if firstUserMessage.isEmpty {
                firstUserMessage = text.split(separator: "\n").first.map(String.init) ?? text
                firstUserMessage = firstUserMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let sessionId, cwd == projectPath else { return nil }

        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modDate = attrs?[.modificationDate] as? Date ?? metaTimestamp ?? Date.distantPast

        return SessionInfo(
            sessionId: sessionId,
            modificationDate: modDate,
            firstUserMessage: firstUserMessage,
            messageCount: messageCount,
            kind: .codex,
            filePath: fileURL
        )
    }

    private func parseJSONObject(_ line: Substring) -> [String: Any]? {
        guard let lineData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func codexMessageText(from payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        let parts = content.compactMap { block -> String? in
            if let text = block["text"] as? String {
                return text
            }
            return nil
        }
        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func codexTailContent(sessionId: String, maxBytes: UInt64) -> String? {
        guard let fileURL = codexSessionFileURL(sessionId: sessionId),
              let fh = FileHandle(forReadingAtPath: fileURL.path) else { return nil }
        defer { try? fh.close() }

        let fileSize = fh.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
        fh.seek(toFileOffset: offset)
        let data = fh.readData(ofLength: Int(fileSize - offset))
        return String(data: data, encoding: .utf8)
    }

    private func codexQuotaSnapshot(from rateLimits: [String: Any], timestamp: Date) -> QuotaMonitor.QuotaSnapshot? {
        guard let primary = rateLimits["primary"] as? [String: Any],
              let secondary = rateLimits["secondary"] as? [String: Any] else { return nil }

        let primaryUsed = codexDouble(primary["used_percent"]) ?? 0
        let secondaryUsed = codexDouble(secondary["used_percent"]) ?? 0
        let primaryReset = codexDouble(primary["resets_at"]).map { Date(timeIntervalSince1970: $0) }
        let secondaryReset = codexDouble(secondary["resets_at"]).map { Date(timeIntervalSince1970: $0) }

        guard primaryUsed > 0 || secondaryUsed > 0 || primaryReset != nil || secondaryReset != nil else {
            return nil
        }

        return QuotaMonitor.QuotaSnapshot(
            fiveHourUsed: primaryUsed,
            fiveHourResetsAt: primaryReset,
            sevenDayUsed: secondaryUsed,
            sevenDayResetsAt: secondaryReset,
            lastUpdated: timestamp)
    }

    private func codexTokenRate(from events: [(timestamp: Date, tokens: Int)], now: Date) -> QuotaMonitor.TokenRate? {
        guard let earliest = events.map(\.timestamp).min() else { return nil }
        let totalTokens = events.reduce(0) { $0 + $1.tokens }
        guard totalTokens > 0 else { return nil }

        let elapsedMinutes = max(now.timeIntervalSince(earliest) / 60.0, 1.0)
        return QuotaMonitor.TokenRate(
            tokensPerMinute: Double(totalTokens) / elapsedMinutes,
            windowSeconds: Int(now.timeIntervalSince(earliest)))
    }

    private func codexInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func codexDouble(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func isSyntheticCodexUserMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<environment_context>") ||
            trimmed.hasPrefix("<attachments>") ||
            trimmed.hasPrefix("<user_instructions>")
    }

    private func codexActionDescription(name: String, arguments: String?) -> String {
        guard let arguments,
              let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return name
        }

        if let cmd = json["cmd"] as? String ?? json["command"] as? String {
            let brief = cmd.split(separator: "\n").first.map(String.init) ?? cmd
            return "\(name): \(String(brief.prefix(50)))"
        }
        if let path = json["path"] as? String ?? json["file_path"] as? String {
            return "\(name) \((path as NSString).lastPathComponent)"
        }
        if let pattern = json["pattern"] as? String {
            return "\(name) \(pattern)"
        }
        return name
    }

    /// Parses a session JSONL file and returns an ordered list of user turns.
    /// Deduplicates by promptId — only the first occurrence with non-empty content is kept.
    func parseTimeline(sessionId: String, projectPath: String, kind: TabKind = .claude) -> [TimelineEntry] {
        if kind == .codex {
            return parseCodexTimeline(sessionId: sessionId, projectPath: projectPath)
        }

        let encoded = projectPath.claudeProjectDirName
        let jsonlPath = NSHomeDirectory() + "/.claude/projects/\(encoded)/\(sessionId).jsonl"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonlPath)),
              let content = String(data: data, encoding: .utf8) else { return [] }

        var entries: [TimelineEntry] = []
        var seenPromptIds = Set<String>()
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in content.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String, type == "user",
                  let promptId = json["promptId"] as? String,
                  !seenPromptIds.contains(promptId) else { continue }

            let msg = json["message"] as? [String: Any]
            var text = ""
            if let content = msg?["content"] as? String {
                text = content
            } else if let contentArr = msg?["content"] as? [[String: Any]] {
                text = contentArr.first(where: { $0["type"] as? String == "text" })?["text"] as? String ?? ""
            }

            // Skip empty continuation messages (same promptId, no content)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                seenPromptIds.insert(promptId)
                continue
            }

            seenPromptIds.insert(promptId)

            let timestamp: Date?
            if let ts = json["timestamp"] as? String {
                timestamp = iso8601.date(from: ts)
            } else {
                timestamp = nil
            }

            entries.append(TimelineEntry(
                index: entries.count,
                promptId: promptId,
                message: text.trimmingCharacters(in: .whitespacesAndNewlines),
                timestamp: timestamp,
                actionSummary: nil
            ))
        }

        return entries
    }

    private func parseCodexTimeline(sessionId: String, projectPath: String) -> [TimelineEntry] {
        guard let fileURL = codexSessionFileURL(sessionId: sessionId),
              let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return [] }

        var entries: [TimelineEntry] = []
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in content.split(separator: "\n") {
            guard let json = parseJSONObject(line),
                  let text = codexRealUserMessageText(from: json) else { continue }

            let timestamp: Date?
            if let ts = json["timestamp"] as? String {
                timestamp = iso8601.date(from: ts)
            } else {
                timestamp = nil
            }

            entries.append(TimelineEntry(
                index: entries.count,
                promptId: "\(sessionId)-\(entries.count)",
                message: text,
                timestamp: timestamp,
                actionSummary: nil
            ))
        }

        return entries
    }

    /// Extracts a raw description of tool uses for each user turn in a session.
    /// Returns a dictionary mapping turn index to a list of action descriptions.
    func parseActions(sessionId: String, projectPath: String, kind: TabKind = .claude) -> [Int: [String]] {
        if kind == .codex {
            return parseCodexActions(sessionId: sessionId, projectPath: projectPath)
        }

        let encoded = projectPath.claudeProjectDirName
        let jsonlPath = NSHomeDirectory() + "/.claude/projects/\(encoded)/\(sessionId).jsonl"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonlPath)),
              let content = String(data: data, encoding: .utf8) else { return [:] }

        var result: [Int: [String]] = [:]
        var currentTurnIndex = -1
        var seenPromptIds = Set<String>()

        for line in content.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            if type == "user", let promptId = json["promptId"] as? String,
               !seenPromptIds.contains(promptId) {
                let msg = json["message"] as? [String: Any]
                var text = ""
                if let c = msg?["content"] as? String {
                    text = c
                } else if let arr = msg?["content"] as? [[String: Any]] {
                    text = arr.first(where: { $0["type"] as? String == "text" })?["text"] as? String ?? ""
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    seenPromptIds.insert(promptId)
                    continue
                }
                seenPromptIds.insert(promptId)
                currentTurnIndex += 1
            } else if type == "assistant", currentTurnIndex >= 0 {
                let msg = json["message"] as? [String: Any]
                let inner = msg?["message"] as? [String: Any] ?? msg
                guard let contentArr = inner?["content"] as? [[String: Any]] else { continue }

                for block in contentArr {
                    guard block["type"] as? String == "tool_use",
                          let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    var desc = name
                    if let fp = input["file_path"] as? String {
                        let filename = (fp as NSString).lastPathComponent
                        desc = "\(name) \(filename)"
                    } else if let cmd = input["command"] as? String {
                        let brief = cmd.split(separator: "\n").first.map(String.init) ?? cmd
                        desc = "\(name): \(String(brief.prefix(50)))"
                    } else if let pattern = input["pattern"] as? String {
                        desc = "\(name) \(pattern)"
                    }
                    result[currentTurnIndex, default: []].append(desc)
                }
            }
        }

        return result
    }

    private func parseCodexActions(sessionId: String, projectPath: String) -> [Int: [String]] {
        guard let fileURL = codexSessionFileURL(sessionId: sessionId),
              let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return [:] }

        var result: [Int: [String]] = [:]
        var currentTurnIndex = -1

        for line in content.split(separator: "\n") {
            guard let json = parseJSONObject(line),
                  json["type"] as? String == "response_item",
                  let payload = json["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else { continue }

            if codexRealUserMessageText(from: json) != nil {
                currentTurnIndex += 1
                continue
            }

            if payloadType == "function_call", currentTurnIndex >= 0,
               let name = payload["name"] as? String {
                let desc = codexActionDescription(name: name, arguments: payload["arguments"] as? String)
                result[currentTurnIndex, default: []].append(desc)
            }
        }

        return result
    }

    /// Creates a truncated copy of a session JSONL, keeping everything up to (and including
    /// the full response for) the Nth unique user turn. Returns the new session ID.
    func truncateSession(sessionId: String, projectPath: String, afterTurnIndex: Int, kind: TabKind = .claude) -> String? {
        switch kind {
        case .claude:
            return truncateClaudeSession(sessionId: sessionId, projectPath: projectPath, afterTurnIndex: afterTurnIndex)
        case .codex:
            return truncateCodexSession(sessionId: sessionId, projectPath: projectPath, afterTurnIndex: afterTurnIndex)
        case .terminal:
            return nil
        }
    }

    private func truncateClaudeSession(sessionId: String, projectPath: String, afterTurnIndex: Int) -> String? {

        let encoded = projectPath.claudeProjectDirName
        let dir = NSHomeDirectory() + "/.claude/projects/\(encoded)"
        let jsonlPath = dir + "/\(sessionId).jsonl"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonlPath)),
              let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var seenPromptIds = Set<String>()
        var uniqueTurnCount = -1  // will be incremented to 0 on first user turn
        var cutoffLineIndex = lines.count

        for (i, line) in lines.enumerated() where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String, type == "user",
                  let promptId = json["promptId"] as? String,
                  !seenPromptIds.contains(promptId) else { continue }

            // Check if this user message has actual content (not a continuation)
            let msg = json["message"] as? [String: Any]
            var text = ""
            if let c = msg?["content"] as? String {
                text = c
            } else if let arr = msg?["content"] as? [[String: Any]] {
                text = arr.first(where: { $0["type"] as? String == "text" })?["text"] as? String ?? ""
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                seenPromptIds.insert(promptId)
                continue
            }

            seenPromptIds.insert(promptId)
            uniqueTurnCount += 1

            // When we hit the turn AFTER the one we want, cut here
            if uniqueTurnCount > afterTurnIndex {
                cutoffLineIndex = i
                break
            }
        }

        let truncatedLines = lines.prefix(cutoffLineIndex).filter { !$0.isEmpty }
        let truncatedContent = truncatedLines.joined(separator: "\n") + "\n"

        let newSessionId = UUID().uuidString.lowercased()
        let newPath = dir + "/\(newSessionId).jsonl"

        guard let writeData = truncatedContent.data(using: .utf8) else { return nil }
        do {
            try writeData.write(to: URL(fileURLWithPath: newPath), options: .atomic)
            return newSessionId
        } catch {
            return nil
        }
    }

    private func truncateCodexSession(sessionId: String, projectPath: String, afterTurnIndex: Int) -> String? {
        guard let sourceURL = codexSessionFileURL(sessionId: sessionId),
              let data = try? Data(contentsOf: sourceURL),
              let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var turnIndex = -1
        var cutoffLineIndex = lines.count
        var pendingTurnStartIndex: Int?

        for (i, line) in lines.enumerated() where !line.isEmpty {
            guard let json = parseJSONObject(line) else { continue }

            if codexLineStartsTurn(json) {
                pendingTurnStartIndex = i
            }

            guard codexRealUserMessageText(from: json) != nil else { continue }

            turnIndex += 1
            if turnIndex > afterTurnIndex {
                cutoffLineIndex = pendingTurnStartIndex ?? i
                break
            }

            pendingTurnStartIndex = nil
        }

        let keptLines = lines.prefix(cutoffLineIndex).filter { !$0.isEmpty }
        guard !keptLines.isEmpty else { return nil }

        let newSessionId = UUID().uuidString.lowercased()
        let now = Date()
        let destinationURL = codexRolloutURL(sessionId: newSessionId, date: now)

        var rewrittenLines: [String] = []
        rewrittenLines.reserveCapacity(keptLines.count)

        for (i, line) in keptLines.enumerated() {
            if i == 0 {
                guard let rewritten = rewriteCodexSessionMeta(line, newSessionId: newSessionId, date: now) else {
                    return nil
                }
                rewrittenLines.append(rewritten)
            } else {
                rewrittenLines.append(String(line))
            }
        }

        let firstMessage = codexFirstUserMessage(from: rewrittenLines)
        let truncatedContent = rewrittenLines.joined(separator: "\n") + "\n"

        do {
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try truncatedContent.write(to: destinationURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        guard registerCodexThreadFork(
            originalSessionId: sessionId,
            newSessionId: newSessionId,
            rolloutPath: destinationURL.path,
            firstUserMessage: firstMessage,
            date: now
        ) else {
            try? FileManager.default.removeItem(at: destinationURL)
            return nil
        }

        return newSessionId
    }

    private func codexLineStartsTurn(_ json: [String: Any]) -> Bool {
        if json["type"] as? String == "turn_context" {
            return true
        }
        guard json["type"] as? String == "event_msg",
              let payload = json["payload"] as? [String: Any] else { return false }
        return payload["type"] as? String == "task_started"
    }

    private func codexRealUserMessageText(from json: [String: Any]) -> String? {
        guard json["type"] as? String == "response_item",
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              payload["role"] as? String == "user",
              let text = codexMessageText(from: payload),
              !isSyntheticCodexUserMessage(text) else { return nil }
        return text
    }

    private func rewriteCodexSessionMeta(_ line: Substring, newSessionId: String, date: Date) -> String? {
        guard var json = parseJSONObject(line),
              json["type"] as? String == "session_meta",
              var payload = json["payload"] as? [String: Any] else { return nil }

        let timestamp = codexTimestampFormatter.string(from: date)
        json["timestamp"] = timestamp
        payload["id"] = newSessionId
        payload["timestamp"] = timestamp
        json["payload"] = payload

        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json),
              let rewritten = String(data: data, encoding: .utf8) else { return nil }
        return rewritten
    }

    private var codexTimestampFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private func codexRolloutURL(sessionId: String, date: Date) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: date)

        let stampFormatter = DateFormatter()
        stampFormatter.calendar = calendar
        stampFormatter.timeZone = calendar.timeZone
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"

        return codexSessionsRoot
            .appendingPathComponent(String(format: "%04d", components.year ?? 0))
            .appendingPathComponent(String(format: "%02d", components.month ?? 0))
            .appendingPathComponent(String(format: "%02d", components.day ?? 0))
            .appendingPathComponent("rollout-\(stampFormatter.string(from: date))-\(sessionId).jsonl")
    }

    private func codexFirstUserMessage(from lines: [String]) -> String {
        for line in lines {
            guard let json = parseJSONObject(Substring(line)),
                  let text = codexRealUserMessageText(from: json) else { continue }
            return text.split(separator: "\n").first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return ""
    }

    private func registerCodexThreadFork(originalSessionId: String, newSessionId: String, rolloutPath: String, firstUserMessage: String, date: Date) -> Bool {
        guard FileManager.default.fileExists(atPath: codexStateDatabaseURL.path) else { return false }

        let seconds = Int(date.timeIntervalSince1970)
        let milliseconds = Int(date.timeIntervalSince1970 * 1000)
        let title = firstUserMessage.isEmpty ? "Forked Codex session" : firstUserMessage

        let sql = """
        PRAGMA busy_timeout=2000;
        BEGIN IMMEDIATE;
        INSERT OR REPLACE INTO threads (
            id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
            sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
            git_sha, git_branch, git_origin_url, cli_version, first_user_message,
            agent_nickname, agent_role, memory_mode, model, reasoning_effort, agent_path,
            created_at_ms, updated_at_ms
        )
        SELECT
            \(sqlString(newSessionId)), \(sqlString(rolloutPath)), \(seconds), \(seconds),
            source, model_provider, cwd, \(sqlString(title)),
            sandbox_policy, approval_mode, 0, has_user_event, 0, NULL,
            git_sha, git_branch, git_origin_url, cli_version, \(sqlString(firstUserMessage)),
            agent_nickname, agent_role, memory_mode, model, reasoning_effort, agent_path,
            \(milliseconds), \(milliseconds)
        FROM threads
        WHERE id = \(sqlString(originalSessionId));
        SELECT changes();
        COMMIT;
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [codexStateDatabaseURL.path, sql]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        guard process.terminationStatus == 0 else { return false }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        return output.split(whereSeparator: \.isWhitespace).last == "1"
    }

    private func sqlString(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// Per-session cache so we don't flicker the context bar to nil when a tail
    /// read misses the usage entry (e.g. large tool-result block at end of file).
    /// Access only via `cachedUsage(_:)` and `setCachedUsage(_:for:)`.
    private var usageCache: [String: ContextUsage] = [:]
    private let cacheLock = NSLock()

    private func cachedUsage(_ sessionId: String) -> ContextUsage? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return usageCache[sessionId]
    }

    private func setCachedUsage(_ usage: ContextUsage, for sessionId: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        usageCache[sessionId] = usage
    }

    /// Get context usage for a session by reading its JSONL file.
    /// Only reads the tail of the file to find the most recent usage entry.
    /// Falls back to a cached value when the tail doesn't contain a usage entry.
    func getUsage(sessionId: String, projectPath: String) -> ContextUsage? {
        let encoded = projectPath.claudeProjectDirName
        let jsonlPath = NSHomeDirectory() + "/.claude/projects/\(encoded)/\(sessionId).jsonl"

        if let usage = getUsageFromFile(at: jsonlPath) {
            setCachedUsage(usage, for: sessionId)
            DiagnosticLog.shared.log("context",
                "getUsage: \(sessionId) \(usage.contextUsed)/\(usage.contextLimit) (\(Int(usage.percentage))%) model=\(usage.model)")
            return usage
        }

        // No usage found — return cached value if available
        let cached = cachedUsage(sessionId)
        DiagnosticLog.shared.log("context",
            "getUsage: \(sessionId) no usage found, cached=\(cached != nil)")
        return cached
    }

    /// Parse context usage from a JSONL file at the given path.
    /// Uses a progressive tail read (256KB then 1MB) to handle large files
    /// where tool results push usage entries far from the end.
    func getUsageFromFile(at jsonlPath: String) -> ContextUsage? {
        guard let fh = FileHandle(forReadingAtPath: jsonlPath) else { return nil }
        defer { try? fh.close() }

        let fileSize = fh.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        // --- Progressive tail read ---
        // Start with 256KB; if that misses, try 1MB. Large tool results
        // (file reads, grep output) can easily exceed 64KB.
        let tailSizes: [UInt64] = [256 * 1024, 1024 * 1024]

        for tailSize in tailSizes {
            let tailOffset = fileSize > tailSize ? fileSize - tailSize : 0
            fh.seek(toFileOffset: tailOffset)
            let tailData = fh.readData(ofLength: Int(fileSize - tailOffset))
            guard let tailContent = String(data: tailData, encoding: .utf8) else { continue }

            if let usage = parseUsage(from: tailContent) {
                return usage
            }
        }

        return nil
    }

    /// Parse the last usage entry from JSONL content, scanning lines in reverse.
    func parseUsage(from content: String) -> ContextUsage? {
        let lines = content.split(separator: "\n")
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let msg = json["message"] as? [String: Any], let usage = msg["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                if input + cacheRead == 0 { continue }
                let model = msg["model"] as? String ?? ""
                let limit = contextLimits[model] ?? defaultLimit
                return ContextUsage(model: model, inputTokens: input,
                                    cacheReadTokens: cacheRead, contextLimit: limit)
            }

            if let msg = json["message"] as? [String: Any],
               let inner = msg["message"] as? [String: Any],
               let usage = inner["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                if input + cacheRead == 0 { continue }
                let model = inner["model"] as? String ?? ""
                let limit = contextLimits[model] ?? defaultLimit
                return ContextUsage(model: model, inputTokens: input,
                                    cacheReadTokens: cacheRead, contextLimit: limit)
            }
        }
        return nil
    }
}

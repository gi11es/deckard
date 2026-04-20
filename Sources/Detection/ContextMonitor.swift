import Foundation

extension String {
    /// Encodes a project path into the directory name Claude Code uses under `~/.claude/projects/`.
    /// Resolves symlinks first so the encoded name matches the canonical path the CLI uses.
    /// The CLI replaces both "/" and "." with "-".
    var claudeProjectDirName: String {
        (self as NSString).resolvingSymlinksInPath
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}

/// Reads Claude Code session JSONL files to calculate context usage.
class ContextMonitor {
    static let shared = ContextMonitor()

    private let contextLimits: [String: Int] = [
        "claude-opus-4-6": 1_000_000,
        "claude-sonnet-4-6": 200_000,
        "claude-haiku-4-5": 200_000,
        "claude-haiku-4-5-20251001": 200_000,
    ]
    private let defaultLimit = 200_000

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

    struct SessionInfo {
        let sessionId: String
        let modificationDate: Date
        let firstUserMessage: String
        let messageCount: Int
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
                messageCount: 0
            ))
        }

        results.sort { $0.modificationDate > $1.modificationDate }
        return results
    }

    /// Parses a session JSONL file and returns an ordered list of user turns.
    /// Deduplicates by promptId — only the first occurrence with non-empty content is kept.
    func parseTimeline(sessionId: String, projectPath: String) -> [TimelineEntry] {
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

    /// Extracts a raw description of tool uses for each user turn in a session.
    /// Returns a dictionary mapping turn index to a list of action descriptions.
    func parseActions(sessionId: String, projectPath: String) -> [Int: [String]] {
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

    /// Creates a truncated copy of a session JSONL, keeping everything up to (and including
    /// the full response for) the Nth unique user turn. Returns the new session ID.
    func truncateSession(sessionId: String, projectPath: String, afterTurnIndex: Int) -> String? {
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

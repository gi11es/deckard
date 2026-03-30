import Foundation

extension String {
    /// Encodes a project path into the directory name Claude Code uses under `~/.claude/projects/`.
    /// Resolves symlinks first so the encoded name matches the canonical path the CLI uses.
    var claudeProjectDirName: String {
        (self as NSString).resolvingSymlinksInPath.replacingOccurrences(of: "/", with: "-")
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
            var uniqueUserTurns = 0

            if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
               let fileContent = String(data: data, encoding: .utf8) {
                var seenPromptIds = Set<String>()
                let lines = fileContent.components(separatedBy: "\n")
                for line in lines where !line.isEmpty {
                    guard let ld = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] else { continue }

                    let type = json["type"] as? String ?? ""
                    if type == "user", let promptId = json["promptId"] as? String, !seenPromptIds.contains(promptId) {
                        let msg = json["message"] as? [String: Any]
                        var text = ""
                        if let content = msg?["content"] as? String {
                            text = content
                        } else if let contentArr = msg?["content"] as? [[String: Any]] {
                            text = contentArr.first(where: { $0["type"] as? String == "text" })?["text"] as? String ?? ""
                        }
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else {
                            seenPromptIds.insert(promptId)
                            continue
                        }
                        seenPromptIds.insert(promptId)
                        uniqueUserTurns += 1
                        if firstMessage.isEmpty {
                            firstMessage = trimmed.components(separatedBy: "\n").first ?? ""
                        }
                    }
                }
            }

            results.append(SessionInfo(
                sessionId: sessionId,
                modificationDate: modDate,
                firstUserMessage: firstMessage,
                messageCount: uniqueUserTurns
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

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
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
                isBookmarked: false,
                bookmarkLabel: nil
            ))
        }

        return entries
    }

    /// Creates a truncated copy of a session JSONL, keeping everything up to (and including
    /// the full response for) the Nth unique user turn. Returns the new session ID.
    func truncateSession(sessionId: String, projectPath: String, afterTurnIndex: Int) -> String? {
        let encoded = projectPath.claudeProjectDirName
        let dir = NSHomeDirectory() + "/.claude/projects/\(encoded)"
        let jsonlPath = dir + "/\(sessionId).jsonl"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonlPath)),
              let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n")
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
            if let c = msg?["content"] as? String { text = c }
            else if let arr = msg?["content"] as? [[String: Any]] {
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

    /// Get context usage for a session by reading its JSONL file.
    /// Only reads the tail of the file to find the most recent usage entry.
    func getUsage(sessionId: String, projectPath: String) -> ContextUsage? {
        let encoded = projectPath.claudeProjectDirName
        let jsonlPath = NSHomeDirectory() + "/.claude/projects/\(encoded)/\(sessionId).jsonl"

        guard let fh = FileHandle(forReadingAtPath: jsonlPath) else { return nil }
        defer { try? fh.close() }

        let fileSize = fh.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        // --- Find last usage: read only the tail of the file ---
        // Usage entries appear near the end. Read the last 64KB (enough for
        // several assistant response entries).
        let tailSize: UInt64 = 64 * 1024
        let tailOffset = fileSize > tailSize ? fileSize - tailSize : 0
        fh.seek(toFileOffset: tailOffset)
        let tailData = fh.readData(ofLength: Int(fileSize - tailOffset))
        guard let tailContent = String(data: tailData, encoding: .utf8) else { return nil }

        var lastInput = 0
        var lastCacheRead = 0
        var model = ""

        // Split tail into lines and scan in reverse for the last usage entry
        let lines = tailContent.components(separatedBy: "\n")
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let msg = json["message"] as? [String: Any], let usage = msg["usage"] as? [String: Any] {
                lastInput = usage["input_tokens"] as? Int ?? 0
                lastCacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                if lastInput + lastCacheRead == 0 { continue }
                model = msg["model"] as? String ?? model
                break
            }

            if let msg = json["message"] as? [String: Any],
               let inner = msg["message"] as? [String: Any],
               let usage = inner["usage"] as? [String: Any] {
                lastInput = usage["input_tokens"] as? Int ?? 0
                lastCacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                if lastInput + lastCacheRead == 0 { continue }
                model = inner["model"] as? String ?? model
                break
            }
        }

        guard !model.isEmpty || lastInput > 0 || lastCacheRead > 0 else { return nil }

        let limit = contextLimits[model] ?? defaultLimit

        return ContextUsage(
            model: model,
            inputTokens: lastInput,
            cacheReadTokens: lastCacheRead,
            contextLimit: limit,
        )
    }
}

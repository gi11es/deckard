import Foundation

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
    }

    /// Lists all Claude sessions for a project, sorted by most recent first.
    func listSessions(forProjectPath projectPath: String) -> [SessionInfo] {
        let resolved = (projectPath as NSString).resolvingSymlinksInPath
        let encoded = resolved.replacingOccurrences(of: "/", with: "-")
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
                    let lines = headStr.components(separatedBy: "\n")
                    for line in lines where !line.isEmpty {
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

            firstMessage = firstMessage.components(separatedBy: "\n").first ?? ""
            firstMessage = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)

            results.append(SessionInfo(
                sessionId: sessionId,
                modificationDate: modDate,
                firstUserMessage: firstMessage
            ))
        }

        results.sort { $0.modificationDate > $1.modificationDate }
        return results
    }

    /// Get context usage for a session by reading its JSONL file.
    /// Only reads the tail of the file to find the most recent usage entry.
    func getUsage(sessionId: String, projectPath: String) -> ContextUsage? {
        let resolved = (projectPath as NSString).resolvingSymlinksInPath
        let encoded = resolved.replacingOccurrences(of: "/", with: "-")
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

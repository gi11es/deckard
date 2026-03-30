import Foundation

/// Generates and caches AI-generated session summaries by shelling out to `claude --print`.
class SummaryManager {
    static let shared = SummaryManager()

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let deckardDir = appSupport.appendingPathComponent("Deckard")
        try? FileManager.default.createDirectory(at: deckardDir, withIntermediateDirectories: true)
        return deckardDir.appendingPathComponent("session-summaries.json")
    }()

    private var cache: [String: CachedSummary]?
    private var inFlightSessionIds = Set<String>()

    struct CachedSummary: Codable {
        let summary: String
        let generatedAt: Date
        var turnCount: Int?
    }

    /// Returns a cached summary for the session, or nil if not yet generated.
    func cachedSummary(forSessionId sessionId: String) -> String? {
        let all = loadAll()
        return all[sessionId]?.summary
    }

    /// Returns the cached turn count for a session summary, or 0 if unknown.
    func cachedSummaryTurnCount(forSessionId sessionId: String) -> Int {
        let all = loadAll()
        return all[sessionId]?.turnCount ?? 0
    }

    /// Returns true if a summary generation is currently in progress for this session.
    func isGenerating(sessionId: String) -> Bool {
        inFlightSessionIds.contains(sessionId)
    }

    /// Generates a session summary. If a cached summary exists but the session has more
    /// turns than when it was generated, the summary is regenerated.
    /// Calls `completion` on the main thread with the result.
    func generateSummary(sessionId: String, projectPath: String, currentTurnCount: Int, completion: @escaping (String?) -> Void) {
        let all = loadAll()
        let cached = all[sessionId]

        // Return cached if it covers all current turns
        if let cached, (cached.turnCount ?? 0) >= currentTurnCount {
            completion(cached.summary)
            return
        }

        // Already in flight?
        guard !inFlightSessionIds.contains(sessionId) else { return }
        inFlightSessionIds.insert(sessionId)

        // Parse user messages for the prompt
        let entries = ContextMonitor.shared.parseTimeline(sessionId: sessionId, projectPath: projectPath)
        guard !entries.isEmpty else {
            inFlightSessionIds.remove(sessionId)
            completion(cached?.summary)
            return
        }

        let userMessages = entries.map { $0.message }.joined(separator: "\n---\n")
        let prompt = "Summarize this Claude Code session in 1-2 concise sentences, focusing on what was accomplished. Only output the summary, nothing else.\n\nUser messages:\n\(userMessages)"

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = self?.runClaudePrint(prompt: prompt)

            DispatchQueue.main.async {
                self?.inFlightSessionIds.remove(sessionId)

                if let summary = result, !summary.isEmpty {
                    self?.saveSummary(sessionId: sessionId, summary: summary, turnCount: entries.count)
                    completion(summary)
                } else {
                    completion(cached?.summary)
                }
            }
        }
    }

    // MARK: - Turn Summaries (persisted, incremental)

    struct CachedTurnSummaries: Codable {
        var summaries: [String: String]  // "turnIndex" → summary (String keys for Codable)
    }

    private let turnSummariesURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let deckardDir = appSupport.appendingPathComponent("Deckard")
        try? FileManager.default.createDirectory(at: deckardDir, withIntermediateDirectories: true)
        return deckardDir.appendingPathComponent("turn-summaries.json")
    }()

    private var turnSummariesCache: [String: CachedTurnSummaries]?

    /// Returns all cached turn summaries for a session.
    func cachedTurnSummaries(forSessionId sessionId: String) -> [Int: String] {
        let all = loadAllTurnSummaries()
        guard let cached = all[sessionId] else { return [:] }
        var result: [Int: String] = [:]
        for (key, value) in cached.summaries {
            if let idx = Int(key) { result[idx] = value }
        }
        return result
    }

    /// Generates action summaries for turns that don't already have cached summaries.
    /// Returns cached summaries immediately via `completion`, then generates missing ones
    /// and calls `completion` again with the full set when done.
    /// `actions` maps turn index to raw action descriptions. `totalTurnCount` is the current
    /// number of turns in the session (used to detect continued sessions).
    func generateTurnSummaries(sessionId: String, actions: [Int: [String]], completion: @escaping ([Int: String]) -> Void) {
        let key = "turns-\(sessionId)"

        // Load existing cached summaries
        let existing = cachedTurnSummaries(forSessionId: sessionId)

        // Figure out which turns need summarization (have actions but no cached summary)
        let nonEmpty = actions.filter { !$0.value.isEmpty }
        let needsSummary = nonEmpty.filter { existing[$0.key] == nil }

        // If everything is cached, return immediately
        if needsSummary.isEmpty {
            completion(existing)
            return
        }

        // Return what we have so far
        if !existing.isEmpty {
            completion(existing)
        }

        // Don't double-generate
        guard !inFlightSessionIds.contains(key) else { return }
        inFlightSessionIds.insert(key)

        // Build prompt only for new turns
        var promptLines = ["For each numbered turn below, write a single short sentence (max 10 words) summarizing what was done. Output one line per turn in the format \"N: summary\". No other text.\n"]
        for turnIndex in needsSummary.keys.sorted() {
            let actionList = needsSummary[turnIndex]!.joined(separator: ", ")
            promptLines.append("\(turnIndex): \(actionList)")
        }
        let prompt = promptLines.joined(separator: "\n")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = self?.runClaudePrint(prompt: prompt)

            DispatchQueue.main.async {
                self?.inFlightSessionIds.remove(key)

                var newSummaries: [Int: String] = [:]
                if let output = result {
                    for line in output.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
                        let numStr = trimmed[trimmed.startIndex..<colonIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let turnIdx = Int(numStr) else { continue }
                        let summary = trimmed[trimmed.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !summary.isEmpty {
                            newSummaries[turnIdx] = summary
                        }
                    }
                }

                // Merge with existing and persist
                let merged = existing.merging(newSummaries) { _, new in new }
                self?.saveTurnSummaries(sessionId: sessionId, summaries: merged)
                completion(merged)
            }
        }
    }

    private func loadAllTurnSummaries() -> [String: CachedTurnSummaries] {
        if let cached = turnSummariesCache { return cached }
        guard let data = try? Data(contentsOf: turnSummariesURL),
              let dict = try? JSONDecoder().decode([String: CachedTurnSummaries].self, from: data) else {
            turnSummariesCache = [:]
            return [:]
        }
        turnSummariesCache = dict
        return dict
    }

    private func saveTurnSummaries(sessionId: String, summaries: [Int: String]) {
        var all = loadAllTurnSummaries()
        var codable: [String: String] = [:]
        for (key, value) in summaries { codable[String(key)] = value }
        all[sessionId] = CachedTurnSummaries(summaries: codable)
        turnSummariesCache = all
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: turnSummariesURL, options: .atomic)
    }

    // MARK: - Private

    private func runClaudePrint(prompt: String) -> String? {
        let process = Process()
        // Search common locations for the claude binary
        let candidates = ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        var claudePath: String?
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                claudePath = path
                break
            }
        }
        // Fallback: search PATH
        if claudePath == nil, let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let full = "\(dir)/claude"
                if FileManager.default.isExecutableFile(atPath: full) {
                    claudePath = full
                    break
                }
            }
        }
        guard let resolvedPath = claudePath else { return nil }

        process.executableURL = URL(fileURLWithPath: resolvedPath)
        process.arguments = ["--print", "--model", "haiku", "-p", prompt]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadAll() -> [String: CachedSummary] {
        if let cached = cache { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? decoder.decode([String: CachedSummary].self, from: data) else {
            cache = [:]
            return [:]
        }
        cache = dict
        return dict
    }

    private func saveSummary(sessionId: String, summary: String, turnCount: Int) {
        var all = loadAll()
        all[sessionId] = CachedSummary(summary: summary, generatedAt: Date(), turnCount: turnCount)
        cache = all
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

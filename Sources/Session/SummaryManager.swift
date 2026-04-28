import Foundation

/// Generates and caches AI-generated session summaries by shelling out to `claude --print`.
class SummaryManager {
    static let shared = SummaryManager()

    struct CombinedSummaryRequest {
        let sessionId: String
        let projectPath: String
        let kind: TabKind
        let currentTurnCount: Int
        let actions: [Int: [String]]
    }

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
        cachedSummary(forSessionId: sessionId, kind: .claude)
    }

    func cachedSummary(forSessionId sessionId: String, kind: TabKind) -> String? {
        let all = loadAll()
        return all[cacheKey(sessionId: sessionId, kind: kind)]?.summary
    }

    /// Returns the cached turn count for a session summary, or 0 if unknown.
    func cachedSummaryTurnCount(forSessionId sessionId: String) -> Int {
        cachedSummaryTurnCount(forSessionId: sessionId, kind: .claude)
    }

    func cachedSummaryTurnCount(forSessionId sessionId: String, kind: TabKind) -> Int {
        let all = loadAll()
        return all[cacheKey(sessionId: sessionId, kind: kind)]?.turnCount ?? 0
    }

    /// Returns true if a summary generation is currently in progress for this session.
    func isGenerating(sessionId: String) -> Bool {
        inFlightSessionIds.contains(sessionId)
    }

    /// Generates a session summary. If a cached summary exists but the session has more
    /// turns than when it was generated, the summary is regenerated.
    /// Calls `completion` on the main thread with the result.
    func generateSummary(sessionId: String, projectPath: String, currentTurnCount: Int, completion: @escaping (String?) -> Void) {
        generateSummary(sessionId: sessionId, projectPath: projectPath, kind: .claude, currentTurnCount: currentTurnCount, completion: completion)
    }

    func generateSummary(sessionId: String, projectPath: String, kind: TabKind, currentTurnCount: Int, completion: @escaping (String?) -> Void) {
        let cacheKey = cacheKey(sessionId: sessionId, kind: kind)
        let all = loadAll()
        let cached = all[cacheKey]

        // Return cached if it covers all current turns
        if let cached, (cached.turnCount ?? 0) >= currentTurnCount {
            completion(cached.summary)
            return
        }

        // Already in flight?
        guard !inFlightSessionIds.contains(cacheKey) else { return }
        inFlightSessionIds.insert(cacheKey)

        // Parse user messages for the prompt
        let entries = ContextMonitor.shared.parseTimeline(sessionId: sessionId, projectPath: projectPath, kind: kind)
        guard !entries.isEmpty else {
            inFlightSessionIds.remove(cacheKey)
            completion(cached?.summary)
            return
        }

        let userMessages = entries.map { $0.message }.joined(separator: "\n---\n")
        let prompt = "Summarize this \(kind.displayName) session in 1-2 concise sentences, focusing on what was accomplished. Only output the summary, nothing else.\n\nUser messages:\n\(userMessages)"

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = self?.runClaudePrint(prompt: prompt)

            DispatchQueue.main.async {
                self?.inFlightSessionIds.remove(cacheKey)

                if let summary = result, !summary.isEmpty {
                    self?.saveSummary(sessionId: cacheKey, summary: summary, turnCount: entries.count)
                    completion(summary)
                } else {
                    completion(cached?.summary)
                }
            }
        }
    }

    // MARK: - Combined Summary (session + actions in one AI call)

    /// Generates both a session summary and per-turn action summaries in a single haiku call.
    /// Calls `completion` on the main thread with (sessionSummary, actionSummaries).
    func generateCombinedSummaries(
        sessionId: String,
        projectPath: String,
        currentTurnCount: Int,
        actions: [Int: [String]],
        completion: @escaping (String?, [Int: String]) -> Void
    ) {
        generateCombinedSummaries(
            CombinedSummaryRequest(
                sessionId: sessionId,
                projectPath: projectPath,
                kind: .claude,
                currentTurnCount: currentTurnCount,
                actions: actions),
            completion: completion)
    }

    func generateCombinedSummaries(
        _ request: CombinedSummaryRequest,
        completion: @escaping (String?, [Int: String]) -> Void
    ) {
        let sessionId = request.sessionId
        let projectPath = request.projectPath
        let kind = request.kind
        let currentTurnCount = request.currentTurnCount
        let actions = request.actions
        let sessionCacheKey = cacheKey(sessionId: sessionId, kind: kind)
        let key = "combined-\(sessionCacheKey)"
        guard !inFlightSessionIds.contains(key) else { return }
        inFlightSessionIds.insert(key)

        // Determine what needs generation
        let cachedSessionSummary = loadAll()[sessionCacheKey]
        let needsSessionSummary = cachedSessionSummary == nil || (cachedSessionSummary?.turnCount ?? 0) < currentTurnCount

        let existingTurnSummaries = cachedTurnSummaries(forSessionId: sessionId, kind: kind)
        let nonEmpty = actions.filter { !$0.value.isEmpty }
        let needsTurnSummaries = nonEmpty.filter { existingTurnSummaries[$0.key] == nil }

        // If nothing to do, return cached
        if !needsSessionSummary && needsTurnSummaries.isEmpty {
            inFlightSessionIds.remove(key)
            completion(cachedSessionSummary?.summary, existingTurnSummaries)
            return
        }

        // Build combined prompt
        let entries = ContextMonitor.shared.parseTimeline(sessionId: sessionId, projectPath: projectPath, kind: kind)
        let userMessages = entries.map { $0.message }.joined(separator: "\n---\n")

        var promptParts: [String] = []

        if needsSessionSummary {
            promptParts.append("PART 1: Summarize this \(kind.displayName) session in 1-2 concise sentences, focusing on what was accomplished. Output on a line starting with \"SESSION:\".")
            promptParts.append("\nUser messages:\n\(userMessages)\n")
        }

        if !needsTurnSummaries.isEmpty {
            promptParts.append("PART 2: For each numbered turn below, write a single short sentence (max 10 words) summarizing what was done. Output one line per turn in the format \"N: summary\".\n")
            for turnIndex in needsTurnSummaries.keys.sorted() {
                let actionList = needsTurnSummaries[turnIndex]!.joined(separator: ", ")
                promptParts.append("\(turnIndex): \(actionList)")
            }
        }

        promptParts.append("\nOutput nothing else.")
        let prompt = promptParts.joined(separator: "\n")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = self?.runClaudePrint(prompt: prompt)

            DispatchQueue.main.async {
                self?.inFlightSessionIds.remove(key)

                var sessionSummary: String?
                var newTurnSummaries: [Int: String] = [:]

                if let output = result {
                    for line in output.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.hasPrefix("SESSION:") {
                            sessionSummary = String(trimmed.dropFirst("SESSION:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if let colonIdx = trimmed.firstIndex(of: ":") {
                            let numStr = trimmed[trimmed.startIndex..<colonIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                            if let turnIdx = Int(numStr) {
                                let summary = trimmed[trimmed.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
                                if !summary.isEmpty {
                                    newTurnSummaries[turnIdx] = summary
                                }
                            }
                        }
                    }
                }

                // Persist session summary
                if let summary = sessionSummary, needsSessionSummary {
                    self?.saveSummary(sessionId: sessionCacheKey, summary: summary, turnCount: currentTurnCount)
                }

                // Mark all requested turns as cached (empty string for ones haiku skipped)
                // so they aren't re-requested on next open
                var allRequestedTurns: [Int: String] = [:]
                for turnIndex in needsTurnSummaries.keys {
                    allRequestedTurns[turnIndex] = newTurnSummaries[turnIndex] ?? ""
                }
                let mergedTurns = existingTurnSummaries.merging(allRequestedTurns) { _, new in new }
                if !needsTurnSummaries.isEmpty {
                    self?.saveTurnSummaries(sessionId: sessionCacheKey, summaries: mergedTurns)
                }

                completion(
                    sessionSummary ?? cachedSessionSummary?.summary,
                    mergedTurns
                )
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
        cachedTurnSummaries(forSessionId: sessionId, kind: .claude)
    }

    func cachedTurnSummaries(forSessionId sessionId: String, kind: TabKind) -> [Int: String] {
        let all = loadAllTurnSummaries()
        guard let cached = all[cacheKey(sessionId: sessionId, kind: kind)] else { return [:] }
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
        generateTurnSummaries(sessionId: sessionId, kind: .claude, actions: actions, completion: completion)
    }

    func generateTurnSummaries(sessionId: String, kind: TabKind, actions: [Int: [String]], completion: @escaping ([Int: String]) -> Void) {
        let sessionCacheKey = cacheKey(sessionId: sessionId, kind: kind)
        let key = "turns-\(sessionCacheKey)"

        // Load existing cached summaries
        let existing = cachedTurnSummaries(forSessionId: sessionId, kind: kind)

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
                self?.saveTurnSummaries(sessionId: sessionCacheKey, summaries: merged)
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

    private func cacheKey(sessionId: String, kind: TabKind) -> String {
        kind == .claude ? sessionId : "\(kind.rawValue):\(sessionId)"
    }

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
        process.arguments = ["--print", "--model", "haiku", "--effort", "low", "-p", prompt]

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

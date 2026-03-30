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
    }

    /// Returns a cached summary for the session, or nil if not yet generated.
    func cachedSummary(forSessionId sessionId: String) -> String? {
        let all = loadAll()
        return all[sessionId]?.summary
    }

    /// Returns true if a summary generation is currently in progress for this session.
    func isGenerating(sessionId: String) -> Bool {
        inFlightSessionIds.contains(sessionId)
    }

    /// Generates a summary asynchronously. Calls `completion` on the main thread with the result.
    /// Does nothing if a summary is already cached or generation is in flight.
    func generateSummary(sessionId: String, projectPath: String, completion: @escaping (String?) -> Void) {
        // Already cached?
        if let existing = cachedSummary(forSessionId: sessionId) {
            completion(existing)
            return
        }

        // Already in flight?
        guard !inFlightSessionIds.contains(sessionId) else { return }
        inFlightSessionIds.insert(sessionId)

        // Parse user messages for the prompt
        let entries = ContextMonitor.shared.parseTimeline(sessionId: sessionId, projectPath: projectPath)
        guard !entries.isEmpty else {
            inFlightSessionIds.remove(sessionId)
            completion(nil)
            return
        }

        let userMessages = entries.map { $0.message }.joined(separator: "\n---\n")
        let prompt = "Summarize this Claude Code session in one concise sentence, focusing on what was accomplished. Only output the summary, nothing else.\n\nUser messages:\n\(userMessages)"

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = self?.runClaudePrint(prompt: prompt)

            DispatchQueue.main.async {
                self?.inFlightSessionIds.remove(sessionId)

                if let summary = result, !summary.isEmpty {
                    self?.saveSummary(sessionId: sessionId, summary: summary)
                    completion(summary)
                } else {
                    completion(nil)
                }
            }
        }
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

    private func saveSummary(sessionId: String, summary: String) {
        var all = loadAll()
        all[sessionId] = CachedSummary(summary: summary, generatedAt: Date())
        cache = all
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

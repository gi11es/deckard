import Foundation

/// Tracks Claude Code API rate limits and token usage rates.
class QuotaMonitor {
    static let shared = QuotaMonitor()
    static let quotaDidChange = Notification.Name("QuotaMonitorQuotaDidChange")

    private static let cacheKey = "QuotaMonitorSnapshot"

    struct QuotaSnapshot {
        var fiveHourUsed: Double       // 0-100
        var fiveHourResetsAt: Date?
        var sevenDayUsed: Double       // 0-100
        var sevenDayResetsAt: Date?
        var lastUpdated: Date
    }

    struct TokenRate {
        var tokensPerMinute: Double
        var windowSeconds: Int  // how far back we looked
    }

    private var cachedSnapshot: QuotaSnapshot?
    private var liveSnapshot: QuotaSnapshot?
    private let launchTime = Date()

    /// Returns the live snapshot if available, otherwise the cached snapshot
    /// (but only after a 2-second grace period to avoid flashing stale values
    /// before fresh statusLine data arrives).
    var latest: QuotaSnapshot? {
        if let live = liveSnapshot { return live }
        if Date().timeIntervalSince(launchTime) > 2.0 { return cachedSnapshot }
        return nil
    }

    private(set) var tokenRate: TokenRate?
    private(set) var sparklineData: [Double] = []  // Ring buffer, max 30 points
    private var lastSparklinePush: Date = .distantPast
    private let sparklineMaxPoints = 30
    private let sparklinePushInterval: TimeInterval = 10  // seconds between data points

    init() {
        loadCachedSnapshot()
    }

    /// Called from HookHandler when a hook event arrives with rate limit data.
    /// Merges non-nil fields into the current snapshot.
    func update(fiveHourUsed: Double?, fiveHourResetsAt: Double?,
                sevenDayUsed: Double?, sevenDayResetsAt: Double?) {
        var snapshot = liveSnapshot ?? cachedSnapshot ?? QuotaSnapshot(
            fiveHourUsed: 0, fiveHourResetsAt: nil,
            sevenDayUsed: 0, sevenDayResetsAt: nil,
            lastUpdated: Date())

        if let v = fiveHourUsed { snapshot.fiveHourUsed = v }
        if let v = fiveHourResetsAt { snapshot.fiveHourResetsAt = Date(timeIntervalSince1970: v) }
        if let v = sevenDayUsed { snapshot.sevenDayUsed = v }
        if let v = sevenDayResetsAt { snapshot.sevenDayResetsAt = Date(timeIntervalSince1970: v) }
        snapshot.lastUpdated = Date()

        liveSnapshot = snapshot
        saveCachedSnapshot(snapshot)
        NotificationCenter.default.post(name: Self.quotaDidChange, object: self)
    }

    // MARK: - Persistence

    private func saveCachedSnapshot(_ snap: QuotaSnapshot) {
        var dict: [String: Any] = [
            "fiveHourUsed": snap.fiveHourUsed,
            "sevenDayUsed": snap.sevenDayUsed,
            "lastUpdated": snap.lastUpdated.timeIntervalSince1970,
        ]
        if let d = snap.fiveHourResetsAt { dict["fiveHourResetsAt"] = d.timeIntervalSince1970 }
        if let d = snap.sevenDayResetsAt { dict["sevenDayResetsAt"] = d.timeIntervalSince1970 }
        UserDefaults.standard.set(dict, forKey: Self.cacheKey)
    }

    private func loadCachedSnapshot() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.cacheKey) else { return }
        let fiveUsed = dict["fiveHourUsed"] as? Double ?? 0
        let sevenUsed = dict["sevenDayUsed"] as? Double ?? 0
        let lastUpdated = (dict["lastUpdated"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let fiveResets = (dict["fiveHourResetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let sevenResets = (dict["sevenDayResetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }

        // Only use cached data if it's less than 6 hours old
        guard Date().timeIntervalSince(lastUpdated) < 6 * 3600 else { return }

        cachedSnapshot = QuotaSnapshot(
            fiveHourUsed: fiveUsed,
            fiveHourResetsAt: fiveResets,
            sevenDayUsed: sevenUsed,
            sevenDayResetsAt: sevenResets,
            lastUpdated: lastUpdated)
    }

    /// Compute tokens-per-minute from the single most recently written session JSONL.
    /// Only considers the one file most recently modified (the active conversation),
    /// and only counts output_tokens with timestamps in the last 5 minutes.
    func computeTokenRate(projectPaths: [String]) -> TokenRate? {
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)  // 5 minutes ago
        let recentCutoff = now.addingTimeInterval(-120)  // 2 minutes ago (must be very recent)
        let fm = FileManager.default

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Find the single most recently modified JSONL across all projects
        var bestFile: String?
        var bestDate: Date = .distantPast

        for projectPath in projectPaths {
            let resolved = (projectPath as NSString).resolvingSymlinksInPath
            let encoded = resolved.replacingOccurrences(of: "/", with: "-")
            let dir = NSHomeDirectory() + "/.claude/projects/\(encoded)"

            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = dir + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }
                if modDate > recentCutoff && modDate > bestDate {
                    bestDate = modDate
                    bestFile = filePath
                }
            }
        }

        guard let jsonlPath = bestFile else {
            tokenRate = nil
            return nil
        }

        var totalOutputTokens = 0
        var earliestTimestamp: Date?
        var latestTimestamp: Date?

        // Read last 128KB of the file using FileHandle-based tail reading
        guard let fh = FileHandle(forReadingAtPath: jsonlPath) else {
            tokenRate = nil
            return nil
        }
        defer { try? fh.close() }

        let fileSize = fh.seekToEndOfFile()
        guard fileSize > 0 else {
            tokenRate = nil
            return nil
        }

        let tailSize: UInt64 = 128 * 1024
        let tailOffset = fileSize > tailSize ? fileSize - tailSize : 0
        fh.seek(toFileOffset: tailOffset)
        let tailData = fh.readData(ofLength: Int(fileSize - tailOffset))
        guard let tailContent = String(data: tailData, encoding: .utf8) else {
            tokenRate = nil
            return nil
        }

        // Parse lines in reverse looking for output_tokens with timestamps
        let lines = tailContent.components(separatedBy: "\n")
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            // Look for timestamp
            guard let timestampStr = json["timestamp"] as? String,
                  let timestamp = isoFormatter.date(from: timestampStr) else { continue }

            // Skip entries older than 5 minutes
            if timestamp < cutoff { break }

            // Look for message.usage.output_tokens
            if let msg = json["message"] as? [String: Any],
               let usage = msg["usage"] as? [String: Any],
               let outputTokens = usage["output_tokens"] as? Int {
                totalOutputTokens += outputTokens

                if earliestTimestamp == nil || timestamp < earliestTimestamp! {
                    earliestTimestamp = timestamp
                }
                if latestTimestamp == nil || timestamp > latestTimestamp! {
                    latestTimestamp = timestamp
                }
            }
        }

        guard totalOutputTokens > 0, let earliest = earliestTimestamp else {
            tokenRate = nil
            return nil
        }

        // Compute elapsed minutes from actual time span, min 1.0
        let elapsedSeconds = (latestTimestamp ?? now).timeIntervalSince(earliest)
        let elapsedMinutes = max(elapsedSeconds / 60.0, 1.0)
        let tokensPerMinute = Double(totalOutputTokens) / elapsedMinutes
        let windowSeconds = Int(now.timeIntervalSince(earliest))

        let rate = TokenRate(tokensPerMinute: tokensPerMinute, windowSeconds: windowSeconds)
        tokenRate = rate

        // Push to sparkline ring buffer if enough time has elapsed
        if now.timeIntervalSince(lastSparklinePush) >= sparklinePushInterval {
            if sparklineData.count >= sparklineMaxPoints {
                sparklineData.removeFirst()
            }
            sparklineData.append(tokensPerMinute)
            lastSparklinePush = now
        }

        return rate
    }

    /// Clears all state (for unit tests).
    func resetForTesting() {
        liveSnapshot = nil
        cachedSnapshot = nil
        tokenRate = nil
        sparklineData = []
        lastSparklinePush = .distantPast
    }
}

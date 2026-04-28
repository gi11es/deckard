import Foundation

/// Manages session bookmarks persisted to ~/Library/Application Support/Deckard/session-bookmarks.json.
/// Stores a set of bookmarked session IDs per project path.
class BookmarkManager {
    static let shared = BookmarkManager()

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let deckardDir = appSupport.appendingPathComponent("Deckard")
        try? FileManager.default.createDirectory(at: deckardDir, withIntermediateDirectories: true)
        return deckardDir.appendingPathComponent("session-bookmarks.json")
    }()

    private var cache: [String: [String]]?  // projectKey -> [sessionId]

    /// Returns all bookmarked session IDs for a project.
    func bookmarkedSessionIds(forProjectPath projectPath: String) -> Set<String> {
        bookmarkedSessionIds(forProjectPath: projectPath, kind: .claude)
    }

    func bookmarkedSessionIds(forProjectPath projectPath: String, kind: TabKind) -> Set<String> {
        let all = loadAll()
        let key = projectKey(projectPath: projectPath, kind: kind)
        return Set(all[key] ?? [])
    }

    /// Checks if a session is bookmarked.
    func isBookmarked(projectPath: String, sessionId: String) -> Bool {
        isBookmarked(projectPath: projectPath, sessionId: sessionId, kind: .claude)
    }

    func isBookmarked(projectPath: String, sessionId: String, kind: TabKind) -> Bool {
        bookmarkedSessionIds(forProjectPath: projectPath, kind: kind).contains(sessionId)
    }

    /// Toggles the bookmark state for a session. Returns the new state.
    @discardableResult
    func toggleBookmark(projectPath: String, sessionId: String) -> Bool {
        toggleBookmark(projectPath: projectPath, sessionId: sessionId, kind: .claude)
    }

    @discardableResult
    func toggleBookmark(projectPath: String, sessionId: String, kind: TabKind) -> Bool {
        var all = loadAll()
        let key = projectKey(projectPath: projectPath, kind: kind)
        var ids = all[key] ?? []

        if let idx = ids.firstIndex(of: sessionId) {
            ids.remove(at: idx)
            all[key] = ids
            saveAll(all)
            return false
        } else {
            ids.append(sessionId)
            all[key] = ids
            saveAll(all)
            return true
        }
    }

    // MARK: - Private

    private func projectKey(projectPath: String, kind: TabKind) -> String {
        let encoded = projectPath.claudeProjectDirName
        return kind == .claude ? encoded : "\(kind.rawValue):\(encoded)"
    }

    private func loadAll() -> [String: [String]] {
        if let cached = cache { return cached }
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            cache = [:]
            return [:]
        }
        cache = dict
        return dict
    }

    private func saveAll(_ dict: [String: [String]]) {
        cache = dict
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(dict) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

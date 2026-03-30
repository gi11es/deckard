import Foundation

/// Manages session bookmarks persisted to ~/Library/Application Support/Deckard/session-bookmarks.json.
/// Bookmarks are keyed by the encoded project path (matching Claude Code's convention).
class BookmarkManager {
    static let shared = BookmarkManager()

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let deckardDir = appSupport.appendingPathComponent("Deckard")
        try? FileManager.default.createDirectory(at: deckardDir, withIntermediateDirectories: true)
        return deckardDir.appendingPathComponent("session-bookmarks.json")
    }()

    private var cache: [String: [SessionBookmark]]?

    /// Returns all bookmarks for a given project path.
    func bookmarks(forProjectPath projectPath: String) -> [SessionBookmark] {
        let all = loadAll()
        let key = projectPath.claudeProjectDirName
        return all[key] ?? []
    }

    /// Adds a bookmark. Returns the created bookmark.
    @discardableResult
    func addBookmark(projectPath: String, sessionId: String, messageIndex: Int, label: String) -> SessionBookmark {
        var all = loadAll()
        let key = projectPath.claudeProjectDirName
        var projectBookmarks = all[key] ?? []

        let bookmark = SessionBookmark(
            sessionId: sessionId,
            messageIndex: messageIndex,
            label: label,
            createdAt: Date()
        )
        projectBookmarks.append(bookmark)
        all[key] = projectBookmarks
        saveAll(all)
        return bookmark
    }

    /// Removes a bookmark matching sessionId + messageIndex.
    func removeBookmark(projectPath: String, sessionId: String, messageIndex: Int) {
        var all = loadAll()
        let key = projectPath.claudeProjectDirName
        guard var projectBookmarks = all[key] else { return }

        projectBookmarks.removeAll { $0.sessionId == sessionId && $0.messageIndex == messageIndex }
        all[key] = projectBookmarks
        saveAll(all)
    }

    /// Checks if a specific point is bookmarked.
    func isBookmarked(projectPath: String, sessionId: String, messageIndex: Int) -> Bool {
        let bookmarks = bookmarks(forProjectPath: projectPath)
        return bookmarks.contains { $0.sessionId == sessionId && $0.messageIndex == messageIndex }
    }

    /// Returns the bookmark label for a specific point, or nil.
    func bookmarkLabel(projectPath: String, sessionId: String, messageIndex: Int) -> String? {
        let bookmarks = bookmarks(forProjectPath: projectPath)
        return bookmarks.first(where: { $0.sessionId == sessionId && $0.messageIndex == messageIndex })?.label
    }

    // MARK: - Private

    private func loadAll() -> [String: [SessionBookmark]] {
        if let cached = cache { return cached }
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: [SessionBookmark]].self, from: data) else {
            cache = [:]
            return [:]
        }
        cache = dict
        return dict
    }

    private func saveAll(_ dict: [String: [SessionBookmark]]) {
        cache = dict
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(dict) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

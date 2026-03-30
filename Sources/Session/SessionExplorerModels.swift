import Foundation

/// A Claude Code session on disk, enriched with parsed metadata.
struct ExplorerSessionInfo {
    let sessionId: String
    let filePath: URL
    let modificationDate: Date
    var messageCount: Int
    let firstUserMessage: String
    var summary: String?
}

/// A single user turn within a session timeline.
struct TimelineEntry {
    let index: Int
    let promptId: String
    let message: String
    let timestamp: Date?
    var isBookmarked: Bool
    var bookmarkLabel: String?
    var actionSummary: String?
}

/// A starred point in a conversation, persisted to disk.
struct SessionBookmark: Codable {
    let sessionId: String
    let messageIndex: Int
    let label: String
    let createdAt: Date
}

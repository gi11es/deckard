import Foundation

/// An agent session on disk, enriched with parsed metadata.
struct ExplorerSessionInfo {
    let agentKind: TabKind
    let sessionId: String
    let filePath: URL
    let modificationDate: Date
    var messageCount: Int
    let firstUserMessage: String
    var savedName: String?
    var isBookmarked: Bool

    var cacheKey: String {
        SessionManager.sessionCacheKey(sessionId: sessionId, kind: agentKind)
    }

    init(agentKind: TabKind = .claude,
         sessionId: String,
         filePath: URL,
         modificationDate: Date,
         messageCount: Int,
         firstUserMessage: String,
         savedName: String?,
         isBookmarked: Bool) {
        self.agentKind = agentKind
        self.sessionId = sessionId
        self.filePath = filePath
        self.modificationDate = modificationDate
        self.messageCount = messageCount
        self.firstUserMessage = firstUserMessage
        self.savedName = savedName
        self.isBookmarked = isBookmarked
    }
}

/// A single user turn within a session timeline.
struct TimelineEntry {
    let index: Int
    let promptId: String
    let message: String
    let timestamp: Date?
}

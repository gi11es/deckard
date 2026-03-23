import Foundation

/// Persisted state for Deckard — saved to ~/Library/Application Support/Deckard/state.json
struct DeckardState: Codable {
    var version: Int = 2
    var selectedTabIndex: Int = 0  // selected project index
    var defaultWorkingDirectory: String?

    // Legacy (v1) — kept for backward compat
    var tabs: [TabState]?
    var claudeTabCounter: Int?
    var terminalTabCounter: Int?
    var masterSessionId: String?

    // v2: project-based
    var projects: [ProjectState]?
}

struct TabState: Codable {
    var id: String
    var sessionId: String?
    var name: String
    var nameOverride: Bool
    var isMaster: Bool
    var isClaude: Bool
    var workingDirectory: String?
}

struct ProjectState: Codable {
    var id: String
    var path: String
    var name: String
    var selectedTabIndex: Int
    var tabs: [ProjectTabState]
}

struct ProjectTabState: Codable {
    var id: String
    var name: String
    var isClaude: Bool
    var sessionId: String?
    var tmuxSessionName: String?
}

/// Manages saving and loading Deckard state.
class SessionManager {
    static let shared = SessionManager()

    private let stateURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let deckardDir = appSupport.appendingPathComponent("Deckard")
        try? FileManager.default.createDirectory(at: deckardDir, withIntermediateDirectories: true)
        return deckardDir.appendingPathComponent("state.json")
    }()

    private var autosaveTimer: Timer?

    func save(_ state: DeckardState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    func load() -> DeckardState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(DeckardState.self, from: data)
    }

    func startAutosave(provider: @escaping () -> DeckardState) {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            self?.save(provider())
        }
    }

    func stopAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
    }

    // MARK: - Session Name Persistence

    private let sessionNamesURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let deckardDir = appSupport.appendingPathComponent("Deckard")
        try? FileManager.default.createDirectory(at: deckardDir, withIntermediateDirectories: true)
        return deckardDir.appendingPathComponent("session-names.json")
    }()

    private var cachedSessionNames: [String: String]?

    func loadSessionNames() -> [String: String] {
        if let cached = cachedSessionNames { return cached }
        guard let data = try? Data(contentsOf: sessionNamesURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            cachedSessionNames = [:]
            return [:]
        }
        cachedSessionNames = dict
        return dict
    }

    func saveSessionName(sessionId: String, name: String) {
        var names = loadSessionNames()
        names[sessionId] = name
        cachedSessionNames = names
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(names) else { return }
        try? data.write(to: sessionNamesURL, options: .atomic)
    }
}

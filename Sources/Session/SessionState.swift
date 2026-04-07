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

    // v3: sidebar folders
    var sidebarFolders: [SidebarFolderState]?
    var sidebarOrder: [SidebarOrderItem]?
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
    var defaultArgs: String?
}

struct ProjectTabState: Codable {
    var id: String
    var name: String
    var isClaude: Bool
    var sessionId: String?
    var tmuxSessionName: String?
}

struct SidebarFolderState: Codable {
    var id: String
    var name: String
    var isCollapsed: Bool
    var projectIds: [String]
}

/// A tagged union for sidebar ordering — either a folder or an ungrouped project.
enum SidebarOrderItem: Codable {
    case folder(String)   // folder id
    case project(String)  // project id

    private enum CodingKeys: String, CodingKey {
        case type, id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folder(let id):
            try container.encode("folder", forKey: .type)
            try container.encode(id, forKey: .id)
        case .project(let id):
            try container.encode("project", forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let id = try container.decode(String.self, forKey: .id)
        switch type {
        case "folder":
            self = .folder(id)
        case "project":
            self = .project(id)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                debugDescription: "Unknown sidebar order item type: \(type)")
        }
    }
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
    private(set) var isDirty = false

    /// Mark state as changed so the next autosave cycle writes to disk.
    func markDirty() {
        isDirty = true
    }

    func save(_ state: DeckardState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        do {
            try data.write(to: stateURL, options: .atomic)
            isDirty = false
        } catch {
            // Write failed — keep isDirty true so the next autosave cycle retries.
        }
    }

    func load() -> DeckardState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(DeckardState.self, from: data)
    }

    func startAutosave(provider: @escaping () -> DeckardState) {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self, self.isDirty else { return }
            self.save(provider())
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

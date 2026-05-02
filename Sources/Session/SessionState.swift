import Foundation

enum TabKind: String, Codable, CaseIterable {
    case claude
    case codex
    case terminal

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .terminal: return "Terminal"
        }
    }

    var isAgent: Bool {
        self == .claude || self == .codex
    }
}

/// Persisted state for Deckard — saved to ~/Library/Application Support/Deckard/state.json
struct DeckardState: Codable {
    var version: Int = 3
    var selectedTabIndex: Int = 0  // selected workspace index
    var defaultWorkingDirectory: String?

    // Legacy (v1) — kept for backward compat
    var tabs: [TabState]?
    var claudeTabCounter: Int?
    var terminalTabCounter: Int?
    var masterSessionId: String?

    // Workspaces (the on-disk key was "projects" in v2; CodingKeys reads both)
    var workspaces: [WorkspaceState]?

    // v3: sidebar groups (was "sidebarFolders" in v2-era state.json)
    var sidebarGroups: [SidebarGroupState]?
    var sidebarOrder: [SidebarOrderItem]?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, selectedTabIndex, defaultWorkingDirectory
        case tabs, claudeTabCounter, terminalTabCounter, masterSessionId
        case workspaces
        case sidebarGroups, sidebarOrder
        // Legacy keys — read on decode, never written.
        case projects        // v2 name for workspaces
        case sidebarFolders  // v2 name for sidebarGroups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        selectedTabIndex = try c.decodeIfPresent(Int.self, forKey: .selectedTabIndex) ?? 0
        defaultWorkingDirectory = try c.decodeIfPresent(String.self, forKey: .defaultWorkingDirectory)
        tabs = try c.decodeIfPresent([TabState].self, forKey: .tabs)
        claudeTabCounter = try c.decodeIfPresent(Int.self, forKey: .claudeTabCounter)
        terminalTabCounter = try c.decodeIfPresent(Int.self, forKey: .terminalTabCounter)
        masterSessionId = try c.decodeIfPresent(String.self, forKey: .masterSessionId)
        workspaces = try c.decodeIfPresent([WorkspaceState].self, forKey: .workspaces)
            ?? c.decodeIfPresent([WorkspaceState].self, forKey: .projects)
        sidebarGroups = try c.decodeIfPresent([SidebarGroupState].self, forKey: .sidebarGroups)
            ?? c.decodeIfPresent([SidebarGroupState].self, forKey: .sidebarFolders)
        sidebarOrder = try c.decodeIfPresent([SidebarOrderItem].self, forKey: .sidebarOrder)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(selectedTabIndex, forKey: .selectedTabIndex)
        try c.encodeIfPresent(defaultWorkingDirectory, forKey: .defaultWorkingDirectory)
        try c.encodeIfPresent(tabs, forKey: .tabs)
        try c.encodeIfPresent(claudeTabCounter, forKey: .claudeTabCounter)
        try c.encodeIfPresent(terminalTabCounter, forKey: .terminalTabCounter)
        try c.encodeIfPresent(masterSessionId, forKey: .masterSessionId)
        try c.encodeIfPresent(workspaces, forKey: .workspaces)
        try c.encodeIfPresent(sidebarGroups, forKey: .sidebarGroups)
        try c.encodeIfPresent(sidebarOrder, forKey: .sidebarOrder)
    }
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

struct WorkspaceState: Codable {
    var id: String
    var path: String
    var name: String
    var selectedTabIndex: Int
    var tabs: [WorkspaceTabState]
    var defaultArgs: String?
    var defaultCodexArgs: String?
}

struct WorkspaceTabState: Codable {
    var id: String
    var name: String
    var kind: TabKind
    var sessionId: String?
    var tmuxSessionName: String?

    var isClaude: Bool {
        get { kind == .claude }
        set { kind = newValue ? .claude : .terminal }
    }

    init(id: String, name: String, kind: TabKind, sessionId: String? = nil, tmuxSessionName: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sessionId = sessionId
        self.tmuxSessionName = tmuxSessionName
    }

    init(id: String, name: String, isClaude: Bool, sessionId: String? = nil, tmuxSessionName: String? = nil) {
        self.init(id: id, name: name, kind: isClaude ? .claude : .terminal, sessionId: sessionId, tmuxSessionName: tmuxSessionName)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, isClaude, sessionId, tmuxSessionName
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(kind == .claude, forKey: .isClaude)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(tmuxSessionName, forKey: .tmuxSessionName)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        tmuxSessionName = try container.decodeIfPresent(String.self, forKey: .tmuxSessionName)
        if let decodedKind = try container.decodeIfPresent(TabKind.self, forKey: .kind) {
            kind = decodedKind
        } else {
            let legacyIsClaude = try container.decodeIfPresent(Bool.self, forKey: .isClaude) ?? false
            kind = legacyIsClaude ? .claude : .terminal
        }
    }
}

struct SidebarGroupState: Codable {
    var id: String
    var name: String
    var isCollapsed: Bool
    var workspaceIds: [String]

    init(id: String, name: String, isCollapsed: Bool, workspaceIds: [String]) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.workspaceIds = workspaceIds
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isCollapsed
        case workspaceIds
        // Legacy key — read on decode, never written.
        case projectIds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isCollapsed = try c.decode(Bool.self, forKey: .isCollapsed)
        workspaceIds = try c.decodeIfPresent([String].self, forKey: .workspaceIds)
            ?? c.decodeIfPresent([String].self, forKey: .projectIds)
            ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isCollapsed, forKey: .isCollapsed)
        try c.encode(workspaceIds, forKey: .workspaceIds)
    }
}

/// A tagged union for sidebar ordering — either a group or an ungrouped workspace.
enum SidebarOrderItem: Codable {
    case group(String)      // group id
    case workspace(String)  // workspace id

    private enum CodingKeys: String, CodingKey {
        case type, id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .group(let id):
            try container.encode("group", forKey: .type)
            try container.encode(id, forKey: .id)
        case .workspace(let id):
            // Keep the on-disk discriminator as "project" — that is what every
            // existing state.json contains. Users on this build still encode it
            // unchanged so a downgrade keeps loading their workspaces.
            try container.encode("project", forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let id = try container.decode(String.self, forKey: .id)
        switch type {
        case "group", "folder":  // "folder" is the v2 legacy discriminator
            self = .group(id)
        case "project":
            self = .workspace(id)
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

    static func sessionCacheKey(sessionId: String, kind: TabKind) -> String {
        kind == .claude ? sessionId : "\(kind.rawValue):\(sessionId)"
    }

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
        saveSessionName(sessionId: sessionId, kind: .claude, name: name)
    }

    func saveSessionName(sessionId: String, kind: TabKind, name: String) {
        var names = loadSessionNames()
        names[Self.sessionCacheKey(sessionId: sessionId, kind: kind)] = name
        cachedSessionNames = names
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(names) else { return }
        try? data.write(to: sessionNamesURL, options: .atomic)
    }
}

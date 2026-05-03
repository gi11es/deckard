import AppKit
import KeyboardShortcuts

/// Format a tooltip with the current shortcut, e.g. "Open Workspace (Cmd+O)"
@MainActor
func shortcutTooltip(_ label: String, for name: KeyboardShortcuts.Name) -> String {
    if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
        return "\(label) (\(shortcut.description))"
    }
    return label
}

// MARK: - Data Models

/// A horizontal tab within a workspace (agent session or terminal).
class TabItem {
    let id: UUID
    var surface: TerminalSurface
    var name: String
    var kind: TabKind
    var sessionId: String?
    var badgeState: BadgeState = .none
    /// Set during restore — suppresses completedUnseen until hook.session-start fires.
    var suppressUnseen: Bool = false

    var isClaude: Bool { kind == .claude }
    var isCodex: Bool { kind == .codex }
    var isTerminal: Bool { kind == .terminal }
    var isAgent: Bool { kind.isAgent }

    var sessionCacheKey: String? {
        guard let sessionId, !sessionId.isEmpty else { return nil }
        return SessionManager.sessionCacheKey(sessionId: sessionId, kind: kind)
    }

    enum BadgeState: String {
        case none
        case idle             // grey - connected but no activity yet
        case thinking
        case waitingForInput
        case needsPermission
        case error
        case codexIdle
        case codexThinking
        case codexError
        case codexCompletedUnseen
        case terminalIdle     // muted teal - terminal at prompt
        case terminalActive   // teal pulsing - terminal foreground process has activity
        case terminalError    // red - terminal process exited with error
        case completedUnseen        // vivid purple - Claude finished while tab unfocused
        case terminalCompletedUnseen // vivid teal - terminal finished while tab unfocused
    }

    enum BadgeShape: String, CaseIterable {
        case circle, square, diamond, triangleUp, triangleDown, cross, xCross, hexagon

        var displayName: String {
            switch self {
            case .circle: return "●"
            case .square: return "■"
            case .diamond: return "♦"
            case .triangleUp: return "▲"
            case .triangleDown: return "▼"
            case .cross: return "✚"
            case .xCross: return "✖"
            case .hexagon: return "⬢"
            }
        }
    }

    init(surface: TerminalSurface, name: String, kind: TabKind) {
        self.id = surface.surfaceId
        self.surface = surface
        self.name = name
        self.kind = kind
    }

    convenience init(surface: TerminalSurface, name: String, isClaude: Bool) {
        self.init(surface: surface, name: name, kind: isClaude ? .claude : .terminal)
    }
}

/// A workspace in the vertical sidebar — contains horizontal tabs.
class WorkspaceItem {
    let id: UUID
    var path: String
    var name: String  // basename of path
    var tabs: [TabItem] = []
    var selectedTabIndex: Int = 0
    var defaultArgs: String?
    var defaultCodexArgs: String?

    init(path: String) {
        self.id = UUID()
        self.path = (path as NSString).resolvingSymlinksInPath
        self.name = (self.path as NSString).lastPathComponent
    }
}

// MARK: - Sidebar Group Model

/// A group in the sidebar that groups workspaces.
class SidebarGroup {
    let id: UUID
    var name: String
    var isCollapsed: Bool
    var workspaceIds: [UUID]  // references to WorkspaceItem.id

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.isCollapsed = false
        self.workspaceIds = []
    }

    init(id: UUID, name: String, isCollapsed: Bool, workspaceIds: [UUID]) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.workspaceIds = workspaceIds
    }
}

/// Ordered sidebar items: either a group or an ungrouped workspace reference.
enum SidebarItem {
    case group(SidebarGroup)
    case workspace(UUID)  // WorkspaceItem.id
}

// MARK: - Default Tab Configuration

struct DefaultTabConfig {
    var entries: [(kind: TabKind, name: String)]

    static var current: DefaultTabConfig {
        let raw = UserDefaults.standard.string(forKey: "defaultTabConfig") ?? "claude, terminal"
        let entries = raw.split(separator: ",").compactMap { item -> (kind: TabKind, name: String)? in
            let trimmed = item.trimmingCharacters(in: .whitespaces).lowercased()
            switch trimmed {
            case "claude": return (kind: .claude, name: "Claude")
            case "codex": return (kind: .codex, name: "Codex")
            case "terminal": return (kind: .terminal, name: "Terminal")
            default: return nil
            }
        }
        return DefaultTabConfig(entries: entries.isEmpty ? [(.claude, "Claude"), (.terminal, "Terminal")] : entries)
    }
}

// MARK: - Window Controller

let deckardWorkspaceDragType = NSPasteboard.PasteboardType("com.deckard.workspace-reorder")
let deckardSidebarDragType = NSPasteboard.PasteboardType("com.deckard.sidebar-drag")
let deckardGroupDragType = NSPasteboard.PasteboardType("com.deckard.group-reorder")


private class CollapsibleSplitView: NSSplitView {
    var sidebarCollapsed = false
    override var dividerThickness: CGFloat {
        sidebarCollapsed ? 0 : super.dividerThickness
    }
    override func drawDivider(in rect: NSRect) {
        if !sidebarCollapsed { super.drawDivider(in: rect) }
    }
}

class DeckardWindowController: NSWindowController, NSSplitViewDelegate {
    var workspaces: [WorkspaceItem] = []
    var selectedWorkspaceIndex: Int = -1

    // Sidebar groups
    var sidebarGroups: [SidebarGroup] = []
    var sidebarOrder: [SidebarItem] = []

    // Theme
    private var colors: ThemeColors { ThemeManager.shared.currentColors }

    // UI
    private let splitView = CollapsibleSplitView()
    private let sidebarView = NSView()
    let sidebarStackView = ReorderableStackView()
    private let rightPane = NSView()
    let tabBar = ReorderableHStackView()  // horizontal tab bar
    var isRebuildingTabBar = false
    var needsTabBarRebuild = false
    /// Saved first responder before a rebuild, used to detect and restore focus theft.
    weak var savedFirstResponder: NSResponder?
    private let terminalContainerView = NSView()
    private var contextTimer: Timer?
    private var processMonitorTimer: Timer?
    var currentTerminalView: NSView?
    /// Opaque overlay shown when a workspace has no tabs, covering any surfaces underneath.
    private var emptyStateView: NSView?

    let sidebarDropZone = SidebarDropZone()
    private let quotaView = QuotaView()
    private let sidebarEffectView = NSVisualEffectView()
    private let sidebarWidth: CGFloat = 210
    private var sidebarInitialized = false
    private var sidebarWidthBeforeCollapse: CGFloat = 210
    /// Recently closed workspaces — stored so reopening the same path restores tabs.
    private var recentlyClosedWorkspaces: [WorkspaceState] = []
    var isRestoring = false
    /// Tabs in the order they were created (for ProcessMonitor PID matching).
    var tabCreationOrder: [UUID] = []

    /// Last activity info per surface, used for tooltips.
    var terminalActivity: [UUID: ProcessMonitor.ActivityInfo] = [:]
    /// Consecutive active poll count per surface — require 2 before showing as active.
    private var terminalActiveStreak: [UUID: Int] = [:]
    private var flagsMonitor: Any?
    /// Window frame captured before sleep/screen sleep. Restored on wake to undo
    /// AppKit's tendency to resize windows when displays disconnect/reconnect
    /// during lock screen or system sleep.
    private var preSleepWindowFrame: NSRect?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Deckard"
        window.minSize = NSSize(width: 600, height: 400)
        window.backgroundColor = ThemeManager.shared.currentColors.background
        window.titlebarAppearsTransparent = true
        window.appearance = ThemeManager.shared.currentColors.isDark
            ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        window.tabbingMode = .disallowed

        super.init(window: window)

        Self.sanitizeAutosavedFrameForTiling()
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }

        setupUI()

        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange(_:)), name: .deckardThemeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(vibrancyDidChange), name: .deckardVibrancyChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(quotaDidChange), name: QuotaMonitor.quotaDidChange, object: nil)
        // Show cached quota data immediately if available
        quotaDidChange()

        let wsNC = NSWorkspace.shared.notificationCenter
        let saveFrame: (Notification) -> Void = { [weak self] _ in
            guard let self, let frame = self.window?.frame else { return }
            self.preSleepWindowFrame = frame
        }
        wsNC.addObserver(forName: NSWorkspace.willSleepNotification,
                         object: nil, queue: .main, using: saveFrame)
        wsNC.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                         object: nil, queue: .main, using: saveFrame)

        let onWake: (Notification) -> Void = { [weak self] _ in
            self?.handleWake()
        }
        wsNC.addObserver(forName: NSWorkspace.didWakeNotification,
                         object: nil, queue: .main, using: onWake)
        wsNC.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                         object: nil, queue: .main, using: onWake)

        restoreOrCreateInitial()

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let mods = revealNumbersModifiers()
            let active = !mods.isEmpty && event.modifierFlags.contains(mods)
            self?.updateShortcutIndicators(commandHeld: active)
            return event
        }

        // If no workspaces after restore, auto-show the workspace picker
        if workspaces.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AppDelegate.shared?.openWorkspacePicker()
            }
        }

        // Start autosave AFTER restore completes — if we autosave during
        // progressive restore, a crash would lose the tabs not yet created.
        // The autosave is started at the end of createTabsProgressively.

        // Delay process monitor start to let surfaces finish initializing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.startProcessMonitor()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor) }
        SessionManager.shared.stopAutosave()
        processMonitorTimer?.invalidate()
    }

    // MARK: - Frame Autosave (with macOS 15 tiling workaround)

    private static let frameAutosaveName = "DeckardMainWindow"

    /// Strip macOS 15 (Sequoia) edge-tiling state from the saved autosave
    /// string. Without this, AppKit restores the window into its previously
    /// tiled state — which on a multi-display setup means the window opens
    /// snapped to a screen edge at full screen-tile size, instead of the
    /// user's preferred frame from before they edge-snapped it.
    ///
    /// Autosave string format:
    ///   "winX winY winW winH screenX screenY screenW screenH [tilingJSON]"
    /// When tiled, the geometry is the *tiled* frame and the JSON contains
    /// the user's preferred frame as `untiledFrame`. We substitute the
    /// untiled frame back as the geometry and drop the JSON.
    private static func sanitizeAutosavedFrameForTiling() {
        let key = "NSWindow Frame \(frameAutosaveName)"
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: key),
              let braceIdx = raw.firstIndex(of: "{") else { return }

        var cleaned = String(raw[..<braceIdx]).trimmingCharacters(in: .whitespaces)
        if let untiled = parseUntiledFrame(in: String(raw[braceIdx...])) {
            let parts = cleaned.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 8 {
                let screen = parts[4..<8].joined(separator: " ")
                cleaned = "\(Int(untiled.origin.x)) \(Int(untiled.origin.y))"
                    + " \(Int(untiled.size.width)) \(Int(untiled.size.height)) \(screen)"
            }
        }
        defaults.set(cleaned, forKey: key)
    }

    private static func parseUntiledFrame(in json: String) -> NSRect? {
        guard let prefix = json.range(of: "\"untiledFrame\":\"") else { return nil }
        let after = json[prefix.upperBound...]
        guard let endQuote = after.firstIndex(of: "\"") else { return nil }
        let rect = NSRectFromString(String(after[..<endQuote]))
        return (rect.width > 0 && rect.height > 0) ? rect : nil
    }

    // MARK: - Sleep / Wake

    private func handleWake() {
        // Two restoration attempts: the first catches resizes that happen during
        // wake; the second catches the slower screen-reconnect path (which can
        // fire seconds after the wake notification when displays come back).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.restoreFrameIfNeeded()
            self?.restoreFirstResponderAfterWake()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.restoreFrameIfNeeded()
        }
    }

    private func restoreFrameIfNeeded() {
        guard let saved = preSleepWindowFrame,
              let window = self.window,
              window.frame != saved else { return }
        // Skip if the saved frame is no longer on any connected screen
        // (e.g. external monitor unplugged while locked) — let macOS handle it.
        let center = NSPoint(x: saved.midX, y: saved.midY)
        let onAScreen = NSScreen.screens.contains { $0.frame.contains(center) }
        guard onAScreen else { return }
        DiagnosticLog.shared.log("sleep",
            "restoring pre-sleep window frame: \(window.frame) -> \(saved)")
        window.setFrame(saved, display: true)
    }

    private func restoreFirstResponderAfterWake() {
        guard let workspace = currentWorkspace else { return }
        let idx = workspace.selectedTabIndex
        guard idx >= 0, idx < workspace.tabs.count else { return }
        let tab = workspace.tabs[idx]
        let fr = window?.firstResponder
        DiagnosticLog.shared.log("sleep",
            "wake recovery: firstResponder=\(type(of: fr)) surfaceId=\(tab.id)")
        window?.makeFirstResponder(tab.surface.view)
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        // Sidebar
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.wantsLayer = true

        // Vibrancy: sidebar blurs through to the desktop wallpaper
        sidebarEffectView.translatesAutoresizingMaskIntoConstraints = false
        sidebarEffectView.material = .sidebar
        sidebarEffectView.blendingMode = .behindWindow
        sidebarEffectView.state = .active
        sidebarView.addSubview(sidebarEffectView, positioned: .below, relativeTo: nil)
        applyVibrancySettings()

        // Drop zone covers the entire sidebar area below the stack
        sidebarDropZone.translatesAutoresizingMaskIntoConstraints = false
        sidebarDropZone.registerForDraggedTypes([deckardWorkspaceDragType, deckardGroupDragType])
        sidebarView.addSubview(sidebarDropZone)

        sidebarStackView.orientation = .vertical
        sidebarStackView.alignment = .leading
        sidebarStackView.spacing = 1
        sidebarStackView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(sidebarStackView)

        // Quota/context usage widget (hidden until data arrives)
        sidebarView.addSubview(quotaView)

        NSLayoutConstraint.activate([
            sidebarEffectView.topAnchor.constraint(equalTo: sidebarView.topAnchor),
            sidebarEffectView.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor),
            sidebarEffectView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarEffectView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),

            sidebarStackView.topAnchor.constraint(equalTo: sidebarView.topAnchor),
            sidebarStackView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarStackView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),

            quotaView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 8),
            quotaView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -8),
            quotaView.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor, constant: -8),

            sidebarDropZone.topAnchor.constraint(equalTo: sidebarStackView.bottomAnchor),
            sidebarDropZone.bottomAnchor.constraint(equalTo: quotaView.topAnchor),
            sidebarDropZone.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarDropZone.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
        ])

        // Right pane: tab bar + terminal
        rightPane.translatesAutoresizingMaskIntoConstraints = false

        tabBar.orientation = .horizontal
        tabBar.alignment = .centerY
        tabBar.spacing = 0
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = colors.tabBarBackground.cgColor
        rightPane.addSubview(tabBar)

        terminalContainerView.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(terminalContainerView)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: rightPane.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 28),

            terminalContainerView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            terminalContainerView.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            terminalContainerView.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            terminalContainerView.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
        ])

        splitView.addArrangedSubview(sidebarView)
        splitView.addArrangedSubview(rightPane)

        // Opaque empty-state overlay — covers all surfaces when a workspace has no tabs.
        let emptyBg = NSView()
        emptyBg.wantsLayer = true
        emptyBg.layer?.backgroundColor = colors.background.cgColor
        emptyBg.translatesAutoresizingMaskIntoConstraints = false
        let welcome = NSTextField(labelWithString: "Press \u{2318}O to open a workspace")
        welcome.font = .systemFont(ofSize: 16, weight: .light)
        welcome.textColor = colors.secondaryText
        welcome.alignment = .center
        welcome.translatesAutoresizingMaskIntoConstraints = false
        emptyBg.addSubview(welcome)
        terminalContainerView.addSubview(emptyBg)
        NSLayoutConstraint.activate([
            emptyBg.topAnchor.constraint(equalTo: terminalContainerView.topAnchor),
            emptyBg.bottomAnchor.constraint(equalTo: terminalContainerView.bottomAnchor),
            emptyBg.leadingAnchor.constraint(equalTo: terminalContainerView.leadingAnchor),
            emptyBg.trailingAnchor.constraint(equalTo: terminalContainerView.trailingAnchor),
            welcome.centerXAnchor.constraint(equalTo: emptyBg.centerXAnchor),
            welcome.centerYAnchor.constraint(equalTo: emptyBg.centerYAnchor),
        ])
        self.emptyStateView = emptyBg

        NSLayoutConstraint.activate([
        ])

        sidebarView.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        DispatchQueue.main.async { [self] in
            if UserDefaults.standard.bool(forKey: "sidebarCollapsed") {
                splitView.sidebarCollapsed = true
                sidebarView.isHidden = true
                splitView.adjustSubviews()
            } else {
                let saved = CGFloat(UserDefaults.standard.double(forKey: "sidebarWidth"))
                splitView.setPosition(saved > 80 ? saved : sidebarWidth, ofDividerAt: 0)
            }
            sidebarInitialized = true
        }

        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { 80 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { splitView.bounds.width * 0.5 }
    func splitView(_ splitView: NSSplitView, canCollapseSubview s: NSView) -> Bool { s === sidebarView }

    func splitView(_ splitView: NSSplitView, shouldCollapseSubview s: NSView, forDoubleClickOnDividerAt i: Int) -> Bool {
        s === sidebarView
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard sidebarInitialized, !splitView.isSubviewCollapsed(sidebarView), sidebarView.frame.width > 0 else { return }
        UserDefaults.standard.set(Double(sidebarView.frame.width), forKey: "sidebarWidth")
    }

    // MARK: - Sidebar Toggle

    var isSidebarCollapsed: Bool {
        splitView.sidebarCollapsed
    }

    @objc func toggleSidebar() {
        if splitView.sidebarCollapsed {
            splitView.sidebarCollapsed = false
            sidebarView.isHidden = false
            splitView.adjustSubviews()
            let target = sidebarWidthBeforeCollapse > 80 ? sidebarWidthBeforeCollapse : sidebarWidth
            splitView.setPosition(target, ofDividerAt: 0)
        } else {
            sidebarWidthBeforeCollapse = sidebarView.frame.width
            splitView.sidebarCollapsed = true
            sidebarView.isHidden = true
            splitView.adjustSubviews()
        }
        splitView.needsDisplay = true
        UserDefaults.standard.set(splitView.sidebarCollapsed, forKey: "sidebarCollapsed")
        // Update the View > Toggle Sidebar menu item title
        let newTitle = splitView.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar"
        if let mainMenu = NSApp.mainMenu {
            for item in mainMenu.items {
                if item.submenu?.title == "View" {
                    item.submenu?.items.first?.title = newTitle
                    break
                }
            }
        }
    }

    // MARK: - Workspace Management

    func openWorkspacePaths() -> [String] {
        return workspaces.map { $0.path }
    }

    func openWorkspace(path: String) {
        let workspace = WorkspaceItem(path: path)

        // Check if we have a recently closed snapshot — restore tabs from it
        // Use workspace.path (symlinks resolved) so symlinked paths match canonical ones.
        if let snapshot = recentlyClosedWorkspaces.first(where: { $0.path == workspace.path }) {
            recentlyClosedWorkspaces.removeAll { $0.path == workspace.path }
            workspace.name = snapshot.name
            workspace.defaultArgs = snapshot.defaultArgs
            workspace.defaultCodexArgs = snapshot.defaultCodexArgs
            for ts in snapshot.tabs {
                createTabInWorkspace(workspace, kind: ts.kind, name: ts.name,
                                   sessionIdToResume: ts.kind.isAgent ? ts.sessionId : nil,
                                   tmuxSessionToResume: ts.tmuxSessionName)
            }
            workspace.selectedTabIndex = min(snapshot.selectedTabIndex, workspace.tabs.count - 1)
        }

        // If no tabs restored, create defaults
        if workspace.tabs.isEmpty {
            let config = DefaultTabConfig.current
            for entry in config.entries {
                createTabInWorkspace(workspace, kind: entry.kind)
            }
        }

        workspaces.append(workspace)
        sidebarOrder.append(.workspace(workspace.id))
        rebuildSidebar()
        selectWorkspace(at: workspaces.count - 1)
        if !isRestoring { saveState() }
    }

    func closeCurrentWorkspace() {
        guard selectedWorkspaceIndex >= 0, selectedWorkspaceIndex < workspaces.count else { return }
        closeWorkspace(at: selectedWorkspaceIndex)
    }

    func exploreCurrentWorkspaceSessions() {
        guard selectedWorkspaceIndex >= 0, selectedWorkspaceIndex < workspaces.count else { return }
        let workspace = workspaces[selectedWorkspaceIndex]
        let fakeMenuItem = NSMenuItem()
        fakeMenuItem.representedObject = workspace
        exploreSessionsMenuAction(fakeMenuItem)
    }

    func moveCurrentWorkspaceOutOfGroup() {
        guard selectedWorkspaceIndex >= 0, selectedWorkspaceIndex < workspaces.count else { return }
        let workspace = workspaces[selectedWorkspaceIndex]
        moveWorkspaceOutOfGroup(workspaceId: workspace.id)
    }

    func closeWorkspace(at index: Int) {
        guard index >= 0, index < workspaces.count else { return }
        let workspace = workspaces[index]

        // Save workspace state for potential restoration
        let snapshot = WorkspaceState(
            id: workspace.id.uuidString,
            path: workspace.path,
            name: workspace.name,
            selectedTabIndex: workspace.selectedTabIndex,
            tabs: workspace.tabs.map { tab in
                WorkspaceTabState(id: tab.id.uuidString, name: tab.name,
                                kind: tab.kind, sessionId: tab.sessionId,
                                tmuxSessionName: tab.surface.tmuxSessionName)
            },
            defaultArgs: workspace.defaultArgs,
            defaultCodexArgs: workspace.defaultCodexArgs
        )
        recentlyClosedWorkspaces.removeAll { $0.path == workspace.path }
        recentlyClosedWorkspaces.append(snapshot)

        // Persist session names for agent tabs so they survive app restarts
        for tab in workspace.tabs where tab.isAgent {
            if let sid = tab.sessionId, !sid.isEmpty {
                SessionManager.shared.saveSessionName(sessionId: sid, kind: tab.kind, name: tab.name)
            }
        }

        // Detach terminal tabs so their tmux sessions survive for re-open;
        // terminate agent tabs (they use their own resume mechanism).
        let closedIds = Set(workspace.tabs.map { $0.id })
        tabCreationOrder.removeAll { closedIds.contains($0) }
        for tab in workspace.tabs {
            if tab.isTerminal && tab.surface.tmuxSessionName != nil {
                tab.surface.detach()
            } else {
                tab.surface.terminate()
            }
        }

        workspaces.remove(at: index)
        removeSidebarReference(workspaceId: workspace.id)
        rebuildSidebar()

        if workspaces.isEmpty {
            selectedWorkspaceIndex = -1
            currentTerminalView?.removeFromSuperview()
            currentTerminalView = nil
            rebuildTabBar()
        } else if let next = nextVisibleWorkspaceIndex(near: index) {
            selectWorkspace(at: next, autoExpandGroup: false)
        } else {
            // All remaining workspaces are inside collapsed groups — show empty state.
            selectedWorkspaceIndex = -1
            currentTerminalView?.removeFromSuperview()
            currentTerminalView = nil
            rebuildTabBar()
            rebuildSidebar()
            showEmptyState()
        }
        saveState()
    }

    /// Returns the index of the nearest workspace that is visible in the sidebar
    /// (i.e. top-level or inside a non-collapsed group), or nil if none.
    private func nextVisibleWorkspaceIndex(near index: Int) -> Int? {
        let collapsedWorkspaceIds = Set(sidebarGroups.filter(\.isCollapsed).flatMap(\.workspaceIds))
        let clamped = min(index, workspaces.count - 1)
        // Search outward from `clamped`: check clamped, clamped-1, clamped+1, ...
        var lo = clamped, hi = clamped + 1
        while lo >= 0 || hi < workspaces.count {
            if lo >= 0, !collapsedWorkspaceIds.contains(workspaces[lo].id) { return lo }
            if hi < workspaces.count, !collapsedWorkspaceIds.contains(workspaces[hi].id) { return hi }
            lo -= 1; hi += 1
        }
        return nil
    }

    func selectWorkspace(at index: Int, autoExpandGroup: Bool = true) {
        guard index >= 0, index < workspaces.count else { return }
        selectedWorkspaceIndex = index

        let workspace = workspaces[index]

        // Auto-expand group if the selected workspace is inside a collapsed one
        if autoExpandGroup {
            for group in sidebarGroups where group.isCollapsed && group.workspaceIds.contains(workspace.id) {
                group.isCollapsed = false
                rebuildSidebar()
            }
        }

        rebuildTabBar()

        if workspace.tabs.isEmpty {
            currentTerminalView = nil
            showEmptyState()
        } else {
            // Always clamp for safe array access, even during restore
            let safeIdx = max(0, min(workspace.selectedTabIndex, workspace.tabs.count - 1))
            clearUnseenIfNeeded(workspace.tabs[safeIdx])
            showTab(workspace.tabs[safeIdx])
        }

        // Show group path in title bar
        let home = NSHomeDirectory()
        let displayPath = workspace.path.hasPrefix(home)
            ? "~" + workspace.path.dropFirst(home.count)
            : workspace.path
        #if DEBUG
        window?.title = "\(displayPath) [DEV]"
        #else
        window?.title = displayPath
        #endif

        updateSidebarSelection()
    }

    // MARK: - Tab Management (within a workspace)

    private func initialBadgeState(for kind: TabKind) -> TabItem.BadgeState {
        switch kind {
        case .claude:
            return .idle
        case .codex:
            return .codexIdle
        case .terminal:
            return .terminalIdle
        }
    }

    func createTabInWorkspace(_ workspace: WorkspaceItem, isClaude: Bool, name: String? = nil, sessionIdToResume: String? = nil, forkSession: Bool = false, tmuxSessionToResume: String? = nil, extraArgs: String? = nil) {
        createTabInWorkspace(workspace, kind: isClaude ? .claude : .terminal, name: name, sessionIdToResume: sessionIdToResume, forkSession: forkSession, tmuxSessionToResume: tmuxSessionToResume, extraArgs: extraArgs)
    }

    func createTabInWorkspace(_ workspace: WorkspaceItem, kind: TabKind, name: String? = nil, sessionIdToResume: String? = nil, forkSession: Bool = false, tmuxSessionToResume: String? = nil, extraArgs: String? = nil) {
        let surface = TerminalSurface()
        let tabName: String
        if let name = name {
            tabName = name
        } else {
            let base = kind.displayName
            // Find the highest existing number for this tab type to avoid duplicates
            let prefix = "\(base) #"
            let maxNum = workspace.tabs
                .filter { $0.kind == kind }
                .compactMap { tab -> Int? in
                    guard tab.name.hasPrefix(prefix) else { return nil }
                    return Int(tab.name.dropFirst(prefix.count))
                }
                .max() ?? 0
            tabName = "\(base) #\(maxNum + 1)"
        }
        let tab = TabItem(surface: surface, name: tabName, kind: kind)
        surface.tabId = tab.id
        tab.badgeState = initialBadgeState(for: kind)
        if kind == .claude && isRestoring {
            tab.suppressUnseen = true
        }
        var envVars: [String: String] = [:]
        if kind.isAgent {
            tab.sessionId = forkSession ? nil : sessionIdToResume
            envVars["DECKARD_SESSION_TYPE"] = kind.rawValue
        }

        let initialInput: String?
        if kind == .claude {
            let resolvedArgs = extraArgs ?? workspace.defaultArgs ?? UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
            let extraArgsSuffix = resolvedArgs.isEmpty ? "" : " \(resolvedArgs)"
            var claudeArgs = extraArgsSuffix
            if let sessionIdToResume {
                let encoded = workspace.path.claudeProjectDirName
                let jsonlPath = NSHomeDirectory() + "/.claude/projects/\(encoded)/\(sessionIdToResume).jsonl"
                if FileManager.default.fileExists(atPath: jsonlPath) {
                    let forkFlag = forkSession ? " --fork-session" : ""
                    claudeArgs = " --resume \(sessionIdToResume)\(forkFlag)\(extraArgsSuffix)"
                } else {
                    tab.sessionId = nil
                }
            }
            // Hooks are pre-configured in ~/.claude/settings.local.json by
            // DeckardHooksInstaller — no wrapper needed, just call claude directly.
            // clear hides the echoed command; exec replaces the shell.
            initialInput = "clear && exec claude\(claudeArgs)\n"
        } else if kind == .codex {
            let resolvedArgs = extraArgs ?? workspace.defaultCodexArgs ?? UserDefaults.standard.string(forKey: "codexExtraArgs") ?? ""
            let codexOptions = resolvedArgs.isEmpty ? "" : " \(resolvedArgs)"
            var codexArgs = ""
            if let sessionIdToResume {
                if forkSession {
                    codexArgs = "\(codexOptions) fork \(sessionIdToResume)"
                } else if ContextMonitor.shared.codexSessionFileURL(sessionId: sessionIdToResume) != nil {
                    codexArgs = "\(codexOptions) resume \(sessionIdToResume)"
                } else {
                    tab.sessionId = nil
                }
            } else {
                codexArgs = codexOptions
            }
            initialInput = "clear && exec codex\(codexArgs)\n"
        } else {
            initialInput = nil
        }

        DiagnosticLog.shared.log("surface", "createTab: \(kind.rawValue) surfaceId=\(surface.surfaceId)")

        surface.startShell(
            workingDirectory: workspace.path,
            envVars: envVars,
            initialInput: initialInput,
            tmuxSession: tmuxSessionToResume
        )

        surface.onProcessExit = { [weak self] exitedSurface in
            DispatchQueue.main.async {
                self?.handleSurfaceClosedById(exitedSurface.surfaceId)
            }
        }

        workspace.tabs.append(tab)
        tabCreationOrder.append(tab.id)

        if kind == .codex && (tab.sessionId == nil || forkSession) {
            scheduleCodexSessionDiscovery(forSurfaceId: tab.id, workspacePath: workspace.path)
        }
    }

    private func scheduleCodexSessionDiscovery(forSurfaceId surfaceId: UUID, workspacePath: String) {
        for delay in [1.0, 3.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      let tab = self.tabForSurfaceId(surfaceId.uuidString),
                      tab.kind == .codex,
                      tab.sessionId == nil else { return }

                guard let processId = ProcessMonitor.shared.shellPid(forSurface: surfaceId),
                      let session = ContextMonitor.shared.codexSessionInfo(
                        openedByProcessId: processId,
                        workspacePath: workspacePath
                ) else { return }

                self.updateSessionId(forSurfaceId: surfaceId.uuidString, sessionId: session.sessionId)
            }
        }
    }

    /// Guards against rapid duplicate tab creation from key repeat.
    var isCreatingTab = false

    func addTabToCurrentWorkspace(isClaude: Bool) {
        addTabToCurrentWorkspace(kind: isClaude ? .claude : .terminal)
    }

    func addTabToCurrentWorkspace(kind: TabKind) {
        guard !isCreatingTab else { return }
        isCreatingTab = true

        guard selectedWorkspaceIndex >= 0, selectedWorkspaceIndex < workspaces.count else {
            isCreatingTab = false
            return
        }
        let workspace = workspaces[selectedWorkspaceIndex]

        if kind == .claude && UserDefaults.standard.bool(forKey: "promptForSessionArgs") {
            promptForClaudeArgs(for: workspace) { [weak self] args in
                guard let self else { return }
                guard let args else {
                    // User cancelled
                    self.isCreatingTab = false
                    return
                }
                guard self.workspaces.contains(where: { $0 === workspace }) else {
                    self.isCreatingTab = false
                    return
                }
                self.createTabInWorkspace(workspace, kind: .claude, extraArgs: args)
                self.finalizeTabCreation(in: workspace)
            }
        } else if kind == .codex && UserDefaults.standard.bool(forKey: "promptForCodexSessionArgs") {
            promptForCodexArgs(for: workspace) { [weak self] args in
                guard let self else { return }
                guard let args else {
                    self.isCreatingTab = false
                    return
                }
                guard self.workspaces.contains(where: { $0 === workspace }) else {
                    self.isCreatingTab = false
                    return
                }
                self.createTabInWorkspace(workspace, kind: .codex, extraArgs: args)
                self.finalizeTabCreation(in: workspace)
            }
        } else {
            createTabInWorkspace(workspace, kind: kind)
            finalizeTabCreation(in: workspace)
        }
    }

    private func finalizeTabCreation(in workspace: WorkspaceItem) {
        workspace.selectedTabIndex = workspace.tabs.count - 1
        rebuildTabBar()
        rebuildSidebar()
        showTab(workspace.tabs[workspace.selectedTabIndex])
        saveState()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isCreatingTab = false
        }
    }

    private func promptForClaudeArgs(for workspace: WorkspaceItem, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Claude Code Arguments"
        alert.informativeText = "Arguments passed to this session:"
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let field = ClaudeArgsField(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        field.stringValue = workspace.defaultArgs ?? UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
        alert.accessoryView = field

        guard let window else {
            completion(nil)
            return
        }

        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                completion(field.stringValue)
            } else {
                completion(nil)
            }
        }
    }

    private func promptForCodexArgs(for workspace: WorkspaceItem, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Codex Arguments"
        alert.informativeText = "Arguments passed to this session:"
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let field = ClaudeArgsField(
            frame: NSRect(x: 0, y: 0, width: 400, height: 60),
            flagSource: .codex
        )
        field.stringValue = workspace.defaultCodexArgs ?? UserDefaults.standard.string(forKey: "codexExtraArgs") ?? ""
        alert.accessoryView = field

        guard let window else {
            completion(nil)
            return
        }

        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                completion(field.stringValue)
            } else {
                completion(nil)
            }
        }
    }

    func closeCurrentTab() {
        guard let workspace = currentWorkspace else { return }
        let idx = workspace.selectedTabIndex
        guard idx >= 0, idx < workspace.tabs.count else { return }

        let tab = workspace.tabs[idx]
        tab.surface.terminate()
        tabCreationOrder.removeAll { $0 == tab.id }

        workspace.tabs.remove(at: idx)

        if workspace.tabs.isEmpty {
            // Keep the workspace in the sidebar with just the "+" button
            currentTerminalView = nil
            showEmptyState()
            rebuildTabBar()
            rebuildSidebar()
        } else {
            workspace.selectedTabIndex = min(idx, workspace.tabs.count - 1)
            rebuildTabBar()
            rebuildSidebar()
            clearUnseenIfNeeded(workspace.tabs[workspace.selectedTabIndex])
            showTab(workspace.tabs[workspace.selectedTabIndex])
        }
        saveState()
    }

    /// If the tab is in a completedUnseen state, revert to the normal idle state.
    func clearUnseenIfNeeded(_ tab: TabItem) {
        switch tab.badgeState {
        case .completedUnseen:
            tab.badgeState = .waitingForInput
            rebuildSidebar()
            rebuildTabBar()
        case .codexCompletedUnseen:
            tab.badgeState = .codexIdle
            rebuildSidebar()
            rebuildTabBar()
        case .terminalCompletedUnseen:
            tab.badgeState = .terminalIdle
            rebuildSidebar()
            rebuildTabBar()
        default:
            break
        }
    }

    func selectTabInWorkspace(at tabIndex: Int) {
        guard let workspace = currentWorkspace else { return }
        guard tabIndex >= 0, tabIndex < workspace.tabs.count else { return }
        workspace.selectedTabIndex = tabIndex
        clearUnseenIfNeeded(workspace.tabs[tabIndex])
        rebuildTabBar()
        showTab(workspace.tabs[tabIndex])
    }

    /// Switch to a tab without rebuilding the tab bar.
    /// Called from HorizontalTabView.mouseDown so the terminal switch
    /// is not lost if an async rebuild destroys the view before mouseUp.
    func switchToTab(at tabIndex: Int) {
        guard let workspace = currentWorkspace else { return }
        guard tabIndex >= 0, tabIndex < workspace.tabs.count else { return }
        guard tabIndex != workspace.selectedTabIndex else { return }
        workspace.selectedTabIndex = tabIndex
        clearUnseenIfNeeded(workspace.tabs[tabIndex])
        showTab(workspace.tabs[tabIndex])
    }

    func selectNextTab() {
        guard let workspace = currentWorkspace, !workspace.tabs.isEmpty else { return }
        selectTabInWorkspace(at: (workspace.selectedTabIndex + 1) % workspace.tabs.count)
    }

    func selectPrevTab() {
        guard let workspace = currentWorkspace, !workspace.tabs.isEmpty else { return }
        selectTabInWorkspace(at: (workspace.selectedTabIndex - 1 + workspace.tabs.count) % workspace.tabs.count)
    }

    var currentWorkspace: WorkspaceItem? {
        guard selectedWorkspaceIndex >= 0, selectedWorkspaceIndex < workspaces.count else { return nil }
        return workspaces[selectedWorkspaceIndex]
    }

    func showTab(_ tab: TabItem) {
        hideEmptyState()

        let view = tab.surface.view

        // Remove the previous surface view from the hierarchy.
        // Only one terminal view is in the container at a time.
        if let prev = currentTerminalView, prev !== view {
            prev.removeFromSuperview()
        }

        // Add the new surface view (or re-add if it was previously removed).
        if view.superview !== terminalContainerView {
            view.translatesAutoresizingMaskIntoConstraints = false
            terminalContainerView.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: terminalContainerView.topAnchor),
                view.bottomAnchor.constraint(equalTo: terminalContainerView.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: terminalContainerView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: terminalContainerView.trailingAnchor),
            ])
            terminalContainerView.layoutSubtreeIfNeeded()
        }
        currentTerminalView = view

        // Exit tmux copy mode if active, so arrow keys go to the shell
        tab.surface.exitTmuxCopyMode()

        let ok = window?.makeFirstResponder(view) ?? false
        DiagnosticLog.shared.log("focus",
            "showTab: makeFirstResponder=\(ok) surfaceId=\(tab.surface.surfaceId)" +
            " frame=\(view.frame)")
        refreshContextBar(for: tab)
    }

    /// Show the empty-state overlay (workspace has no tabs).
    func showEmptyState() {
        currentTerminalView?.removeFromSuperview()
        emptyStateView?.isHidden = false
        contextTimer?.invalidate()
        contextTimer = nil
        quotaView.clear()
    }

    /// Hide the empty-state overlay (active tab is being shown).
    private func hideEmptyState() {
        emptyStateView?.isHidden = true
    }



    private func refreshContextBar(for tab: TabItem) {
        contextTimer?.invalidate()
        contextTimer = nil

        switch tab.kind {
        case .claude:
            updateContextUsage(for: tab)
            contextTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.updateContextUsage(for: tab)
            }
        case .codex:
            updateCodexUsage(for: tab)
            contextTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.updateCodexUsage(for: tab)
            }
        case .terminal:
            quotaView.clear()
        }
    }

    private func updateContextUsage(for tab: TabItem) {
        guard let sessionId = tab.sessionId,
              let workspace = currentWorkspace else {
            DiagnosticLog.shared.log("context",
                "updateContextUsage: skipped — sessionId=\(tab.sessionId ?? "nil") workspace=\(currentWorkspace != nil)")
            quotaView.updateContext(usage: nil, tabName: nil)
            return
        }

        let tabName = tab.name
        let tabId = tab.id
        let workspacePath = workspace.path
        let allPaths = workspaces.map { $0.path }
        DispatchQueue.global(qos: .utility).async {
            let usage = ContextMonitor.shared.getUsage(sessionId: sessionId, workspacePath: workspacePath)
            let rate = QuotaMonitor.shared.computeTokenRate(workspacePaths: allPaths)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Only update if this tab is still the active one
                guard let workspace = self.currentWorkspace,
                      let activeTab = workspace.tabs[safe: workspace.selectedTabIndex],
                      activeTab.id == tabId else {
                    DiagnosticLog.shared.log("context",
                        "updateContextUsage: stale callback for \(tabName), ignoring")
                    return
                }
                self.quotaView.updateContext(usage: usage, tabName: tabName)
                self.quotaView.update(
                    snapshot: QuotaMonitor.shared.latest,
                    tokenRate: rate,
                    sparklineData: QuotaMonitor.shared.sparklineData,
                    alwaysShowRate: true)
            }
        }
    }

    private func updateCodexUsage(for tab: TabItem) {
        guard let workspace = currentWorkspace else {
            quotaView.clear()
            return
        }

        let tabName = tab.name
        let tabId = tab.id
        let initialSessionId = tab.sessionId
        let workspacePath = workspace.path
        DispatchQueue.global(qos: .utility).async {
            var sessionId = initialSessionId
            if sessionId == nil,
               let processId = ProcessMonitor.shared.shellPid(forSurface: tabId) {
                sessionId = ContextMonitor.shared.codexSessionInfo(
                    openedByProcessId: processId,
                    workspacePath: workspacePath
                )?.sessionId
            }
            let usage = ContextMonitor.shared.getCodexUsage(sessionId: sessionId)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard let workspace = self.currentWorkspace,
                      let activeTab = workspace.tabs[safe: workspace.selectedTabIndex],
                      activeTab.id == tabId else {
                    DiagnosticLog.shared.log("context",
                        "updateCodexUsage: stale callback for \(tabName), ignoring")
                    return
                }

                if let sessionId, activeTab.sessionId != sessionId {
                    self.updateSessionId(forSurfaceId: tabId.uuidString, sessionId: sessionId)
                    return
                }

                guard let usage else {
                    self.quotaView.clear()
                    return
                }

                self.quotaView.updateContext(usage: usage.context, tabName: tabName)
                self.quotaView.update(
                    snapshot: usage.quotaSnapshot,
                    tokenRate: usage.tokenRate,
                    sparklineData: usage.sparklineData)
            }
        }
    }

    // MARK: - Process Monitor

    private struct CodexBadgePollTarget {
        let surfaceId: UUID
        let workspacePath: String
        let sessionId: String?
        let processId: pid_t?
    }

    private struct CodexBadgePollResult {
        let states: [UUID: ContextMonitor.CodexActivityInfo]
        let discoveredSessionIds: [UUID: String]
    }

    private func startProcessMonitor() {
        processMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Build tab infos — order doesn't matter since PID matching
            // is done via control socket registration, not sorted order.
            var tabInfos: [ProcessMonitor.TabInfo] = []
            var codexTargets: [CodexBadgePollTarget] = []
            for workspace in self.workspaces {
                for tab in workspace.tabs {
                    tabInfos.append(ProcessMonitor.TabInfo(
                        surfaceId: tab.id, kind: tab.kind,
                        name: tab.name, workspacePath: workspace.path))
                    if tab.kind == .codex {
                        codexTargets.append(CodexBadgePollTarget(
                            surfaceId: tab.id,
                            workspacePath: workspace.path,
                            sessionId: tab.sessionId,
                            processId: ProcessMonitor.shared.shellPid(forSurface: tab.id)))
                    }
                }
            }
            DispatchQueue.global(qos: .utility).async {
                let states = ProcessMonitor.shared.poll(tabs: tabInfos)
                let codexResult = self.pollCodexBadgeStates(for: codexTargets)
                DispatchQueue.main.async {
                    self.applyCodexSessionDiscoveries(codexResult.discoveredSessionIds)
                    self.applyTerminalBadgeStates(states)
                    self.applyCodexBadgeStates(codexResult.states)
                }
            }
        }
    }

    private func pollCodexBadgeStates(for targets: [CodexBadgePollTarget]) -> CodexBadgePollResult {
        var states: [UUID: ContextMonitor.CodexActivityInfo] = [:]
        var discoveredSessionIds: [UUID: String] = [:]

        for target in targets {
            var sessionId = target.sessionId
            if sessionId == nil,
               let processId = target.processId,
               let session = ContextMonitor.shared.codexSessionInfo(
                    openedByProcessId: processId,
                    workspacePath: target.workspacePath
               ),
               !discoveredSessionIds.values.contains(session.sessionId) {
                sessionId = session.sessionId
                discoveredSessionIds[target.surfaceId] = session.sessionId
            }

            guard let sessionId,
                  let state = ContextMonitor.shared.codexActivityInfo(sessionId: sessionId) else { continue }
            states[target.surfaceId] = state
        }

        return CodexBadgePollResult(states: states, discoveredSessionIds: discoveredSessionIds)
    }

    private func applyCodexSessionDiscoveries(_ discoveredSessionIds: [UUID: String]) {
        guard !discoveredSessionIds.isEmpty else { return }
        for (surfaceId, sessionId) in discoveredSessionIds {
            updateSessionId(forSurfaceId: surfaceId.uuidString, sessionId: sessionId)
        }
    }

    private func applyCodexBadgeStates(_ states: [UUID: ContextMonitor.CodexActivityInfo]) {
        var changed = false
        for workspace in workspaces {
            for tab in workspace.tabs where tab.kind == .codex {
                guard let state = states[tab.id] else { continue }

                let newBadge: TabItem.BadgeState
                if state.isBusy {
                    newBadge = .codexThinking
                } else if state.isError {
                    newBadge = .codexError
                } else if tab.badgeState == .codexThinking {
                    let visible = isTabVisible(tab.id.uuidString)
                    newBadge = visible ? .codexIdle : .codexCompletedUnseen
                } else if tab.badgeState == .codexCompletedUnseen {
                    newBadge = .codexCompletedUnseen
                } else {
                    newBadge = .codexIdle
                }

                if tab.badgeState != newBadge {
                    DiagnosticLog.shared.log("badge",
                        "codex badge: workspace=\(workspace.path) tab=\"\(tab.name)\" busy=\(state.isBusy) error=\(state.isError) -> \(newBadge)")
                    tab.badgeState = newBadge
                    changed = true
                }
            }
        }
        if changed {
            rebuildSidebar()
            rebuildTabBar()
        }
    }

    private func applyTerminalBadgeStates(_ states: [UUID: ProcessMonitor.ActivityInfo]) {
        var changed = false
        for workspace in workspaces {
            for tab in workspace.tabs where tab.isTerminal {
                let activity = states[tab.id] ?? ProcessMonitor.ActivityInfo()

                // Require 2 consecutive active polls to transition to terminalActive.
                // This filters single-poll spikes from process changes or scheduler noise.
                let streak = (terminalActiveStreak[tab.id] ?? 0)
                let newStreak = activity.isActive ? streak + 1 : 0
                terminalActiveStreak[tab.id] = newStreak
                let confirmedActive = newStreak >= 2

                let newBadge: TabItem.BadgeState
                if confirmedActive {
                    newBadge = .terminalActive
                } else if tab.badgeState == .terminalActive {
                    // Transitioning from active to idle — check if tab is currently visible
                    let visible = isTabVisible(tab.id.uuidString)
                    newBadge = visible ? .terminalIdle : .terminalCompletedUnseen
                } else if tab.badgeState == .terminalCompletedUnseen {
                    // Stay unseen until tab is visited (cleared elsewhere)
                    newBadge = .terminalCompletedUnseen
                } else {
                    newBadge = .terminalIdle
                }

                terminalActivity[tab.id] = activity
                if tab.badgeState != newBadge {
                    if newBadge == .terminalActive {
                        DiagnosticLog.shared.log("processmon",
                            "badge -> terminalActive: workspace=\(workspace.path) tab=\"\(tab.name)\"")
                    }
                    tab.badgeState = newBadge
                    changed = true
                }
            }
        }
        if changed {
            rebuildSidebar()
            rebuildTabBar()
        }
    }

    func setTitle(_ title: String, forSurfaceId surfaceId: UUID) {
        for workspace in workspaces {
            for tab in workspace.tabs where tab.surface.surfaceId == surfaceId {
                guard tab.surface.title != title else { return }
                tab.surface.title = title
                return
            }
        }
    }

    func handleSurfaceClosedById(_ surfaceId: UUID) {
        for (pi, workspace) in workspaces.enumerated() {
            if let ti = workspace.tabs.firstIndex(where: { $0.id == surfaceId }) {
                let tab = workspace.tabs[ti]

                // Terminal tabs: restart shell instead of removing the tab.
                // Reconnects to the tmux session if it still exists, otherwise
                // starts a fresh shell. Rate-limited to prevent crash loops.
                if tab.isTerminal && tab.surface.canRestart {
                    DiagnosticLog.shared.log("surface",
                        "restarting shell for surfaceId=\(surfaceId)")
                    tab.surface.restartShell(workingDirectory: workspace.path)
                    return
                }

                tab.surface.terminate()
                tabCreationOrder.removeAll { $0 == tab.id }

                workspace.tabs.remove(at: ti)

                if workspace.tabs.isEmpty && pi == selectedWorkspaceIndex {
                    currentTerminalView?.removeFromSuperview()
                    currentTerminalView = nil
                    rebuildTabBar()
                    rebuildSidebar()
                } else if workspace.tabs.isEmpty {
                    rebuildSidebar()
                } else if pi == selectedWorkspaceIndex {
                    workspace.selectedTabIndex = min(workspace.selectedTabIndex, workspace.tabs.count - 1)
                    rebuildTabBar()
                    rebuildSidebar()
                    showTab(workspace.tabs[workspace.selectedTabIndex])
                } else {
                    rebuildSidebar()
                }
                saveState()
                return
            }
        }
    }

    // MARK: - Lookup helpers

    func tabForSurfaceId(_ surfaceIdStr: String) -> TabItem? {
        guard let surfaceId = UUID(uuidString: surfaceIdStr) else { return nil }
        for workspace in workspaces {
            if let tab = workspace.tabs.first(where: { $0.id == surfaceId }) {
                return tab
            }
        }
        return nil
    }

    func revealClaudeTab(surfaceId: String) {
        // No-op: all tabs are immediately visible (macos-hush-login
        // suppresses "Last login", so no masking needed).
    }

    func isTabFocused(_ surfaceIdStr: String) -> Bool {
        guard let surfaceId = UUID(uuidString: surfaceIdStr) else { return false }
        guard let workspace = currentWorkspace else { return false }
        let idx = workspace.selectedTabIndex
        guard idx >= 0, idx < workspace.tabs.count else { return false }
        return workspace.tabs[idx].id == surfaceId && (window?.isKeyWindow ?? false)
    }

    /// Whether the tab is currently visible (selected tab in the active workspace),
    /// regardless of whether the Deckard window is in the foreground.
    func isTabVisible(_ surfaceIdStr: String) -> Bool {
        guard let surfaceId = UUID(uuidString: surfaceIdStr) else { return false }
        guard let workspace = currentWorkspace else { return false }
        let idx = workspace.selectedTabIndex
        guard idx >= 0, idx < workspace.tabs.count else { return false }
        return workspace.tabs[idx].id == surfaceId
    }

    func focusTabById(_ tabId: UUID) {
        for (pi, workspace) in workspaces.enumerated() {
            if let ti = workspace.tabs.firstIndex(where: { $0.id == tabId }) {
                selectWorkspace(at: pi)
                selectTabInWorkspace(at: ti)
                window?.makeKeyAndOrderFront(nil)
                return
            }
        }
    }

    // MARK: - Session ID / Badge

    func updateSessionId(forSurfaceId surfaceIdStr: String, sessionId: String) {
        guard let tab = tabForSurfaceId(surfaceIdStr) else { return }
        guard tab.sessionId != sessionId else { return }
        tab.sessionId = sessionId
        SessionManager.shared.saveSessionName(sessionId: sessionId, kind: tab.kind, name: tab.name)
        saveState()
        // Start watching if this is the currently displayed tab
        if let workspace = currentWorkspace,
           let idx = workspace.tabs.firstIndex(where: { $0.id == tab.id }),
           idx == workspace.selectedTabIndex {
            refreshContextBar(for: tab)
        }
    }

    func updateBadge(forSurfaceId surfaceIdStr: String, state: TabItem.BadgeState) {
        guard let tab = tabForSurfaceId(surfaceIdStr) else { return }
        DiagnosticLog.shared.log("badge",
            "updateBadge: surfaceId=\(surfaceIdStr) state=\(state) currentFR=\(type(of: window?.firstResponder))")
        tab.badgeState = state
        rebuildSidebar()
        rebuildTabBar()
    }

    /// Like updateBadge, but substitutes completedUnseen/terminalCompletedUnseen
    /// when the tab transitions to an idle state while unfocused.
    func updateBadgeToIdleOrUnseen(forSurfaceId surfaceIdStr: String, isClaude: Bool) {
        guard let tab = tabForSurfaceId(surfaceIdStr) else { return }
        let wasBusy = isClaude
            ? (tab.badgeState == .thinking || tab.badgeState == .needsPermission)
            : (tab.badgeState == .terminalActive)
        let visible = isTabVisible(surfaceIdStr)
        let idleState: TabItem.BadgeState = isClaude ? .waitingForInput : .terminalIdle
        let unseenState: TabItem.BadgeState = isClaude ? .completedUnseen : .terminalCompletedUnseen
        let newState = (wasBusy && !visible && !tab.suppressUnseen) ? unseenState : idleState
        DiagnosticLog.shared.log("badge",
            "updateBadgeToIdleOrUnseen: surfaceId=\(surfaceIdStr) wasBusy=\(wasBusy) visible=\(visible) suppress=\(tab.suppressUnseen) -> \(newState)")
        tab.badgeState = newState
        rebuildSidebar()
        rebuildTabBar()
    }

    func listTabInfo() -> [TabInfo] {
        var result: [TabInfo] = []
        for workspace in workspaces {
            for tab in workspace.tabs {
                result.append(TabInfo(
                    id: tab.id.uuidString,
                    name: "\(workspace.name)/\(tab.name)",
                    isClaude: tab.isClaude,
                    kind: tab.kind.rawValue,
                    isMaster: false,
                    sessionId: tab.sessionId,
                    badgeState: tab.badgeState.rawValue,
                    workingDirectory: workspace.path
                ))
            }
        }
        return result
    }

    // MARK: - Remote Control

    func renameTab(id tabIdStr: String, name: String) {
        guard let tab = tabForSurfaceId(tabIdStr) else { return }
        tab.name = name
        if let sid = tab.sessionId, !sid.isEmpty {
            SessionManager.shared.saveSessionName(sessionId: sid, kind: tab.kind, name: name)
        }
        rebuildTabBar()
        saveState()
    }

    func closeTabById(_ tabIdStr: String) {
        guard let surfaceId = UUID(uuidString: tabIdStr) else { return }
        handleSurfaceClosedById(surfaceId)
    }

    // MARK: - State Persistence

    func captureState() -> DeckardState {
        var state = DeckardState()
        state.selectedTabIndex = selectedWorkspaceIndex
        state.tabs = workspaces.map { workspace in
            // Store workspace-level info; individual tabs stored in a new field
            TabState(
                id: workspace.id.uuidString,
                sessionId: nil,
                name: workspace.name,
                nameOverride: false,
                isMaster: false,
                isClaude: false,
                workingDirectory: workspace.path
            )
        }
        // Store full workspace data in the new workspaces field
        state.workspaces = workspaces.map { workspace in
            WorkspaceState(
                id: workspace.id.uuidString,
                path: workspace.path,
                name: workspace.name,
                selectedTabIndex: workspace.selectedTabIndex,
                tabs: workspace.tabs.map { tab in
                    WorkspaceTabState(
                        id: tab.id.uuidString,
                        name: tab.name,
                        kind: tab.kind,
                        sessionId: tab.sessionId,
                        tmuxSessionName: tab.surface.tmuxSessionName
                    )
                },
                defaultArgs: workspace.defaultArgs,
                defaultCodexArgs: workspace.defaultCodexArgs
            )
        }

        // Persist sidebar groups
        state.sidebarGroups = sidebarGroups.map { group in
            SidebarGroupState(
                id: group.id.uuidString,
                name: group.name,
                isCollapsed: group.isCollapsed,
                workspaceIds: group.workspaceIds.map { $0.uuidString }
            )
        }

        // Persist sidebar order
        state.sidebarOrder = sidebarOrder.compactMap { item in
            switch item {
            case .group(let group):
                return .group(group.id.uuidString)
            case .workspace(let pid):
                return .workspace(pid.uuidString)
            }
        }

        return state
    }

    func saveState() {
        SessionManager.shared.markDirty()
    }

    private func restoreOrCreateInitial() {
        guard let state = SessionManager.shared.load(),
              let workspaceStates = state.workspaces, !workspaceStates.isEmpty else {
            // Nothing to restore — start autosave immediately
            SessionManager.shared.startAutosave { [weak self] in
                self?.captureState() ?? DeckardState()
            }
            return
        }

        isRestoring = true

        // Pre-flight: touch each unique workspace directory to trigger a single
        // TCC prompt per protected group category (Documents, Desktop, etc.)
        // before mass-creating tabs.  Without this, each forkpty queues its
        // own TCC request and the user sees one dialog per tab.
        let uniquePaths = Set(workspaceStates.map(\.path))
        for path in uniquePaths {
            _ = FileManager.default.isReadableFile(atPath: path)
        }

        let selectedIdx = min(max(state.selectedTabIndex, 0), workspaceStates.count - 1)
        var codexRestoreCandidatesByPath: [String: [String]] = [:]
        var usedCodexSessionIds = Set(workspaceStates.flatMap { workspace in
            workspace.tabs.compactMap { tab in
                tab.kind == .codex ? tab.sessionId : nil
            }
        })

        func recoverCodexSessionId(for workspacePath: String, tabName: String) -> String? {
            let resolvedPath = (workspacePath as NSString).resolvingSymlinksInPath
            if codexRestoreCandidatesByPath[resolvedPath] == nil {
                codexRestoreCandidatesByPath[resolvedPath] = ContextMonitor.shared
                    .listCodexSessions(forWorkspacePath: resolvedPath)
                    .map(\.sessionId)
            }

            while var candidates = codexRestoreCandidatesByPath[resolvedPath], !candidates.isEmpty {
                let sessionId = candidates.removeFirst()
                codexRestoreCandidatesByPath[resolvedPath] = candidates
                guard usedCodexSessionIds.insert(sessionId).inserted else { continue }
                DiagnosticLog.shared.log("restore",
                    "recovered missing Codex session id for \(tabName)@\(resolvedPath): \(sessionId)")
                return sessionId
            }

            return nil
        }

        // Phase 1: Create the active workspace's active tab immediately so the user
        // sees a working terminal right away. Collect remaining tabs for Phase 2.
        var pending: [(workspace: WorkspaceItem, tab: WorkspaceTabState, originalIndex: Int)] = []

        for (i, ps) in workspaceStates.enumerated() {
            let workspace = WorkspaceItem(path: ps.path)
            workspace.name = ps.name
            workspace.defaultArgs = ps.defaultArgs
            workspace.defaultCodexArgs = ps.defaultCodexArgs

            let selTab = min(max(ps.selectedTabIndex, 0), max(ps.tabs.count - 1, 0))

            for (t, ts) in ps.tabs.enumerated() {
                var restoredTab = ts
                if restoredTab.kind == .codex, restoredTab.sessionId == nil {
                    restoredTab.sessionId = recoverCodexSessionId(for: ps.path, tabName: restoredTab.name)
                }

                if i == selectedIdx && t == selTab {
                    // Create the active tab's surface synchronously
                    createTabInWorkspace(workspace, kind: restoredTab.kind, name: restoredTab.name,
                                       sessionIdToResume: restoredTab.kind.isAgent ? restoredTab.sessionId : nil,
                                       tmuxSessionToResume: restoredTab.tmuxSessionName)
                } else {
                    pending.append((workspace: workspace, tab: restoredTab, originalIndex: t))
                }
            }

            workspace.selectedTabIndex = selTab
            workspaces.append(workspace)
        }

        // Keep isRestoring = true until Phase 2 finishes, so selectWorkspace
        // won't clamp selectedTabIndex before all tabs are inserted.

        // Restore sidebar groups
        restoreSidebarGroups(from: state)

        rebuildSidebar()
        if selectedIdx >= 0 && selectedIdx < workspaces.count {
            selectWorkspace(at: selectedIdx)
        }

        // Phase 2: Create remaining surfaces progressively with small delays for UX.
        createTabsProgressively(pending)
    }

    private func restoreSidebarGroups(from state: DeckardState) {
        // During restore, WorkspaceItem gets a new UUID. Build a map from saved-id -> live WorkspaceItem.
        // Match by index (workspaces are created in the same order as workspaceStates) rather than
        // by path, because multiple workspaces can share the same path (e.g. ~/Downloads).
        guard let workspaceStates = state.workspaces else { return }
        var savedIdToWorkspace: [String: WorkspaceItem] = [:]
        for (i, ps) in workspaceStates.enumerated() {
            guard i < workspaces.count else { continue }
            savedIdToWorkspace[ps.id] = workspaces[i]
        }

        // Restore groups
        if let groupStates = state.sidebarGroups {
            for fs in groupStates {
                guard let groupId = UUID(uuidString: fs.id) else { continue }
                let resolvedIds = fs.workspaceIds.compactMap { savedIdToWorkspace[$0]?.id }
                let group = SidebarGroup(
                    id: groupId,
                    name: fs.name,
                    isCollapsed: fs.isCollapsed,
                    workspaceIds: resolvedIds
                )
                sidebarGroups.append(group)
            }
        }

        // Restore sidebar order
        if let orderItems = state.sidebarOrder {
            sidebarOrder = orderItems.compactMap { item in
                switch item {
                case .group(let idStr):
                    if let group = sidebarGroups.first(where: { $0.id.uuidString == idStr }) {
                        return .group(group)
                    }
                    return nil
                case .workspace(let idStr):
                    if let workspace = savedIdToWorkspace[idStr] {
                        return .workspace(workspace.id)
                    }
                    return nil
                }
            }
        }

        // If no saved order, ensureSidebarOrder() will build one from workspaces
    }

    private func createTabsProgressively(_ remaining: [(workspace: WorkspaceItem, tab: WorkspaceTabState, originalIndex: Int)]) {
        guard let first = remaining.first else {
            // All tabs created — rebuild UI to reflect the full state
            isRestoring = false
            rebuildSidebar()
            rebuildTabBar()
            saveState()

            // Start autosave now that restore is complete — autosaving
            // during progressive restore would lose tabs on crash.
            SessionManager.shared.startAutosave { [weak self] in
                self?.captureState() ?? DeckardState()
            }

            // Dump tab creation order -> PID mapping for diagnostics
            let mapping = tabCreationOrder.enumerated().map { (i, id) -> String in
                var label = "?"
                for workspace in workspaces {
                    if let tab = workspace.tabs.first(where: { $0.id == id }) {
                        label = "\(tab.kind.rawValue.prefix(1).uppercased()):\(tab.name)@\(workspace.name)"
                        break
                    }
                }
                return "  [\(i)] \(label)"
            }.joined(separator: "\n")
            DiagnosticLog.shared.log("processmon", "tabCreationOrder after restore (\(tabCreationOrder.count) tabs):\n\(mapping)")

            return
        }

        let ts = first.tab
        let workspace = first.workspace
        let insertAt = first.originalIndex

        // Create the tab (appends to workspace.tabs)
        createTabInWorkspace(workspace, kind: ts.kind, name: ts.name,
                           sessionIdToResume: ts.kind.isAgent ? ts.sessionId : nil,
                           tmuxSessionToResume: ts.tmuxSessionName)

        // Move it from the end to its original position
        if insertAt < workspace.tabs.count - 1 {
            let tab = workspace.tabs.removeLast()
            workspace.tabs.insert(tab, at: min(insertAt, workspace.tabs.count))
        }

        // Small delay between tab creations for smoother UX during restore.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            self.createTabsProgressively(Array(remaining.dropFirst()))
        }
    }

    // MARK: - Theme

    @objc private func vibrancyDidChange() {
        applyVibrancySettings()
    }

    private func applyVibrancySettings() {
        let enabled = UserDefaults.standard.object(forKey: "sidebarVibrancy") as? Bool ?? false
        let colors = ThemeManager.shared.currentColors

        sidebarEffectView.isHidden = !enabled
        sidebarView.layer?.backgroundColor = enabled
            ? NSColor.clear.cgColor
            : colors.sidebarBackground.cgColor
    }

    @objc private func quotaDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let workspace = self.currentWorkspace,
                  let activeTab = workspace.tabs[safe: workspace.selectedTabIndex],
                  activeTab.kind == .claude else { return }
            self.quotaView.update(
                snapshot: QuotaMonitor.shared.latest,
                tokenRate: QuotaMonitor.shared.tokenRate,
                sparklineData: QuotaMonitor.shared.sparklineData)
        }
    }

    @objc private func themeDidChange(_ notification: Notification) {
        guard let scheme = notification.userInfo?["scheme"] as? TerminalColorScheme else { return }

        // Update chrome colors
        let newColors = ThemeManager.shared.currentColors
        window?.backgroundColor = newColors.background
        window?.appearance = newColors.isDark
            ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        tabBar.layer?.backgroundColor = newColors.tabBarBackground.cgColor
        applyVibrancySettings()
        emptyStateView?.layer?.backgroundColor = newColors.background.cgColor
        quotaView.applyTheme(colors: newColors)
        rebuildSidebar()
        rebuildTabBar()

        // Apply color scheme to all terminal surfaces
        for workspace in workspaces {
            for tab in workspace.tabs {
                tab.surface.applyColorScheme(scheme)
            }
        }
    }

    // MARK: - Navigation

    /// Workspace indices matching visible sidebar rows (skips collapsed groups).
    func workspaceIndicesInSidebarOrder() -> [Int] {
        var indices: [Int] = []
        for item in sidebarOrder {
            switch item {
            case .workspace(let id):
                if let i = workspaces.firstIndex(where: { $0.id == id }) { indices.append(i) }
            case .group(let group):
                guard !group.isCollapsed else { continue }
                for id in group.workspaceIds {
                    if let i = workspaces.firstIndex(where: { $0.id == id }) { indices.append(i) }
                }
            }
        }
        return indices
    }

    func selectNextWorkspace() {
        let ordered = workspaceIndicesInSidebarOrder()
        guard !ordered.isEmpty else { return }
        let cur = ordered.firstIndex(of: selectedWorkspaceIndex) ?? -1
        selectWorkspace(at: ordered[(cur + 1) % ordered.count])
    }

    func selectPrevWorkspace() {
        let ordered = workspaceIndicesInSidebarOrder()
        guard !ordered.isEmpty else { return }
        let cur = ordered.firstIndex(of: selectedWorkspaceIndex) ?? ordered.count
        selectWorkspace(at: ordered[(cur - 1 + ordered.count) % ordered.count])
    }

    func selectWorkspace(byNumber n: Int) {
        let ordered = workspaceIndicesInSidebarOrder()
        guard n >= 0, n < ordered.count else { return }
        selectWorkspace(at: ordered[n])
    }

    func updateShortcutIndicators(commandHeld: Bool) {
        let ordered = commandHeld ? workspaceIndicesInSidebarOrder() : []
        for view in sidebarStackView.arrangedSubviews {
            guard let row = view as? VerticalTabRowView else { continue }
            if let pos = ordered.firstIndex(of: row.index), pos < 10 {
                row.shortcutBadge = "\((pos + 1) % 10)"
            } else {
                row.shortcutBadge = nil
            }
        }
    }
}

// MARK: - Collection Extension

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - NSColor Extension

extension NSColor {
    func toHex() -> String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#808080" }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        let a = Int(rgb.alphaComponent * 255)
        if a == 255 {
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    static func fromHex(_ hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8 else { return nil }
        var value: UInt64 = 0
        Scanner(string: h).scanHexInt64(&value)
        if h.count == 6 {
            return NSColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1.0)
        }
        return NSColor(
            red: CGFloat((value >> 24) & 0xFF) / 255,
            green: CGFloat((value >> 16) & 0xFF) / 255,
            blue: CGFloat((value >> 8) & 0xFF) / 255,
            alpha: CGFloat(value & 0xFF) / 255)
    }
}

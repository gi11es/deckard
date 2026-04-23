import AppKit
import KeyboardShortcuts

/// Format a tooltip with the current shortcut, e.g. "Open Folder (Cmd+O)"
@MainActor
func shortcutTooltip(_ label: String, for name: KeyboardShortcuts.Name) -> String {
    if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
        return "\(label) (\(shortcut.description))"
    }
    return label
}

// MARK: - Data Models

/// A horizontal tab within a project (Claude session or terminal).
class TabItem {
    let id: UUID
    var surface: TerminalSurface
    var name: String
    var isClaude: Bool
    var sessionId: String?
    var badgeState: BadgeState = .none
    /// Set during restore — suppresses completedUnseen until hook.session-start fires.
    var suppressUnseen: Bool = false

    enum BadgeState: String {
        case none
        case idle             // grey - connected but no activity yet
        case thinking
        case waitingForInput
        case needsPermission
        case error
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

    init(surface: TerminalSurface, name: String, isClaude: Bool) {
        self.id = surface.surfaceId
        self.surface = surface
        self.name = name
        self.isClaude = isClaude
    }
}

/// A project in the vertical sidebar — contains horizontal tabs.
class ProjectItem {
    let id: UUID
    var path: String
    var name: String  // basename of path
    var tabs: [TabItem] = []
    var selectedTabIndex: Int = 0
    var defaultArgs: String?

    init(path: String) {
        self.id = UUID()
        self.path = (path as NSString).resolvingSymlinksInPath
        self.name = (self.path as NSString).lastPathComponent
    }
}

// MARK: - Sidebar Folder Model

/// A folder in the sidebar that groups projects.
class SidebarFolder {
    let id: UUID
    var name: String
    var isCollapsed: Bool
    var projectIds: [UUID]  // references to ProjectItem.id

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.isCollapsed = false
        self.projectIds = []
    }

    init(id: UUID, name: String, isCollapsed: Bool, projectIds: [UUID]) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.projectIds = projectIds
    }
}

/// Ordered sidebar items: either a folder or an ungrouped project reference.
enum SidebarItem {
    case folder(SidebarFolder)
    case project(UUID)  // ProjectItem.id
}

// MARK: - Default Tab Configuration

struct DefaultTabConfig {
    var entries: [(isClaude: Bool, name: String)]

    static var current: DefaultTabConfig {
        let raw = UserDefaults.standard.string(forKey: "defaultTabConfig") ?? "claude, terminal"
        let entries = raw.split(separator: ",").compactMap { item -> (isClaude: Bool, name: String)? in
            let trimmed = item.trimmingCharacters(in: .whitespaces).lowercased()
            switch trimmed {
            case "claude": return (isClaude: true, name: "Claude")
            case "terminal": return (isClaude: false, name: "Terminal")
            default: return nil
            }
        }
        return DefaultTabConfig(entries: entries.isEmpty ? [(true, "Claude"), (false, "Terminal")] : entries)
    }
}

// MARK: - Window Controller

let deckardProjectDragType = NSPasteboard.PasteboardType("com.deckard.project-reorder")
let deckardSidebarDragType = NSPasteboard.PasteboardType("com.deckard.sidebar-drag")
let deckardFolderDragType = NSPasteboard.PasteboardType("com.deckard.folder-reorder")


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
    var projects: [ProjectItem] = []
    var selectedProjectIndex: Int = -1

    // Sidebar folders
    var sidebarFolders: [SidebarFolder] = []
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
    /// Opaque overlay shown when a project has no tabs, covering any surfaces underneath.
    private var emptyStateView: NSView?

    let sidebarDropZone = SidebarDropZone()
    private let quotaView = QuotaView()
    private let sidebarEffectView = NSVisualEffectView()
    private let sidebarWidth: CGFloat = 210
    private var sidebarInitialized = false
    private var sidebarWidthBeforeCollapse: CGFloat = 210
    /// Recently closed projects — stored so reopening the same path restores tabs.
    private var recentlyClosedProjects: [ProjectState] = []
    var isRestoring = false
    /// Tabs in the order they were created (for ProcessMonitor PID matching).
    var tabCreationOrder: [UUID] = []

    /// Last activity info per surface, used for tooltips.
    var terminalActivity: [UUID: ProcessMonitor.ActivityInfo] = [:]
    /// Consecutive active poll count per surface — require 2 before showing as active.
    private var terminalActiveStreak: [UUID: Int] = [:]
    private var flagsMonitor: Any?

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

        window.setFrameAutosaveName("DeckardMainWindow")
        if !window.setFrameUsingName("DeckardMainWindow") {
            window.center()
        }

        setupUI()

        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange(_:)), name: .deckardThemeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(vibrancyDidChange), name: .deckardVibrancyChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(quotaDidChange), name: QuotaMonitor.quotaDidChange, object: nil)
        // Show cached quota data immediately if available
        quotaDidChange()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Re-assert first responder after system wake to recover from potential focus loss
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let wc = self as? DeckardWindowController,
                      let project = wc.currentProject else { return }
                let idx = project.selectedTabIndex
                guard idx >= 0, idx < project.tabs.count else { return }
                let tab = project.tabs[idx]
                let fr = wc.window?.firstResponder
                DiagnosticLog.shared.log("sleep",
                    "wake recovery: firstResponder=\(type(of: fr)) surfaceId=\(tab.id)")
                wc.window?.makeFirstResponder(tab.surface.view)
            }
        }

        restoreOrCreateInitial()

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let mods = revealNumbersModifiers()
            let active = !mods.isEmpty && event.modifierFlags.contains(mods)
            self?.updateShortcutIndicators(commandHeld: active)
            return event
        }

        // If no projects after restore, auto-show the project picker
        if projects.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AppDelegate.shared?.openProjectPicker()
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
        sidebarDropZone.registerForDraggedTypes([deckardProjectDragType, deckardFolderDragType])
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

        // Opaque empty-state overlay — covers all surfaces when a project has no tabs.
        let emptyBg = NSView()
        emptyBg.wantsLayer = true
        emptyBg.layer?.backgroundColor = colors.background.cgColor
        emptyBg.translatesAutoresizingMaskIntoConstraints = false
        let welcome = NSTextField(labelWithString: "Press \u{2318}O to open a project")
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

    // MARK: - Project Management

    func openProjectPaths() -> [String] {
        return projects.map { $0.path }
    }

    func openProject(path: String) {
        let project = ProjectItem(path: path)

        // Check if we have a recently closed snapshot — restore tabs from it
        // Use project.path (symlinks resolved) so symlinked paths match canonical ones.
        if let snapshot = recentlyClosedProjects.first(where: { $0.path == project.path }) {
            recentlyClosedProjects.removeAll { $0.path == project.path }
            project.name = snapshot.name
            for ts in snapshot.tabs {
                createTabInProject(project, isClaude: ts.isClaude, name: ts.name,
                                   sessionIdToResume: ts.isClaude ? ts.sessionId : nil,
                                   tmuxSessionToResume: ts.tmuxSessionName)
            }
            project.selectedTabIndex = min(snapshot.selectedTabIndex, project.tabs.count - 1)
        }

        // If no tabs restored, create defaults
        if project.tabs.isEmpty {
            let config = DefaultTabConfig.current
            for entry in config.entries {
                createTabInProject(project, isClaude: entry.isClaude)
            }
        }

        projects.append(project)
        sidebarOrder.append(.project(project.id))
        rebuildSidebar()
        selectProject(at: projects.count - 1)
        if !isRestoring { saveState() }
    }

    func closeCurrentProject() {
        guard selectedProjectIndex >= 0, selectedProjectIndex < projects.count else { return }
        closeProject(at: selectedProjectIndex)
    }

    func exploreCurrentProjectSessions() {
        guard selectedProjectIndex >= 0, selectedProjectIndex < projects.count else { return }
        let project = projects[selectedProjectIndex]
        let fakeMenuItem = NSMenuItem()
        fakeMenuItem.representedObject = project
        exploreSessionsMenuAction(fakeMenuItem)
    }

    func moveCurrentProjectOutOfFolder() {
        guard selectedProjectIndex >= 0, selectedProjectIndex < projects.count else { return }
        let project = projects[selectedProjectIndex]
        moveProjectOutOfFolder(projectId: project.id)
    }

    func closeProject(at index: Int) {
        guard index >= 0, index < projects.count else { return }
        let project = projects[index]

        // Save project state for potential restoration
        let snapshot = ProjectState(
            id: project.id.uuidString,
            path: project.path,
            name: project.name,
            selectedTabIndex: project.selectedTabIndex,
            tabs: project.tabs.map { tab in
                ProjectTabState(id: tab.id.uuidString, name: tab.name,
                                isClaude: tab.isClaude, sessionId: tab.sessionId,
                                tmuxSessionName: tab.surface.tmuxSessionName)
            }
        )
        recentlyClosedProjects.removeAll { $0.path == project.path }
        recentlyClosedProjects.append(snapshot)

        // Persist session names for claude tabs so they survive app restarts
        for tab in project.tabs where tab.isClaude {
            if let sid = tab.sessionId, !sid.isEmpty {
                SessionManager.shared.saveSessionName(sessionId: sid, name: tab.name)
            }
        }

        // Detach terminal tabs so their tmux sessions survive for re-open;
        // terminate Claude tabs (they use their own resume mechanism).
        let closedIds = Set(project.tabs.map { $0.id })
        tabCreationOrder.removeAll { closedIds.contains($0) }
        for tab in project.tabs {
            if !tab.isClaude && tab.surface.tmuxSessionName != nil {
                tab.surface.detach()
            } else {
                tab.surface.terminate()
            }
        }

        projects.remove(at: index)
        removeSidebarReference(projectId: project.id)
        rebuildSidebar()

        if projects.isEmpty {
            selectedProjectIndex = -1
            currentTerminalView?.removeFromSuperview()
            currentTerminalView = nil
            rebuildTabBar()
        } else if let next = nextVisibleProjectIndex(near: index) {
            selectProject(at: next, autoExpandFolder: false)
        } else {
            // All remaining projects are inside collapsed folders — show empty state.
            selectedProjectIndex = -1
            currentTerminalView?.removeFromSuperview()
            currentTerminalView = nil
            rebuildTabBar()
            rebuildSidebar()
            showEmptyState()
        }
        saveState()
    }

    /// Returns the index of the nearest project that is visible in the sidebar
    /// (i.e. top-level or inside a non-collapsed folder), or nil if none.
    private func nextVisibleProjectIndex(near index: Int) -> Int? {
        let collapsedProjectIds = Set(sidebarFolders.filter(\.isCollapsed).flatMap(\.projectIds))
        let clamped = min(index, projects.count - 1)
        // Search outward from `clamped`: check clamped, clamped-1, clamped+1, ...
        var lo = clamped, hi = clamped + 1
        while lo >= 0 || hi < projects.count {
            if lo >= 0, !collapsedProjectIds.contains(projects[lo].id) { return lo }
            if hi < projects.count, !collapsedProjectIds.contains(projects[hi].id) { return hi }
            lo -= 1; hi += 1
        }
        return nil
    }

    func selectProject(at index: Int, autoExpandFolder: Bool = true) {
        guard index >= 0, index < projects.count else { return }
        selectedProjectIndex = index

        let project = projects[index]

        // Auto-expand folder if the selected project is inside a collapsed one
        if autoExpandFolder {
            for folder in sidebarFolders where folder.isCollapsed && folder.projectIds.contains(project.id) {
                folder.isCollapsed = false
                rebuildSidebar()
            }
        }

        rebuildTabBar()

        if project.tabs.isEmpty {
            currentTerminalView = nil
            showEmptyState()
        } else {
            // Always clamp for safe array access, even during restore
            let safeIdx = max(0, min(project.selectedTabIndex, project.tabs.count - 1))
            clearUnseenIfNeeded(project.tabs[safeIdx])
            showTab(project.tabs[safeIdx])
        }

        // Show folder path in title bar
        let home = NSHomeDirectory()
        let displayPath = project.path.hasPrefix(home)
            ? "~" + project.path.dropFirst(home.count)
            : project.path
        #if DEBUG
        window?.title = "\(displayPath) [DEV]"
        #else
        window?.title = displayPath
        #endif

        updateSidebarSelection()
    }

    // MARK: - Tab Management (within a project)

    func createTabInProject(_ project: ProjectItem, isClaude: Bool, name: String? = nil, sessionIdToResume: String? = nil, forkSession: Bool = false, tmuxSessionToResume: String? = nil, extraArgs: String? = nil) {
        let surface = TerminalSurface()
        let tabName: String
        if let name = name {
            tabName = name
        } else {
            let base = isClaude ? "Claude" : "Terminal"
            // Find the highest existing number for this tab type to avoid duplicates
            let prefix = "\(base) #"
            let maxNum = project.tabs
                .filter { $0.isClaude == isClaude }
                .compactMap { tab -> Int? in
                    guard tab.name.hasPrefix(prefix) else { return nil }
                    return Int(tab.name.dropFirst(prefix.count))
                }
                .max() ?? 0
            tabName = "\(base) #\(maxNum + 1)"
        }
        let tab = TabItem(surface: surface, name: tabName, isClaude: isClaude)
        surface.tabId = tab.id
        tab.badgeState = isClaude ? .idle : .terminalIdle
        if isClaude && isRestoring {
            tab.suppressUnseen = true
        }
        var envVars: [String: String] = [:]
        if isClaude {
            tab.sessionId = sessionIdToResume
            envVars["DECKARD_SESSION_TYPE"] = "claude"
        }

        let initialInput: String?
        if isClaude {
            let resolvedArgs = extraArgs ?? project.defaultArgs ?? UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
            let extraArgsSuffix = resolvedArgs.isEmpty ? "" : " \(resolvedArgs)"
            var claudeArgs = extraArgsSuffix
            if let sessionIdToResume {
                let encoded = project.path.claudeProjectDirName
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
        } else {
            initialInput = nil
        }

        DiagnosticLog.shared.log("surface", "createTab: \(isClaude ? "claude" : "terminal") surfaceId=\(surface.surfaceId)")

        surface.startShell(
            workingDirectory: project.path,
            envVars: envVars,
            initialInput: initialInput,
            tmuxSession: tmuxSessionToResume
        )

        surface.onProcessExit = { [weak self] exitedSurface in
            DispatchQueue.main.async {
                self?.handleSurfaceClosedById(exitedSurface.surfaceId)
            }
        }

        project.tabs.append(tab)
        tabCreationOrder.append(tab.id)
    }

    /// Guards against rapid duplicate tab creation from key repeat.
    var isCreatingTab = false

    func addYoloTabToCurrentProject() {
        guard !isCreatingTab else { return }
        isCreatingTab = true

        guard selectedProjectIndex >= 0, selectedProjectIndex < projects.count else {
            isCreatingTab = false
            return
        }
        let project = projects[selectedProjectIndex]

        let prefix = "Yolo #"
        let maxNum = project.tabs
            .compactMap { tab -> Int? in
                guard tab.name.hasPrefix(prefix) else { return nil }
                return Int(tab.name.dropFirst(prefix.count))
            }
            .max() ?? 0
        let tabName = "\(prefix)\(maxNum + 1)"

        let baseArgs = project.defaultArgs ?? UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
        let yoloFlag = "--dangerously-skip-permissions"
        let yoloArgs = baseArgs.contains(yoloFlag) ? baseArgs : (baseArgs.isEmpty ? yoloFlag : "\(baseArgs) \(yoloFlag)")

        createTabInProject(project, isClaude: true, name: tabName, extraArgs: yoloArgs)
        finalizeTabCreation(in: project)
    }

    func addTabToCurrentProject(isClaude: Bool) {
        guard !isCreatingTab else { return }
        isCreatingTab = true

        guard selectedProjectIndex >= 0, selectedProjectIndex < projects.count else {
            isCreatingTab = false
            return
        }
        let project = projects[selectedProjectIndex]

        if isClaude && UserDefaults.standard.bool(forKey: "promptForSessionArgs") {
            promptForClaudeArgs(for: project) { [weak self] args in
                guard let self else { return }
                guard let args else {
                    // User cancelled
                    self.isCreatingTab = false
                    return
                }
                guard self.projects.contains(where: { $0 === project }) else {
                    self.isCreatingTab = false
                    return
                }
                self.createTabInProject(project, isClaude: true, extraArgs: args)
                self.finalizeTabCreation(in: project)
            }
        } else {
            createTabInProject(project, isClaude: isClaude)
            finalizeTabCreation(in: project)
        }
    }

    private func finalizeTabCreation(in project: ProjectItem) {
        project.selectedTabIndex = project.tabs.count - 1
        rebuildTabBar()
        rebuildSidebar()
        showTab(project.tabs[project.selectedTabIndex])
        saveState()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isCreatingTab = false
        }
    }

    private func promptForClaudeArgs(for project: ProjectItem, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Claude Code Arguments"
        alert.informativeText = "Arguments passed to this session:"
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let field = ClaudeArgsField(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        field.stringValue = project.defaultArgs ?? UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
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
        guard let project = currentProject else { return }
        let idx = project.selectedTabIndex
        guard idx >= 0, idx < project.tabs.count else { return }

        let tab = project.tabs[idx]
        tab.surface.terminate()
        tabCreationOrder.removeAll { $0 == tab.id }

        project.tabs.remove(at: idx)

        if project.tabs.isEmpty {
            // Keep the project in the sidebar with just the "+" button
            currentTerminalView = nil
            showEmptyState()
            rebuildTabBar()
            rebuildSidebar()
        } else {
            project.selectedTabIndex = min(idx, project.tabs.count - 1)
            rebuildTabBar()
            rebuildSidebar()
            clearUnseenIfNeeded(project.tabs[project.selectedTabIndex])
            showTab(project.tabs[project.selectedTabIndex])
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
        case .terminalCompletedUnseen:
            tab.badgeState = .terminalIdle
            rebuildSidebar()
            rebuildTabBar()
        default:
            break
        }
    }

    func selectTabInProject(at tabIndex: Int) {
        guard let project = currentProject else { return }
        guard tabIndex >= 0, tabIndex < project.tabs.count else { return }
        project.selectedTabIndex = tabIndex
        clearUnseenIfNeeded(project.tabs[tabIndex])
        rebuildTabBar()
        showTab(project.tabs[tabIndex])
    }

    /// Switch to a tab without rebuilding the tab bar.
    /// Called from HorizontalTabView.mouseDown so the terminal switch
    /// is not lost if an async rebuild destroys the view before mouseUp.
    func switchToTab(at tabIndex: Int) {
        guard let project = currentProject else { return }
        guard tabIndex >= 0, tabIndex < project.tabs.count else { return }
        guard tabIndex != project.selectedTabIndex else { return }
        project.selectedTabIndex = tabIndex
        clearUnseenIfNeeded(project.tabs[tabIndex])
        showTab(project.tabs[tabIndex])
    }

    func selectNextTab() {
        guard let project = currentProject, !project.tabs.isEmpty else { return }
        selectTabInProject(at: (project.selectedTabIndex + 1) % project.tabs.count)
    }

    func selectPrevTab() {
        guard let project = currentProject, !project.tabs.isEmpty else { return }
        selectTabInProject(at: (project.selectedTabIndex - 1 + project.tabs.count) % project.tabs.count)
    }

    var currentProject: ProjectItem? {
        guard selectedProjectIndex >= 0, selectedProjectIndex < projects.count else { return nil }
        return projects[selectedProjectIndex]
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

    /// Show the empty-state overlay (project has no tabs).
    func showEmptyState() {
        currentTerminalView?.removeFromSuperview()
        emptyStateView?.isHidden = false
    }

    /// Hide the empty-state overlay (active tab is being shown).
    private func hideEmptyState() {
        emptyStateView?.isHidden = true
    }



    private func refreshContextBar(for tab: TabItem) {
        contextTimer?.invalidate()
        contextTimer = nil

        if tab.isClaude {
            updateContextUsage(for: tab)
            contextTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.updateContextUsage(for: tab)
            }
        } else {
            quotaView.updateContext(usage: nil, tabName: nil)
            // Still show quota/sparkline with last known values on non-Claude tabs
            quotaView.update(
                snapshot: QuotaMonitor.shared.latest,
                tokenRate: QuotaMonitor.shared.tokenRate,
                sparklineData: QuotaMonitor.shared.sparklineData)
        }
    }

    private func updateContextUsage(for tab: TabItem) {
        guard let sessionId = tab.sessionId,
              let project = currentProject else {
            DiagnosticLog.shared.log("context",
                "updateContextUsage: skipped — sessionId=\(tab.sessionId ?? "nil") project=\(currentProject != nil)")
            quotaView.updateContext(usage: nil, tabName: nil)
            return
        }

        let tabName = tab.name
        let tabId = tab.id
        let projectPath = project.path
        let allPaths = projects.map { $0.path }
        DispatchQueue.global(qos: .utility).async {
            let usage = ContextMonitor.shared.getUsage(sessionId: sessionId, projectPath: projectPath)
            let rate = QuotaMonitor.shared.computeTokenRate(projectPaths: allPaths)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Only update if this tab is still the active one
                guard let project = self.currentProject,
                      let activeTab = project.tabs[safe: project.selectedTabIndex],
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

    // MARK: - Process Monitor

    private func startProcessMonitor() {
        processMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Build tab infos — order doesn't matter since PID matching
            // is done via control socket registration, not sorted order.
            var tabInfos: [ProcessMonitor.TabInfo] = []
            for project in self.projects {
                for tab in project.tabs {
                    tabInfos.append(ProcessMonitor.TabInfo(
                        surfaceId: tab.id, isClaude: tab.isClaude,
                        name: tab.name, projectPath: project.path))
                }
            }
            DispatchQueue.global(qos: .utility).async {
                let states = ProcessMonitor.shared.poll(tabs: tabInfos)
                DispatchQueue.main.async {
                    self.applyTerminalBadgeStates(states)
                }
            }
        }
    }

    private func applyTerminalBadgeStates(_ states: [UUID: ProcessMonitor.ActivityInfo]) {
        var changed = false
        for project in projects {
            for tab in project.tabs where !tab.isClaude {
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
                            "badge -> terminalActive: project=\(project.path) tab=\"\(tab.name)\"")
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
        for project in projects {
            for tab in project.tabs where tab.surface.surfaceId == surfaceId {
                tab.surface.title = title
                rebuildTabBar()
                return
            }
        }
    }

    func handleSurfaceClosedById(_ surfaceId: UUID) {
        for (pi, project) in projects.enumerated() {
            if let ti = project.tabs.firstIndex(where: { $0.id == surfaceId }) {
                let tab = project.tabs[ti]

                // Terminal tabs: restart shell instead of removing the tab.
                // Reconnects to the tmux session if it still exists, otherwise
                // starts a fresh shell. Rate-limited to prevent crash loops.
                if !tab.isClaude && tab.surface.canRestart {
                    DiagnosticLog.shared.log("surface",
                        "restarting shell for surfaceId=\(surfaceId)")
                    tab.surface.restartShell(workingDirectory: project.path)
                    return
                }

                tab.surface.terminate()
                tabCreationOrder.removeAll { $0 == tab.id }

                project.tabs.remove(at: ti)

                if project.tabs.isEmpty && pi == selectedProjectIndex {
                    currentTerminalView?.removeFromSuperview()
                    currentTerminalView = nil
                    rebuildTabBar()
                    rebuildSidebar()
                } else if project.tabs.isEmpty {
                    rebuildSidebar()
                } else if pi == selectedProjectIndex {
                    project.selectedTabIndex = min(project.selectedTabIndex, project.tabs.count - 1)
                    rebuildTabBar()
                    rebuildSidebar()
                    showTab(project.tabs[project.selectedTabIndex])
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
        for project in projects {
            if let tab = project.tabs.first(where: { $0.id == surfaceId }) {
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
        guard let project = currentProject else { return false }
        let idx = project.selectedTabIndex
        guard idx >= 0, idx < project.tabs.count else { return false }
        return project.tabs[idx].id == surfaceId && (window?.isKeyWindow ?? false)
    }

    /// Whether the tab is currently visible (selected tab in the active project),
    /// regardless of whether the Deckard window is in the foreground.
    func isTabVisible(_ surfaceIdStr: String) -> Bool {
        guard let surfaceId = UUID(uuidString: surfaceIdStr) else { return false }
        guard let project = currentProject else { return false }
        let idx = project.selectedTabIndex
        guard idx >= 0, idx < project.tabs.count else { return false }
        return project.tabs[idx].id == surfaceId
    }

    func focusTabById(_ tabId: UUID) {
        for (pi, project) in projects.enumerated() {
            if let ti = project.tabs.firstIndex(where: { $0.id == tabId }) {
                selectProject(at: pi)
                selectTabInProject(at: ti)
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
        SessionManager.shared.saveSessionName(sessionId: sessionId, name: tab.name)
        saveState()
        // Start watching if this is the currently displayed tab
        if let project = currentProject,
           let idx = project.tabs.firstIndex(where: { $0.id == tab.id }),
           idx == project.selectedTabIndex {
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
        for project in projects {
            for tab in project.tabs {
                result.append(TabInfo(
                    id: tab.id.uuidString,
                    name: "\(project.name)/\(tab.name)",
                    isClaude: tab.isClaude,
                    isMaster: false,
                    sessionId: tab.sessionId,
                    badgeState: tab.badgeState.rawValue,
                    workingDirectory: project.path
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
            SessionManager.shared.saveSessionName(sessionId: sid, name: name)
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
        state.selectedTabIndex = selectedProjectIndex
        state.tabs = projects.map { project in
            // Store project-level info; individual tabs stored in a new field
            TabState(
                id: project.id.uuidString,
                sessionId: nil,
                name: project.name,
                nameOverride: false,
                isMaster: false,
                isClaude: false,
                workingDirectory: project.path
            )
        }
        // Store full project data in the new projects field
        state.projects = projects.map { project in
            ProjectState(
                id: project.id.uuidString,
                path: project.path,
                name: project.name,
                selectedTabIndex: project.selectedTabIndex,
                tabs: project.tabs.map { tab in
                    ProjectTabState(
                        id: tab.id.uuidString,
                        name: tab.name,
                        isClaude: tab.isClaude,
                        sessionId: tab.sessionId,
                        tmuxSessionName: tab.surface.tmuxSessionName
                    )
                },
                defaultArgs: project.defaultArgs
            )
        }

        // Persist sidebar folders
        state.sidebarFolders = sidebarFolders.map { folder in
            SidebarFolderState(
                id: folder.id.uuidString,
                name: folder.name,
                isCollapsed: folder.isCollapsed,
                projectIds: folder.projectIds.map { $0.uuidString }
            )
        }

        // Persist sidebar order
        state.sidebarOrder = sidebarOrder.compactMap { item in
            switch item {
            case .folder(let folder):
                return .folder(folder.id.uuidString)
            case .project(let pid):
                return .project(pid.uuidString)
            }
        }

        return state
    }

    func saveState() {
        SessionManager.shared.markDirty()
    }

    private func restoreOrCreateInitial() {
        guard let state = SessionManager.shared.load(),
              let projectStates = state.projects, !projectStates.isEmpty else {
            // Nothing to restore — start autosave immediately
            SessionManager.shared.startAutosave { [weak self] in
                self?.captureState() ?? DeckardState()
            }
            return
        }

        isRestoring = true

        // Pre-flight: touch each unique project directory to trigger a single
        // TCC prompt per protected folder category (Documents, Desktop, etc.)
        // before mass-creating tabs.  Without this, each forkpty queues its
        // own TCC request and the user sees one dialog per tab.
        let uniquePaths = Set(projectStates.map(\.path))
        for path in uniquePaths {
            _ = FileManager.default.isReadableFile(atPath: path)
        }

        let selectedIdx = min(max(state.selectedTabIndex, 0), projectStates.count - 1)

        // Phase 1: Create the active project's active tab immediately so the user
        // sees a working terminal right away. Collect remaining tabs for Phase 2.
        var pending: [(project: ProjectItem, tab: ProjectTabState, originalIndex: Int)] = []

        for (i, ps) in projectStates.enumerated() {
            let project = ProjectItem(path: ps.path)
            project.name = ps.name
            project.defaultArgs = ps.defaultArgs

            let selTab = min(max(ps.selectedTabIndex, 0), max(ps.tabs.count - 1, 0))

            for (t, ts) in ps.tabs.enumerated() {
                if i == selectedIdx && t == selTab {
                    // Create the active tab's surface synchronously
                    createTabInProject(project, isClaude: ts.isClaude, name: ts.name,
                                       sessionIdToResume: ts.isClaude ? ts.sessionId : nil,
                                       tmuxSessionToResume: ts.tmuxSessionName)
                } else {
                    pending.append((project: project, tab: ts, originalIndex: t))
                }
            }

            project.selectedTabIndex = selTab
            projects.append(project)
        }

        // Keep isRestoring = true until Phase 2 finishes, so selectProject
        // won't clamp selectedTabIndex before all tabs are inserted.

        // Restore sidebar folders
        restoreSidebarFolders(from: state)

        rebuildSidebar()
        if selectedIdx >= 0 && selectedIdx < projects.count {
            selectProject(at: selectedIdx)
        }

        // Phase 2: Create remaining surfaces progressively with small delays for UX.
        createTabsProgressively(pending)
    }

    private func restoreSidebarFolders(from state: DeckardState) {
        // During restore, ProjectItem gets a new UUID. Build a map from saved-id -> live ProjectItem.
        // Match by index (projects are created in the same order as projectStates) rather than
        // by path, because multiple projects can share the same path (e.g. ~/Downloads).
        guard let projectStates = state.projects else { return }
        var savedIdToProject: [String: ProjectItem] = [:]
        for (i, ps) in projectStates.enumerated() {
            guard i < projects.count else { continue }
            savedIdToProject[ps.id] = projects[i]
        }

        // Restore folders
        if let folderStates = state.sidebarFolders {
            for fs in folderStates {
                guard let folderId = UUID(uuidString: fs.id) else { continue }
                let resolvedIds = fs.projectIds.compactMap { savedIdToProject[$0]?.id }
                let folder = SidebarFolder(
                    id: folderId,
                    name: fs.name,
                    isCollapsed: fs.isCollapsed,
                    projectIds: resolvedIds
                )
                sidebarFolders.append(folder)
            }
        }

        // Restore sidebar order
        if let orderItems = state.sidebarOrder {
            sidebarOrder = orderItems.compactMap { item in
                switch item {
                case .folder(let idStr):
                    if let folder = sidebarFolders.first(where: { $0.id.uuidString == idStr }) {
                        return .folder(folder)
                    }
                    return nil
                case .project(let idStr):
                    if let project = savedIdToProject[idStr] {
                        return .project(project.id)
                    }
                    return nil
                }
            }
        }

        // If no saved order, ensureSidebarOrder() will build one from projects
    }

    private func createTabsProgressively(_ remaining: [(project: ProjectItem, tab: ProjectTabState, originalIndex: Int)]) {
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
                for project in projects {
                    if let tab = project.tabs.first(where: { $0.id == id }) {
                        label = "\(tab.isClaude ? "C" : "T"):\(tab.name)@\(project.name)"
                        break
                    }
                }
                return "  [\(i)] \(label)"
            }.joined(separator: "\n")
            DiagnosticLog.shared.log("processmon", "tabCreationOrder after restore (\(tabCreationOrder.count) tabs):\n\(mapping)")

            return
        }

        let ts = first.tab
        let project = first.project
        let insertAt = first.originalIndex

        // Create the tab (appends to project.tabs)
        createTabInProject(project, isClaude: ts.isClaude, name: ts.name,
                           sessionIdToResume: ts.isClaude ? ts.sessionId : nil,
                           tmuxSessionToResume: ts.tmuxSessionName)

        // Move it from the end to its original position
        if insertAt < project.tabs.count - 1 {
            let tab = project.tabs.removeLast()
            project.tabs.insert(tab, at: min(insertAt, project.tabs.count))
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
        for project in projects {
            for tab in project.tabs {
                tab.surface.applyColorScheme(scheme)
            }
        }
    }

    // MARK: - Navigation

    /// Project indices matching visible sidebar rows (skips collapsed folders).
    func projectIndicesInSidebarOrder() -> [Int] {
        var indices: [Int] = []
        for item in sidebarOrder {
            switch item {
            case .project(let id):
                if let i = projects.firstIndex(where: { $0.id == id }) { indices.append(i) }
            case .folder(let folder):
                guard !folder.isCollapsed else { continue }
                for id in folder.projectIds {
                    if let i = projects.firstIndex(where: { $0.id == id }) { indices.append(i) }
                }
            }
        }
        return indices
    }

    func selectNextProject() {
        let ordered = projectIndicesInSidebarOrder()
        guard !ordered.isEmpty else { return }
        let cur = ordered.firstIndex(of: selectedProjectIndex) ?? -1
        selectProject(at: ordered[(cur + 1) % ordered.count])
    }

    func selectPrevProject() {
        let ordered = projectIndicesInSidebarOrder()
        guard !ordered.isEmpty else { return }
        let cur = ordered.firstIndex(of: selectedProjectIndex) ?? ordered.count
        selectProject(at: ordered[(cur - 1 + ordered.count) % ordered.count])
    }

    func selectProject(byNumber n: Int) {
        let ordered = projectIndicesInSidebarOrder()
        guard n >= 0, n < ordered.count else { return }
        selectProject(at: ordered[n])
    }

    func updateShortcutIndicators(commandHeld: Bool) {
        let ordered = commandHeld ? projectIndicesInSidebarOrder() : []
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

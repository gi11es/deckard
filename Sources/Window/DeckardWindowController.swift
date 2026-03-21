import AppKit
import GhosttyKit
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
    var surfaceView: TerminalNSView
    var name: String
    var isClaude: Bool
    var sessionId: String?
    var badgeState: BadgeState = .none

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
    }

    init(surfaceView: TerminalNSView, name: String, isClaude: Bool) {
        self.id = surfaceView.surfaceId
        self.surfaceView = surfaceView
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

    init(path: String) {
        self.id = UUID()
        self.path = path
        self.name = (path as NSString).lastPathComponent
    }
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
    private let ghosttyApp: DeckardGhosttyApp
    private var projects: [ProjectItem] = []
    private var selectedProjectIndex: Int = -1

    // Theme
    private(set) var currentThemeColors: ThemeColors = .default

    // UI
    private let splitView = CollapsibleSplitView()
    private let sidebarView = NSView()
    private let sidebarStackView = ReorderableStackView()
    private let rightPane = NSView()
    private let tabBar = ReorderableHStackView()  // horizontal tab bar
    private var isRebuildingTabBar = false
    private var needsTabBarRebuild = false
    /// Saved first responder before a rebuild, used to detect and restore focus theft.
    private weak var savedFirstResponder: NSResponder?
    private let terminalContainerView = NSView()
    private let contextProgressBar = NSView()
    private var contextProgressFill = NSView()
    private var contextTimer: Timer?
    private var processMonitorTimer: Timer?
    private var focusHealthTimer: Timer?
    private var currentTerminalView: TerminalNSView?
    /// Opaque overlay shown when a project has no tabs, covering any surfaces underneath.
    private var emptyStateView: NSView?

    private let sidebarDropZone = SidebarDropZone()
    private let openFolderButton = NSButton()
    private let sidebarWidth: CGFloat = 210
    private var sidebarInitialized = false
    private var sidebarWidthBeforeCollapse: CGFloat = 210
    /// Recently closed projects — stored so reopening the same path restores tabs.
    private var recentlyClosedProjects: [ProjectState] = []
    private var isRestoring = false
    /// Tabs in the order they were created (for ProcessMonitor PID matching).
    private var tabCreationOrder: [UUID] = []

    init(ghosttyApp: DeckardGhosttyApp) {
        self.ghosttyApp = ghosttyApp

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

        // Apply theme colors BEFORE setupUI so all chrome uses the right colors
        currentThemeColors = ThemeManager.shared.currentColors

        setupUI()

        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange(_:)),
                                               name: .deckardThemeChanged, object: nil)

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
                wc.window?.makeFirstResponder(tab.surfaceView)
            }
        }

        restoreOrCreateInitial()

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
        // IOSurfaceCreate can re-enter the runloop, and polling during that
        // window can access partially-initialized state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.startProcessMonitor()
        }
        startFocusHealthCheck()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        SessionManager.shared.stopAutosave()
        processMonitorTimer?.invalidate()
        focusHealthTimer?.invalidate()
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
        sidebarView.layer?.backgroundColor = currentThemeColors.sidebarBackground.cgColor

        // Drop zone covers the entire sidebar area below the stack
        sidebarDropZone.translatesAutoresizingMaskIntoConstraints = false
        sidebarDropZone.registerForDraggedTypes([deckardProjectDragType])
        sidebarView.addSubview(sidebarDropZone)

        sidebarStackView.orientation = .vertical
        sidebarStackView.alignment = .leading
        sidebarStackView.spacing = 1
        sidebarStackView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(sidebarStackView)

        // Open folder button at bottom of sidebar
        openFolderButton.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Open Folder")
        openFolderButton.target = self
        openFolderButton.action = #selector(openProjectClicked)
        openFolderButton.bezelStyle = .recessed
        openFolderButton.isBordered = false
        openFolderButton.contentTintColor = currentThemeColors.secondaryText
        openFolderButton.toolTip = shortcutTooltip("Open Folder", for: .openFolder)
        openFolderButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(openFolderButton)

        NSLayoutConstraint.activate([
            sidebarStackView.topAnchor.constraint(equalTo: sidebarView.topAnchor),
            sidebarStackView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarStackView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),

            openFolderButton.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 8),
            openFolderButton.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor, constant: -8),

            sidebarDropZone.topAnchor.constraint(equalTo: sidebarStackView.bottomAnchor),
            sidebarDropZone.bottomAnchor.constraint(equalTo: openFolderButton.topAnchor, constant: -4),
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
        tabBar.layer?.backgroundColor = currentThemeColors.tabBarBackground.cgColor
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

        // Context usage progress bar (1px line at bottom of terminal)
        contextProgressBar.translatesAutoresizingMaskIntoConstraints = false
        contextProgressBar.wantsLayer = true
        contextProgressBar.layer?.backgroundColor = NSColor.clear.cgColor
        contextProgressBar.isHidden = true
        rightPane.addSubview(contextProgressBar)

        contextProgressFill.translatesAutoresizingMaskIntoConstraints = false
        contextProgressFill.wantsLayer = true
        contextProgressFill.layer?.backgroundColor = NSColor(red: 0.4, green: 0.7, blue: 0.4, alpha: 1.0).cgColor
        contextProgressBar.addSubview(contextProgressFill)

        NSLayoutConstraint.activate([
            contextProgressBar.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            contextProgressBar.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            contextProgressBar.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
            contextProgressBar.heightAnchor.constraint(equalToConstant: 1),
            contextProgressFill.leadingAnchor.constraint(equalTo: contextProgressBar.leadingAnchor),
            contextProgressFill.topAnchor.constraint(equalTo: contextProgressBar.topAnchor),
            contextProgressFill.bottomAnchor.constraint(equalTo: contextProgressBar.bottomAnchor),
        ])

        splitView.addArrangedSubview(sidebarView)
        splitView.addArrangedSubview(rightPane)

        // Opaque empty-state overlay — covers all surfaces when a project has no tabs.
        let emptyBg = NSView()
        emptyBg.wantsLayer = true
        emptyBg.layer?.backgroundColor = currentThemeColors.background.cgColor
        emptyBg.translatesAutoresizingMaskIntoConstraints = false
        let welcome = NSTextField(labelWithString: "Press \u{2318}O to open a project")
        welcome.font = .systemFont(ofSize: 16, weight: .light)
        welcome.textColor = currentThemeColors.secondaryText
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
        if let snapshot = recentlyClosedProjects.first(where: { $0.path == path }) {
            recentlyClosedProjects.removeAll { $0.path == path }
            project.name = snapshot.name
            for ts in snapshot.tabs {
                createTabInProject(project, isClaude: ts.isClaude, name: ts.name,
                                   sessionIdToResume: ts.isClaude ? ts.sessionId : nil)
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
        rebuildSidebar()
        selectProject(at: projects.count - 1)
        if !isRestoring { saveState() }
    }

    func closeCurrentProject() {
        guard selectedProjectIndex >= 0, selectedProjectIndex < projects.count else { return }
        closeProject(at: selectedProjectIndex)
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
                                isClaude: tab.isClaude, sessionId: tab.sessionId)
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

        // Destroy all surfaces
        let closedIds = Set(project.tabs.map { $0.id })
        tabCreationOrder.removeAll { closedIds.contains($0) }
        for tab in project.tabs {
            tab.surfaceView.destroySurface()
        }

        projects.remove(at: index)
        rebuildSidebar()

        if projects.isEmpty {
            selectedProjectIndex = -1
            currentTerminalView?.removeFromSuperview()
            currentTerminalView = nil
            rebuildTabBar()
        } else {
            selectProject(at: min(index, projects.count - 1))
        }
        saveState()
    }

    func selectProject(at index: Int) {
        guard index >= 0, index < projects.count else { return }
        selectedProjectIndex = index

        let project = projects[index]

        rebuildTabBar()

        if project.tabs.isEmpty {
            currentTerminalView = nil
            showEmptyState()
        } else {
            // Always clamp for safe array access, even during restore
            let safeIdx = max(0, min(project.selectedTabIndex, project.tabs.count - 1))
            showTab(project.tabs[safeIdx])
        }

        // Show folder path in title bar
        let home = NSHomeDirectory()
        let displayPath = project.path.hasPrefix(home)
            ? "~" + project.path.dropFirst(home.count)
            : project.path
        window?.title = displayPath

        updateSidebarSelection()
    }

    // MARK: - Tab Management (within a project)

    private func createTabInProject(_ project: ProjectItem, isClaude: Bool, name: String? = nil, sessionIdToResume: String? = nil) {
        guard let app = ghosttyApp.app else { return }

        let surfaceView = TerminalNSView()
        let tabName: String
        if let name = name {
            tabName = name
        } else {
            let count = project.tabs.filter { $0.isClaude == isClaude }.count + 1
            let base = isClaude ? "Claude" : "Terminal"
            tabName = "\(base) #\(count)"
        }
        let tab = TabItem(surfaceView: surfaceView, name: tabName, isClaude: isClaude)
        tab.badgeState = isClaude ? .idle : .terminalIdle
        var envVars: [String: String] = [:]
        if isClaude {
            tab.sessionId = sessionIdToResume
            envVars["DECKARD_SESSION_TYPE"] = "claude"
        }

        // Register the shell PID with Deckard via the control socket so
        // ProcessMonitor can match login PIDs to surfaces. The register-pid
        // script registers $$, then execs the trailing command (PID preserved).
        // No /bin/sh -c wrapper needed — avoids shell quoting issues.
        let socketPath = ControlSocket.shared.path
        let sid = surfaceView.surfaceId.uuidString
        let binPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path ?? ""

        // Both tab types start the user's default shell as a login shell.
        // Claude tabs send the claude command as initial input (like typing it).
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let command = "direct:\(binPath)/register-pid \(sid) \(socketPath) \(userShell) -l"
        let initialInput: String?
        if isClaude {
            let extraArgs = UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
            let extraArgsSuffix = extraArgs.isEmpty ? "" : " \(extraArgs)"
            var claudeArgs = extraArgsSuffix
            if let sessionIdToResume {
                let encoded = project.path.replacingOccurrences(of: "/", with: "-")
                let jsonlPath = NSHomeDirectory() + "/.claude/projects/\(encoded)/\(sessionIdToResume).jsonl"
                if FileManager.default.fileExists(atPath: jsonlPath) {
                    claudeArgs = " --resume \(sessionIdToResume)\(extraArgsSuffix)"
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

        DiagnosticLog.shared.log("surface", "createTab: \(isClaude ? "claude" : "terminal") command=\(command)")

        surfaceView.createSurface(
            app: app,
            tabId: tab.id,
            workingDirectory: project.path,
            command: command,
            envVars: envVars,
            initialInput: initialInput
        )

        project.tabs.append(tab)
        tabCreationOrder.append(tab.id)
    }

    /// Guards against overlapping ghostty_surface_new() calls.
    /// DispatchQueue.main.async does NOT provide real serialization —
    /// IOSurfaceCreate re-enters the runloop and processes main-queue blocks.
    /// A background-thread timer is the only reliable cooldown mechanism.
    /// Excess requests are dropped (not queued) to avoid creating tabs
    /// after the user releases the key.
    private var isCreatingTab = false

    func addTabToCurrentProject(isClaude: Bool) {
        guard !isCreatingTab else { return }
        isCreatingTab = true

        guard selectedProjectIndex >= 0, selectedProjectIndex < projects.count else {
            isCreatingTab = false
            return
        }
        let project = projects[selectedProjectIndex]
        createTabInProject(project, isClaude: isClaude)
        project.selectedTabIndex = project.tabs.count - 1
        rebuildTabBar()
        rebuildSidebar()
        showTab(project.tabs[project.selectedTabIndex])
        saveState()

        // Clear via background thread — can't be triggered by
        // IOSurface runloop re-entrance (unlike main-queue blocks).
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
            DispatchQueue.main.async {
                self?.isCreatingTab = false
            }
        }
    }

    func closeCurrentTab() {
        guard let project = currentProject else { return }
        let idx = project.selectedTabIndex
        guard idx >= 0, idx < project.tabs.count else { return }

        let tab = project.tabs[idx]
        tab.surfaceView.destroySurface()
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
            showTab(project.tabs[project.selectedTabIndex])
        }
        saveState()
    }

    func selectTabInProject(at tabIndex: Int) {
        guard let project = currentProject else { return }
        guard tabIndex >= 0, tabIndex < project.tabs.count else { return }
        project.selectedTabIndex = tabIndex
        rebuildTabBar()
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

    private func showTab(_ tab: TabItem) {
        hideEmptyState()

        let view = tab.surfaceView

        // Remove the previous surface view from the hierarchy.
        // Only one Metal surface is in the container at a time — this avoids
        // wasted GPU rendering for occluded surfaces and resource exhaustion
        // during session restore with many tabs.
        if let prev = currentTerminalView, prev !== view {
            prev.removeFromSuperview()
        }

        // Add the new surface view (or re-add if it was previously removed).
        // viewDidMoveToWindow fires on add, which calls updateSurfaceSize()
        // to kick the Metal renderer.
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

        let ok = window?.makeFirstResponder(view) ?? false
        DiagnosticLog.shared.log("focus",
            "showTab: makeFirstResponder=\(ok) surfaceId=\(view.surfaceId)" +
            " frame=\(view.frame) surfaceAlive=\(view.surface != nil)" +
            " wantsLayer=\(view.wantsLayer) hasLayer=\(view.layer != nil)")
        refreshContextBar(for: tab)
    }

    /// Show the empty-state overlay (project has no tabs).
    private func showEmptyState() {
        currentTerminalView?.removeFromSuperview()
        emptyStateView?.isHidden = false
    }

    /// Hide the empty-state overlay (active tab is being shown).
    private func hideEmptyState() {
        emptyStateView?.isHidden = true
    }

    private var progressWidthConstraint: NSLayoutConstraint?

    private func refreshContextBar(for tab: TabItem) {
        contextTimer?.invalidate()
        contextTimer = nil

        if tab.isClaude {
            contextProgressBar.isHidden = false
            updateContextUsage(for: tab)
            contextTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.updateContextUsage(for: tab)
            }
        } else {
            contextProgressBar.isHidden = true
        }
    }

    private func updateContextUsage(for tab: TabItem) {
        guard let sessionId = tab.sessionId,
              let project = currentProject else {
            applyContextUsage(nil)
            return
        }

        let projectPath = project.path
        DispatchQueue.global(qos: .utility).async {
            let usage = ContextMonitor.shared.getUsage(sessionId: sessionId, projectPath: projectPath)
            DispatchQueue.main.async { [weak self] in
                self?.applyContextUsage(usage)
            }
        }
    }

    private func applyContextUsage(_ usage: ContextMonitor.ContextUsage?) {
        guard let usage = usage else {
            progressWidthConstraint?.isActive = false
            progressWidthConstraint = contextProgressFill.widthAnchor.constraint(equalToConstant: 0)
            progressWidthConstraint?.isActive = true
            return
        }

        let fraction = CGFloat(usage.percentage) / 100.0
        let barWidth = contextProgressBar.bounds.width * fraction

        let color: NSColor
        switch Int(usage.percentage) {
        case 0..<50: color = NSColor(red: 0.4, green: 0.7, blue: 0.4, alpha: 1.0)
        case 50..<75: color = .systemYellow
        case 75..<90: color = .systemOrange
        default: color = .systemRed
        }

        contextProgressFill.layer?.backgroundColor = color.cgColor
        progressWidthConstraint?.isActive = false
        progressWidthConstraint = contextProgressFill.widthAnchor.constraint(equalToConstant: barWidth)
        progressWidthConstraint?.isActive = true
    }

    // MARK: - Process Monitor

    private func startFocusHealthCheck() {
        focusHealthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self = self,
                  let view = self.currentTerminalView,
                  view.surface != nil,
                  !view.isHidden,
                  self.window?.isKeyWindow == true else { return }
            if self.window?.firstResponder !== view {
                DiagnosticLog.shared.log("health",
                    "MISMATCH: expected=\(view.surfaceId) actual=\(type(of: self.window?.firstResponder))")
                self.window?.makeFirstResponder(view)
            }
        }
    }

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

    /// Last activity info per surface, used for tooltips.
    private var terminalActivity: [UUID: ProcessMonitor.ActivityInfo] = [:]
    /// Consecutive active poll count per surface — require 2 before showing as active.
    private var terminalActiveStreak: [UUID: Int] = [:]

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

                let newBadge: TabItem.BadgeState = confirmedActive ? .terminalActive : .terminalIdle
                terminalActivity[tab.id] = activity
                if tab.badgeState != newBadge {
                    if newBadge == .terminalActive {
                        DiagnosticLog.shared.log("processmon",
                            "badge → terminalActive: project=\(project.path) tab=\"\(tab.name)\"")
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

    func focusedSurface() -> ghostty_surface_t? {
        guard let project = currentProject else { return nil }
        let idx = project.selectedTabIndex
        guard idx >= 0, idx < project.tabs.count else { return nil }
        return project.tabs[idx].surfaceView.surface
    }

    func forEachSurface(_ body: (ghostty_surface_t) -> Void) {
        for project in projects {
            for tab in project.tabs {
                if let surface = tab.surfaceView.surface {
                    body(surface)
                }
            }
        }
    }

    // MARK: - Theme

    @objc private func themeDidChange(_ notification: Notification) {
        applyThemeColors(ThemeManager.shared.currentColors)
    }

    private func applyThemeColors(_ colors: ThemeColors) {
        currentThemeColors = colors
        window?.backgroundColor = colors.background
        window?.appearance = colors.isDark
            ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        sidebarView.layer?.backgroundColor = colors.sidebarBackground.cgColor
        tabBar.layer?.backgroundColor = colors.tabBarBackground.cgColor
        emptyStateView?.layer?.backgroundColor = colors.background.cgColor
        openFolderButton.contentTintColor = colors.secondaryText
        rebuildSidebar()
        rebuildTabBar()
    }

    func setTitle(_ title: String, forSurface surface: ghostty_surface_t?) {
        guard let surface = surface else { return }
        for project in projects {
            for tab in project.tabs where tab.surfaceView.surface == surface {
                tab.surfaceView.title = title
                return
            }
        }
    }

    func setPwd(_ pwd: String, forSurface surface: ghostty_surface_t?) {
        guard let surface = surface else { return }
        for project in projects {
            for tab in project.tabs where tab.surfaceView.surface == surface {
                tab.surfaceView.pwd = pwd
                return
            }
        }
    }

    func handleSurfaceClosedById(_ surfaceId: UUID) {
        for (pi, project) in projects.enumerated() {
            if let ti = project.tabs.firstIndex(where: { $0.id == surfaceId }) {
                let tab = project.tabs[ti]
                tab.surfaceView.destroySurface()
                tabCreationOrder.removeAll { $0 == tab.id }

                project.tabs.remove(at: ti)

                if project.tabs.isEmpty && pi == selectedProjectIndex {
                    currentTerminalView?.isHidden = true
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
        // Only set the session ID if the tab doesn't already have one.
        // Resumed sessions report a new ID in ~/.claude/sessions/<pid>.json
        // that doesn't correspond to an actual JSONL session file.
        if tab.sessionId == nil || tab.sessionId!.isEmpty {
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
    }

    func updateBadge(forSurfaceId surfaceIdStr: String, state: TabItem.BadgeState) {
        guard let tab = tabForSurfaceId(surfaceIdStr) else { return }
        DiagnosticLog.shared.log("badge",
            "updateBadge: surfaceId=\(surfaceIdStr) state=\(state) currentFR=\(type(of: window?.firstResponder))")
        tab.badgeState = state
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
                        sessionId: tab.sessionId
                    )
                }
            )
        }
        return state
    }

    func saveState() {
        SessionManager.shared.save(captureState())
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

        let selectedIdx = min(max(state.selectedTabIndex, 0), projectStates.count - 1)

        // Phase 1: Create the active project's active tab immediately so the user
        // sees a working terminal right away. Collect remaining tabs for Phase 2.
        var pending: [(project: ProjectItem, tab: ProjectTabState, originalIndex: Int)] = []

        for (i, ps) in projectStates.enumerated() {
            let project = ProjectItem(path: ps.path)
            project.name = ps.name

            let selTab = min(max(ps.selectedTabIndex, 0), max(ps.tabs.count - 1, 0))

            for (t, ts) in ps.tabs.enumerated() {
                if i == selectedIdx && t == selTab {
                    // Create the active tab's surface synchronously
                    createTabInProject(project, isClaude: ts.isClaude, name: ts.name,
                                       sessionIdToResume: ts.isClaude ? ts.sessionId : nil)
                } else {
                    pending.append((project: project, tab: ts, originalIndex: t))
                }
            }

            project.selectedTabIndex = selTab
            projects.append(project)
        }

        // Keep isRestoring = true until Phase 2 finishes, so selectProject
        // won't clamp selectedTabIndex before all tabs are inserted.

        rebuildSidebar()
        if selectedIdx >= 0 && selectedIdx < projects.count {
            selectProject(at: selectedIdx)
        }

        // Phase 2: Create remaining surfaces progressively, one per run loop cycle.
        // Each ghostty_surface_new() takes 3-11ms so the app stays responsive.
        createTabsProgressively(pending)
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

            // Dump tab creation order → PID mapping for diagnostics
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
                           sessionIdToResume: ts.isClaude ? ts.sessionId : nil)

        // Move it from the end to its original position
        if insertAt < project.tabs.count - 1 {
            let tab = project.tabs.removeLast()
            project.tabs.insert(tab, at: min(insertAt, project.tabs.count))
        }

        // Use background-thread timer for genuine serialization.
        // DispatchQueue.main.async fires during IOSurfaceCreate's runloop
        // re-entrance, causing all tabs to be created in a single burst.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) { [self] in
            DispatchQueue.main.async {
                self.createTabsProgressively(Array(remaining.dropFirst()))
            }
        }
    }

    // MARK: - Sidebar (project list)

    func rebuildSidebar() {
        let savedFR = window?.firstResponder
        defer {
            if let terminal = savedFR as? TerminalNSView,
               window?.firstResponder !== terminal {
                DiagnosticLog.shared.log("sidebar",
                    "rebuildSidebar: focus stolen! restoring surfaceId=\(terminal.surfaceId)")
                window?.makeFirstResponder(terminal)
            }
        }
        sidebarStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (i, project) in projects.enumerated() {
            let row = VerticalTabRowView(title: project.name, bold: false, index: i,
                                 target: self, action: #selector(projectRowClicked(_:)))
            row.badgeInfos = project.tabs.filter { $0.badgeState != .none }.map { tab in
                (state: tab.badgeState, name: tab.name, activity: self.terminalActivity[tab.id])
            }
            row.onRename = { [weak self] newName in
                guard let self = self, i < self.projects.count else { return }
                self.projects[i].name = newName
                self.saveState()
            }
            row.onClearName = { [weak self] in
                guard let self = self, i < self.projects.count else { return }
                let defaultName = (self.projects[i].path as NSString).lastPathComponent
                self.projects[i].name = defaultName
                self.rebuildSidebar()
                self.saveState()
            }
            row.onReorder = { [weak self] fromIndex, toIndex in
                self?.reorderProject(from: fromIndex, to: toIndex)
            }
            row.onContextMenu = { [weak self] event in
                guard let self = self, i < self.projects.count else { return nil }
                return self.buildProjectContextMenu(for: self.projects[i])
            }
            sidebarStackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: sidebarStackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: sidebarStackView.trailingAnchor).isActive = true
        }

        sidebarStackView.registerForDraggedTypes([deckardProjectDragType])
        sidebarStackView.onReorder = { [weak self] from, to in
            self?.reorderProject(from: from, to: to)
        }
        sidebarDropZone.onDrop = { [weak self] fromIndex in
            guard let self = self else { return }
            self.reorderProject(from: fromIndex, to: self.projects.count)
        }
        sidebarDropZone.sidebarStackView = sidebarStackView

        updateSidebarSelection()
    }

    private func reorderProject(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < projects.count,
              toIndex >= 0, toIndex <= projects.count else { return }

        let project = projects.remove(at: fromIndex)
        let insertAt = toIndex > fromIndex ? toIndex - 1 : toIndex
        projects.insert(project, at: min(insertAt, projects.count))

        // Update selected index
        if selectedProjectIndex == fromIndex {
            selectedProjectIndex = insertAt
        } else if fromIndex < selectedProjectIndex && insertAt >= selectedProjectIndex {
            selectedProjectIndex -= 1
        } else if fromIndex > selectedProjectIndex && insertAt <= selectedProjectIndex {
            selectedProjectIndex += 1
        }

        rebuildSidebar()
        saveState()
    }

    // MARK: - Project Context Menu

    private class ResumeSessionInfo {
        let project: ProjectItem
        let sessionId: String
        let tabName: String?
        init(project: ProjectItem, sessionId: String, tabName: String?) {
            self.project = project
            self.sessionId = sessionId
            self.tabName = tabName
        }
    }

    private func buildProjectContextMenu(for project: ProjectItem) -> NSMenu {
        let menu = NSMenu()

        let resumeItem = NSMenuItem(title: "Resume Session", action: nil, keyEquivalent: "")
        let resumeSubmenu = NSMenu()

        let sessions = ContextMonitor.shared.listSessions(forProjectPath: project.path)
        let openSessionIds = Set(project.tabs.compactMap { $0.sessionId })
        let resumable = sessions.filter { !openSessionIds.contains($0.sessionId) }

        if resumable.isEmpty {
            let emptyItem = NSMenuItem(title: "No sessions to resume", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            resumeSubmenu.addItem(emptyItem)
        } else {
            let savedNames = SessionManager.shared.loadSessionNames()
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated

            for session in resumable.prefix(50) {
                let timeStr = formatter.localizedString(for: session.modificationDate, relativeTo: Date())
                let savedName = savedNames[session.sessionId]

                let title: String
                if let name = savedName, !name.isEmpty {
                    title = "\(timeStr) \u{2014} \(name)"
                } else if !session.firstUserMessage.isEmpty {
                    let msg = session.firstUserMessage.count > 60
                        ? String(session.firstUserMessage.prefix(60)) + "\u{2026}"
                        : session.firstUserMessage
                    title = "\(timeStr) \u{2014} \(msg)"
                } else {
                    title = timeStr
                }

                let item = NSMenuItem(title: title, action: #selector(resumeSessionMenuAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ResumeSessionInfo(project: project, sessionId: session.sessionId, tabName: savedName)
                resumeSubmenu.addItem(item)
            }
        }

        resumeItem.submenu = resumeSubmenu
        menu.addItem(resumeItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close Folder", action: #selector(closeProjectMenuAction(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.representedObject = project
        menu.addItem(closeItem)

        return menu
    }

    @objc private func closeProjectMenuAction(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? ProjectItem,
              let pi = projects.firstIndex(where: { $0.id == project.id }) else { return }
        closeProject(at: pi)
    }

    @objc private func resumeSessionMenuAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? ResumeSessionInfo else { return }
        let project = info.project
        let sessionId = info.sessionId

        createTabInProject(project, isClaude: true, name: info.tabName, sessionIdToResume: sessionId)
        project.selectedTabIndex = project.tabs.count - 1

        if let pi = projects.firstIndex(where: { $0.id == project.id }) {
            if pi == selectedProjectIndex {
                rebuildTabBar()
                showTab(project.tabs[project.selectedTabIndex])
            } else {
                selectProject(at: pi)
            }
        }
        saveState()
    }

    private func updateSidebarSelection() {
        for (i, view) in sidebarStackView.arrangedSubviews.enumerated() {
            if let row = view as? VerticalTabRowView {
                row.isSelected = (i == selectedProjectIndex)
            }
        }
    }

    @objc private func openProjectClicked() {
        AppDelegate.shared?.openProjectPicker()
    }

    @objc private func projectRowClicked(_ sender: VerticalTabRowView) {
        selectProject(at: sender.index)
    }

    // MARK: - Tab Bar (horizontal tabs within selected project)

    private var isTabEditing: Bool {
        tabBar.arrangedSubviews.contains { ($0 as? HorizontalTabView)?.isEditing == true }
    }

    func rebuildTabBar() {
        guard !isRebuildingTabBar else { return }
        if isTabEditing {
            needsTabBarRebuild = true
            return
        }
        isRebuildingTabBar = true
        defer {
            isRebuildingTabBar = false
            // Restore focus if the rebuild stole it from the terminal
            if let terminal = savedFirstResponder as? TerminalNSView,
               window?.firstResponder !== terminal {
                DiagnosticLog.shared.log("tabbar",
                    "rebuildTabBar: focus stolen! restoring surfaceId=\(terminal.surfaceId)")
                window?.makeFirstResponder(terminal)
            }
            savedFirstResponder = nil
        }
        savedFirstResponder = window?.firstResponder

        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let project = currentProject else { return }

        for (i, tab) in project.tabs.enumerated() {
            let isSelected = (i == project.selectedTabIndex)
            let title = " \(tab.name) "

            let tabView = HorizontalTabView(
                displayTitle: title,
                editableName: tab.name,
                isClaude: tab.isClaude,
                badgeState: tab.badgeState,
                activity: terminalActivity[tab.id],
                isSelected: isSelected,
                index: i,
                target: self,
                clickAction: #selector(tabBarClicked(_:))
            )
            tabView.onRename = { [weak self] newName in
                guard let self = self, let project = self.currentProject,
                      i < project.tabs.count else { return }
                let tab = project.tabs[i]
                tab.name = newName
                if let sid = tab.sessionId, !sid.isEmpty {
                    SessionManager.shared.saveSessionName(sessionId: sid, name: newName)
                }
                self.rebuildTabBar()
                self.saveState()
            }
            tabView.onClearName = { [weak self] in
                guard let self = self, let project = self.currentProject,
                      i < project.tabs.count else { return }
                let tab = project.tabs[i]
                let base = tab.isClaude ? "Claude" : "Terminal"
                let sameType = project.tabs.filter { $0.isClaude == tab.isClaude }
                tab.name = sameType.count <= 1 ? base : "\(base) #\(i + 1)"
                self.rebuildTabBar()
                self.saveState()
            }
            tabView.onEditingFinished = { [weak self] in
                guard let self = self, self.needsTabBarRebuild else { return }
                self.needsTabBarRebuild = false
                self.rebuildTabBar()
            }
            tabBar.addArrangedSubview(tabView)
        }

        // Set up drag-to-reorder
        tabBar.tabCount = project.tabs.count
        tabBar.registerForDraggedTypes([deckardTabDragType])
        tabBar.onReorder = { [weak self] from, to in
            self?.reorderTab(from: from, to: to)
        }

        // Add "+" button
        let addButton = AddTabButton(
            leftClickAction: { [weak self] in self?.addTabToCurrentProject(isClaude: true) },
            rightClickAction: { [weak self] in self?.addTabToCurrentProject(isClaude: false) }
        )
        tabBar.addArrangedSubview(addButton)

        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabBar.addArrangedSubview(spacer)
    }

    private func reorderTab(from fromIndex: Int, to toIndex: Int) {
        guard let project = currentProject else { return }
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < project.tabs.count,
              toIndex >= 0, toIndex <= project.tabs.count else { return }

        let tab = project.tabs.remove(at: fromIndex)
        let insertAt = toIndex > fromIndex ? toIndex - 1 : toIndex
        project.tabs.insert(tab, at: min(insertAt, project.tabs.count))

        if project.selectedTabIndex == fromIndex {
            project.selectedTabIndex = insertAt
        } else if fromIndex < project.selectedTabIndex && insertAt >= project.selectedTabIndex {
            project.selectedTabIndex -= 1
        } else if fromIndex > project.selectedTabIndex && insertAt <= project.selectedTabIndex {
            project.selectedTabIndex += 1
        }

        rebuildTabBar()
        rebuildSidebar()
        saveState()
    }

    @objc private func tabBarClicked(_ sender: HorizontalTabView) {
        selectTabInProject(at: sender.index)
    }

    @objc private func tabBarCloseClicked(_ sender: NSButton) {
        guard let project = currentProject else { return }
        let idx = sender.tag
        guard idx >= 0, idx < project.tabs.count else { return }

        let tab = project.tabs[idx]
        tab.surfaceView.destroySurface()
        tabCreationOrder.removeAll { $0 == tab.id }

        project.tabs.remove(at: idx)

        if project.tabs.isEmpty {
            currentTerminalView = nil
            showEmptyState()
            rebuildTabBar()
            rebuildSidebar()
        } else {
            project.selectedTabIndex = min(idx, project.tabs.count - 1)
            rebuildTabBar()
            rebuildSidebar()
            showTab(project.tabs[project.selectedTabIndex])
        }
        saveState()
    }


    // MARK: - Navigation

    func selectNextProject() {
        guard !projects.isEmpty else { return }
        selectProject(at: (selectedProjectIndex + 1) % projects.count)
    }

    func selectPrevProject() {
        guard !projects.isEmpty else { return }
        selectProject(at: (selectedProjectIndex - 1 + projects.count) % projects.count)
    }

    func selectProject(byNumber n: Int) {
        if n >= 0, n < projects.count {
            selectProject(at: n)
        }
    }
}

// MARK: - VerticalTabRowView

class VerticalTabRowView: NSView, NSTextFieldDelegate, NSDraggingSource {
    var title: String {
        didSet { label.stringValue = title }
    }
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    /// Badge info for each Claude tab in this project, shown as right-aligned dots.
    var badgeInfos: [(state: TabItem.BadgeState, name: String, activity: ProcessMonitor.ActivityInfo?)] = [] {
        didSet { updateBadgeDots() }
    }
    var onRename: ((String) -> Void)?
    var onClearName: (() -> Void)?
    var onReorder: ((Int, Int) -> Void)?
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    let index: Int
    private let label: NSTextField
    private let badgeContainer: NSStackView
    private weak var target: AnyObject?
    private let action: Selector
    private var dragStartPoint: NSPoint?

    init(title: String, bold: Bool, index: Int, target: AnyObject, action: Selector) {
        self.title = title
        self.index = index
        self.target = target
        self.action = action

        label = NSTextField(labelWithString: title)
        label.font = bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        label.textColor = ThemeManager.shared.currentColors.primaryText
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        badgeContainer = NSStackView()
        badgeContainer.orientation = .horizontal
        badgeContainer.spacing = 3
        badgeContainer.setContentHuggingPriority(.required, for: .horizontal)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.toolTip = shortcutTooltip("Close Folder", for: .closeFolder)
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(badgeContainer)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.leadingAnchor, constant: -4),
            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            ThemeManager.shared.currentColors.selectedBackground.setFill()
            bounds.fill()
        }
    }


    private func updateBadgeDots() {
        badgeContainer.arrangedSubviews.forEach {
            $0.layer?.removeAllAnimations()
            $0.removeFromSuperview()
        }
        for info in badgeInfos where info.state != .none {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = Self.colorForBadge(info.state).cgColor
            dot.toolTip = "\(info.name): \(Self.tooltipForBadge(info.state, activity: info.activity))"
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
            ])
            if SettingsWindowController.isBadgeAnimated(info.state) {
                Self.addPulseAnimation(to: dot)
            }
            badgeContainer.addArrangedSubview(dot)
        }
    }

    static func addPulseAnimation(to view: NSView) {
        guard let layer = view.layer else { return }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.3
        anim.duration = 1.2
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(anim, forKey: "pulse")
    }

    static func tooltipForBadge(_ state: TabItem.BadgeState, activity: ProcessMonitor.ActivityInfo? = nil) -> String {
        switch state {
        case .none: return ""
        case .idle: return "Idle"
        case .thinking: return "Thinking..."
        case .waitingForInput: return "Waiting for input"
        case .needsPermission: return "Needs permission"
        case .error: return "Error"
        case .terminalIdle: return "Idle"
        case .terminalActive: return activity?.description ?? "Running"
        case .terminalError: return "Error"
        }
    }

    static let defaultBadgeColors: [TabItem.BadgeState: NSColor] = [
        .idle: .systemGray,
        .thinking: NSColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1.0),
        .waitingForInput: NSColor(red: 0.65, green: 0.4, blue: 0.9, alpha: 1.0),
        .needsPermission: .systemOrange,
        .error: .systemRed,
        .terminalIdle: NSColor(red: 0.35, green: 0.55, blue: 0.54, alpha: 1.0),
        .terminalActive: NSColor(red: 0.45, green: 0.72, blue: 0.71, alpha: 1.0),
        .terminalError: NSColor(red: 0.85, green: 0.3, blue: 0.3, alpha: 1.0),
    ]

    static func colorForBadge(_ state: TabItem.BadgeState) -> NSColor {
        if state == .none { return .clear }
        if let hex = UserDefaults.standard.string(forKey: "badgeColor.\(state.rawValue)"),
           let color = NSColor.fromHex(hex) {
            return color
        }
        return defaultBadgeColors[state] ?? .systemGray
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            startEditing()
        } else {
            dragStartPoint = convert(event.locationInWindow, from: nil)
            _ = target?.perform(action, with: self)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = onContextMenu?(event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        let distance = abs(current.y - start.y)
        guard distance > 5 else { return }

        dragStartPoint = nil

        let pb = NSPasteboardItem()
        pb.setString("\(index)", forType: deckardProjectDragType)
        let item = NSDraggingItem(pasteboardWriter: pb)
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }


    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            layer?.render(in: ctx)
        }
        image.unlockFocus()
        return image
    }

    private func startEditing() {
        label.isEditable = true
        label.isSelectable = true
        label.focusRingType = .none
        label.delegate = self
        label.becomeFirstResponder()
        label.currentEditor()?.selectAll(nil)
    }

    private func finishEditing() {
        label.isEditable = false
        label.isSelectable = false
        let newName = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if newName.isEmpty {
            // Reset to default name
            onClearName?()
        } else if newName != title {
            title = newName
            onRename?(newName)
        } else {
            label.stringValue = title
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            finishEditing()
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            label.stringValue = title
            label.isEditable = false
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

// MARK: - HorizontalTabView

/// A single tab in the horizontal tab bar.
let deckardTabDragType = NSPasteboard.PasteboardType("com.deckard.tab-reorder")

class HorizontalTabView: NSView, NSTextFieldDelegate, NSDraggingSource {
    override var mouseDownCanMoveWindow: Bool { false }
    let index: Int
    private let label: NSTextField
    private weak var target: AnyObject?
    private let clickAction: Selector
    private var isSelected: Bool
    var onRename: ((String) -> Void)?
    var onClearName: (() -> Void)?
    var onEditingFinished: (() -> Void)?
    private var rawName: String

    private var displayTitle: String
    private var editWidthConstraint: NSLayoutConstraint?

    private var badgeDot: NSView?

    init(displayTitle: String, editableName: String, isClaude: Bool = false,
         badgeState: TabItem.BadgeState = .none,
         activity: ProcessMonitor.ActivityInfo? = nil,
         isSelected: Bool, index: Int,
         target: AnyObject, clickAction: Selector) {
        self.index = index
        self.isSelected = isSelected
        self.target = target
        self.clickAction = clickAction
        self.rawName = editableName
        self.displayTitle = displayTitle

        label = NSTextField(labelWithString: displayTitle)
        label.font = .systemFont(ofSize: 12)
        let tc = ThemeManager.shared.currentColors
        label.textColor = isSelected ? tc.primaryText : tc.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Badge dot — positioned on the right by layout constraints below
        if badgeState != .none {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = VerticalTabRowView.colorForBadge(badgeState).cgColor
            dot.toolTip = VerticalTabRowView.tooltipForBadge(badgeState, activity: activity)
            dot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            if SettingsWindowController.isBadgeAnimated(badgeState) {
                VerticalTabRowView.addPulseAnimation(to: dot)
            }
            badgeDot = dot
        }

        label.translatesAutoresizingMaskIntoConstraints = false
        label.toolTip = shortcutTooltip("Close Tab", for: .closeTab)
        addSubview(label)

        // Layout: [label] [badge]
        var constraints = [
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]

        if let dot = badgeDot {
            constraints.append(dot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 5))
            constraints.append(dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6))
        } else {
            constraints.append(label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6))
        }

        NSLayoutConstraint.activate(constraints)

        if isSelected {
            layer?.backgroundColor = ThemeManager.shared.currentColors.selectedBackground.cgColor
        }

    }

    required init?(coder: NSCoder) { fatalError() }

    private var dragStartPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            startEditing()
        } else {
            dragStartPoint = convert(event.locationInWindow, from: nil)
            // Select on mouseUp so the view isn't destroyed before mouseDragged fires
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartPoint != nil else { return }
        dragStartPoint = nil
        _ = target?.perform(clickAction, with: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard abs(current.x - start.x) > 5 else { return }

        dragStartPoint = nil
        let pb = NSPasteboardItem()
        pb.setString("\(index)", forType: deckardTabDragType)
        let item = NSDraggingItem(pasteboardWriter: pb)
        let snapshot = NSImage(size: bounds.size)
        snapshot.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext { layer?.render(in: ctx) }
        snapshot.unlockFocus()
        item.setDraggingFrame(bounds, contents: snapshot)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    private func startEditing() {
        isEditing = true
        let w = max(label.fittingSize.width + 16, 80)
        editWidthConstraint = label.widthAnchor.constraint(equalToConstant: w)
        editWidthConstraint?.isActive = true

        label.isEditable = true
        label.isSelectable = true
        label.isBezeled = false
        label.drawsBackground = false
        label.focusRingType = .none
        label.stringValue = rawName
        label.delegate = self
        label.becomeFirstResponder()
        label.currentEditor()?.selectAll(nil)
    }

    private(set) var isEditing = false

    private func finishEditing() {
        guard isEditing else { return }
        isEditing = false
        editWidthConstraint?.isActive = false
        editWidthConstraint = nil
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        let newName = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if newName.isEmpty {
            onClearName?()  // reset to default name
        } else if newName != rawName {
            rawName = newName
            onRename?(newName)
        } else {
            label.stringValue = displayTitle
        }
        onEditingFinished?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(insertNewline(_:)) {
            finishEditing()
            window?.makeFirstResponder(nil)
            return true
        }
        if sel == #selector(cancelOperation(_:)) {
            isEditing = false
            label.stringValue = displayTitle
            label.isEditable = false
            label.isSelectable = false
            window?.makeFirstResponder(nil)
            onEditingFinished?()
            return true
        }
        return false
    }

}

// MARK: - AddTabButton

/// + button: left-click adds Claude tab, right-click adds terminal tab.
class AddTabButton: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    private let leftClickAction: () -> Void
    private let rightClickAction: () -> Void
    private let label: NSTextField

    init(leftClickAction: @escaping () -> Void, rightClickAction: @escaping () -> Void) {
        self.leftClickAction = leftClickAction
        self.rightClickAction = rightClickAction
        label = NSTextField(labelWithString: "  +")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = ThemeManager.shared.currentColors.secondaryText
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = shortcutTooltip("New Claude tab", for: .newClaudeTab)
            + "\nShift-click or right-click: " + shortcutTooltip("new Terminal", for: .newTerminalTab)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) {
            rightClickAction()  // Shift+click opens terminal tab
        } else {
            leftClickAction()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        rightClickAction()
    }
}

// MARK: - ReorderableStackView

/// NSStackView subclass that accepts drops for reordering.
class ReorderableStackView: NSStackView {
    var onReorder: ((Int, Int) -> Void)?

    private let dropIndicator: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = ThemeManager.shared.currentColors.foreground.withAlphaComponent(0.4).cgColor
        v.isHidden = true
        return v
    }()
    private var currentDropIndex: Int = -1

    private func dropIndex(for sender: NSDraggingInfo) -> Int {
        let location = convert(sender.draggingLocation, from: nil)
        for (i, view) in arrangedSubviews.enumerated() {
            if location.y > view.frame.midY {
                return i
            }
        }
        return arrangedSubviews.count
    }

    private func showIndicator(at index: Int) {
        guard index != currentDropIndex else { return }
        currentDropIndex = index

        // Use frame-based positioning (no autolayout) for simplicity
        if dropIndicator.superview !== self {
            dropIndicator.removeFromSuperview()
            addSubview(dropIndicator)
        }
        dropIndicator.isHidden = false

        let yPos: CGFloat
        if index < arrangedSubviews.count {
            yPos = arrangedSubviews[index].frame.maxY - 1
        } else if let last = arrangedSubviews.last {
            yPos = last.frame.minY - 1
        } else {
            yPos = bounds.maxY - 1
        }
        dropIndicator.frame = NSRect(x: 8, y: yPos, width: bounds.width - 16, height: 2)
    }

    func showIndicatorAtEnd() {
        showIndicator(at: arrangedSubviews.count)
    }

    func hideIndicator() {
        dropIndicator.isHidden = true
        currentDropIndex = -1
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(deckardProjectDragType) == true else { return [] }
        showIndicator(at: dropIndex(for: sender))
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(deckardProjectDragType) == true else { return [] }
        showIndicator(at: dropIndex(for: sender))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideIndicator()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideIndicator()
        guard let fromStr = sender.draggingPasteboard.string(forType: deckardProjectDragType),
              let fromIndex = Int(fromStr) else { return false }

        let toIndex = dropIndex(for: sender)
        if toIndex != fromIndex {
            onReorder?(fromIndex, toIndex)
        }
        return true
    }
}

// MARK: - ReorderableHStackView

/// Horizontal stack view that accepts drops for tab reordering.
class ReorderableHStackView: NSStackView {
    override var mouseDownCanMoveWindow: Bool { false }
    var onReorder: ((Int, Int) -> Void)?
    var tabCount: Int = 0  // number of tab views (excluding + button and spacer)

    private let dropIndicator: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = ThemeManager.shared.currentColors.foreground.withAlphaComponent(0.4).cgColor
        v.isHidden = true
        return v
    }()
    private var currentDropIndex: Int = -1

    private func dropIndex(for sender: NSDraggingInfo) -> Int {
        let location = convert(sender.draggingLocation, from: nil)
        for i in 0..<tabCount {
            guard i < arrangedSubviews.count else { break }
            let view = arrangedSubviews[i]
            if location.x < view.frame.midX {
                return i
            }
        }
        return tabCount
    }

    private func showIndicator(at index: Int) {
        guard index != currentDropIndex else { return }
        currentDropIndex = index

        if dropIndicator.superview !== self {
            dropIndicator.removeFromSuperview()
            addSubview(dropIndicator)
        }
        dropIndicator.isHidden = false

        let xPos: CGFloat
        if index < tabCount, index < arrangedSubviews.count {
            xPos = arrangedSubviews[index].frame.minX - 1
        } else if tabCount > 0, tabCount - 1 < arrangedSubviews.count {
            xPos = arrangedSubviews[tabCount - 1].frame.maxX + 1
        } else {
            xPos = 0
        }
        dropIndicator.frame = NSRect(x: xPos, y: 4, width: 2, height: bounds.height - 8)
    }

    func hideIndicator() {
        dropIndicator.isHidden = true
        currentDropIndex = -1
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(deckardTabDragType) == true else { return [] }
        showIndicator(at: dropIndex(for: sender))
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(deckardTabDragType) == true else { return [] }
        showIndicator(at: dropIndex(for: sender))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideIndicator()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideIndicator()
        guard let fromStr = sender.draggingPasteboard.string(forType: deckardTabDragType),
              let fromIndex = Int(fromStr) else { return false }

        let toIndex = dropIndex(for: sender)
        if toIndex != fromIndex {
            onReorder?(fromIndex, toIndex)
        }
        return true
    }
}

// MARK: - SidebarDropZone

/// Covers the empty area below the project list; dropping here moves to end.
class SidebarDropZone: NSView {
    var onDrop: ((Int) -> Void)?
    weak var sidebarStackView: ReorderableStackView?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(deckardProjectDragType) == true else { return [] }
        sidebarStackView?.showIndicatorAtEnd()
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(deckardProjectDragType) == true else { return [] }
        sidebarStackView?.showIndicatorAtEnd()
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        sidebarStackView?.hideIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        sidebarStackView?.hideIndicator()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sidebarStackView?.hideIndicator()
        guard let fromStr = sender.draggingPasteboard.string(forType: deckardProjectDragType),
              let fromIndex = Int(fromStr) else { return false }
        onDrop?(fromIndex)
        return true
    }
}


extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

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

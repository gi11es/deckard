import AppKit
import GhosttyKit

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

class DeckardWindowController: NSWindowController, NSSplitViewDelegate {
    private let ghosttyApp: DeckardGhosttyApp
    private var projects: [ProjectItem] = []
    private var selectedProjectIndex: Int = -1

    // UI
    private let splitView = NSSplitView()
    private let sidebarView = NSView()
    private let sidebarStackView = ReorderableStackView()
    private let rightPane = NSView()
    private let tabBar = NSStackView()          // horizontal tab bar
    private let terminalContainerView = NSView()
    private var currentTerminalView: TerminalNSView?
    private var welcomeLabel: NSTextField?

    private let sidebarWidth: CGFloat = 210
    private var sidebarInitialized = false
    private var startupOverlay: NSView?
    /// Recently closed projects — stored so reopening the same path restores tabs.
    private var recentlyClosedProjects: [ProjectState] = []
    private var isRestoring = false

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
        window.backgroundColor = ghosttyApp.defaultBackgroundColor
        window.tabbingMode = .disallowed

        // Extend content into the title bar
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)

        super.init(window: window)

        window.setFrameAutosaveName("DeckardMainWindow")
        if !window.setFrameUsingName("DeckardMainWindow") {
            window.center()
        }

        setupUI()

        // Startup overlay — removed when the shell finishes initializing
        // (detected by the clear command completing, which triggers a title/pwd change)
        let startupOverlay = NSView()
        startupOverlay.wantsLayer = true
        startupOverlay.layer?.backgroundColor = ghosttyApp.defaultBackgroundColor.cgColor
        startupOverlay.layer?.zPosition = 9999
        startupOverlay.translatesAutoresizingMaskIntoConstraints = false
        terminalContainerView.addSubview(startupOverlay)
        self.startupOverlay = startupOverlay
        NSLayoutConstraint.activate([
            startupOverlay.topAnchor.constraint(equalTo: terminalContainerView.topAnchor),
            startupOverlay.bottomAnchor.constraint(equalTo: terminalContainerView.bottomAnchor),
            startupOverlay.leadingAnchor.constraint(equalTo: terminalContainerView.leadingAnchor),
            startupOverlay.trailingAnchor.constraint(equalTo: terminalContainerView.trailingAnchor),
        ])
        // Safety fallback in case signal never comes
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.dismissStartupOverlay()
        }

        restoreOrCreateInitial()

        // If no projects after restore, auto-show the project picker
        if projects.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AppDelegate.shared?.openProjectPicker()
            }
        }

        SessionManager.shared.startAutosave { [weak self] in
            self?.captureState() ?? DeckardState()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { SessionManager.shared.stopAutosave() }

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
        sidebarView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor

        sidebarStackView.orientation = .vertical
        sidebarStackView.alignment = .leading
        sidebarStackView.spacing = 1
        sidebarStackView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(sidebarStackView)

        // Open project button in the top-left area (next to traffic lights)
        let openButton = NSButton(image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Open Folder")!, target: self, action: #selector(openProjectClicked))
        openButton.bezelStyle = .recessed
        openButton.isBordered = false
        openButton.contentTintColor = .secondaryLabelColor
        openButton.toolTip = "Open Folder (\u{2318}O)"
        openButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(openButton)

        NSLayoutConstraint.activate([
            openButton.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 4),
            openButton.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -6),
            openButton.widthAnchor.constraint(equalToConstant: 24),
            openButton.heightAnchor.constraint(equalToConstant: 24),

            sidebarStackView.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 28),
            sidebarStackView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarStackView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
        ])

        // Right pane: tab bar + terminal
        rightPane.translatesAutoresizingMaskIntoConstraints = false

        tabBar.orientation = .horizontal
        tabBar.alignment = .centerY
        tabBar.spacing = 0
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.8).cgColor
        rightPane.addSubview(tabBar)

        terminalContainerView.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(terminalContainerView)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: rightPane.topAnchor, constant: 0),
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

        // Welcome message for empty state
        let welcome = NSTextField(labelWithString: "Press \u{2318}O to open a project")
        welcome.font = .systemFont(ofSize: 16, weight: .light)
        welcome.textColor = .secondaryLabelColor
        welcome.alignment = .center
        welcome.translatesAutoresizingMaskIntoConstraints = false
        terminalContainerView.addSubview(welcome)
        NSLayoutConstraint.activate([
            welcome.centerXAnchor.constraint(equalTo: terminalContainerView.centerXAnchor),
            welcome.centerYAnchor.constraint(equalTo: terminalContainerView.centerYAnchor),
        ])
        self.welcomeLabel = welcome

        // Full-width 1px divider below the title bar / tab bar area
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        contentView.addSubview(divider)

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])

        sidebarView.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        DispatchQueue.main.async { [self] in
            let saved = CGFloat(UserDefaults.standard.double(forKey: "sidebarWidth"))
            splitView.setPosition(saved > 80 ? saved : sidebarWidth, ofDividerAt: 0)
            sidebarInitialized = true
        }

        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { 80 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { splitView.bounds.width * 0.5 }
    func splitView(_ splitView: NSSplitView, canCollapseSubview s: NSView) -> Bool { false }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard sidebarInitialized, sidebarView.frame.width > 0 else { return }
        UserDefaults.standard.set(Double(sidebarView.frame.width), forKey: "sidebarWidth")
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

        // Destroy all surfaces
        for tab in project.tabs {
            tab.surfaceView.destroySurface()
            tab.surfaceView.removeFromSuperview()
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
        rebuildTabBar()

        let project = projects[index]
        if project.selectedTabIndex >= 0, project.selectedTabIndex < project.tabs.count {
            showTab(project.tabs[project.selectedTabIndex])
        }

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
        if isClaude {
            tab.badgeState = .idle
        }

        var envVars: [String: String] = [:]
        if isClaude {
            tab.sessionId = sessionIdToResume
            envVars["DECKARD_SESSION_TYPE"] = "claude"
        }

        let initialInput: String?
        if isClaude {
            let prefix = "stty -echo; export PATH=\"$DECKARD_BIN_DIR:$PATH\"; clear; stty echo; "
            let extraArgs = UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
            let extraArgsSuffix = extraArgs.isEmpty ? "" : " \(extraArgs)"
            if let sid = sessionIdToResume {
                initialInput = "\(prefix)claude --resume \(sid)\(extraArgsSuffix)\n"
            } else {
                initialInput = "\(prefix)claude\(extraArgsSuffix)\n"
            }
        } else {
            initialInput = "stty -echo; clear; stty echo\n"
        }

        surfaceView.needsOverlay = true  // showTab will add a covering overlay

        surfaceView.createSurface(
            app: app,
            tabId: tab.id,
            workingDirectory: project.path,
            command: nil,
            envVars: envVars,
            initialInput: initialInput
        )

        project.tabs.append(tab)
    }

    func addTabToCurrentProject(isClaude: Bool) {
        guard selectedProjectIndex >= 0, selectedProjectIndex < projects.count else { return }
        let project = projects[selectedProjectIndex]
        createTabInProject(project, isClaude: isClaude)
        project.selectedTabIndex = project.tabs.count - 1
        rebuildTabBar()
        showTab(project.tabs[project.selectedTabIndex])
        saveState()
    }

    func closeCurrentTab() {
        guard let project = currentProject else { return }
        let idx = project.selectedTabIndex
        guard idx >= 0, idx < project.tabs.count else { return }

        let tab = project.tabs[idx]
        tab.surfaceView.destroySurface()
        tab.surfaceView.removeFromSuperview()
        project.tabs.remove(at: idx)

        if project.tabs.isEmpty {
            // Close the whole project if no tabs left
            if let pi = projects.firstIndex(where: { $0.id == project.id }) {
                closeProject(at: pi)
            }
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

    func duplicateCurrentTab() {
        guard let project = currentProject else { return }
        guard project.selectedTabIndex >= 0, project.selectedTabIndex < project.tabs.count else { return }
        let current = project.tabs[project.selectedTabIndex]
        addTabToCurrentProject(isClaude: current.isClaude)
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

    private var currentOverlay: NSView?

    private func showTab(_ tab: TabItem) {
        welcomeLabel?.isHidden = true

        // Remove previous overlay and terminal
        currentOverlay?.removeFromSuperview()
        currentOverlay = nil
        currentTerminalView?.removeFromSuperview()

        let view = tab.surfaceView
        view.translatesAutoresizingMaskIntoConstraints = false

        // Add surface view first (bottom)
        terminalContainerView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: terminalContainerView.topAnchor),
            view.bottomAnchor.constraint(equalTo: terminalContainerView.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: terminalContainerView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: terminalContainerView.trailingAnchor),
        ])
        currentTerminalView = view

        // Add opaque overlay on top if surface isn't ready yet
        if view.needsOverlay {
            let overlay = NSView()
            overlay.wantsLayer = true
            overlay.layer?.backgroundColor = ghosttyApp.defaultBackgroundColor.cgColor
            overlay.translatesAutoresizingMaskIntoConstraints = false
            terminalContainerView.addSubview(overlay, positioned: .above, relativeTo: view)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: terminalContainerView.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: terminalContainerView.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: terminalContainerView.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: terminalContainerView.trailingAnchor),
            ])
            currentOverlay = overlay
            // Safety fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self, weak overlay] in
                overlay?.removeFromSuperview()
                if self?.currentOverlay === overlay { self?.currentOverlay = nil }
            }
        }

        window?.makeFirstResponder(view)
    }

    func focusedSurface() -> ghostty_surface_t? {
        guard let project = currentProject else { return nil }
        let idx = project.selectedTabIndex
        guard idx >= 0, idx < project.tabs.count else { return nil }
        return project.tabs[idx].surfaceView.surface
    }

    // MARK: - Surface Callbacks

    func dismissStartupOverlay() {
        guard let overlay = startupOverlay else { return }
        startupOverlay = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            overlay.animator().alphaValue = 0
        }, completionHandler: {
            overlay.removeFromSuperview()
        })
    }

    private func revealSurface(_ view: TerminalNSView) {
        view.needsOverlay = false
        guard let overlay = currentOverlay, view === currentTerminalView else { return }
        currentOverlay = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            overlay.animator().alphaValue = 0
        }, completionHandler: {
            overlay.removeFromSuperview()
        })
    }

    func setTitle(_ title: String, forSurface surface: ghostty_surface_t?) {
        dismissStartupOverlay()
        guard let surface = surface else { return }
        for project in projects {
            for tab in project.tabs where tab.surfaceView.surface == surface {
                tab.surfaceView.title = title
                revealSurface(tab.surfaceView)
                return
            }
        }
    }

    func setPwd(_ pwd: String, forSurface surface: ghostty_surface_t?) {
        dismissStartupOverlay()
        guard let surface = surface else { return }
        for project in projects {
            for tab in project.tabs where tab.surfaceView.surface == surface {
                tab.surfaceView.pwd = pwd
                revealSurface(tab.surfaceView)
                return
            }
        }
    }

    func handleSurfaceClosedById(_ surfaceId: UUID) {
        for (pi, project) in projects.enumerated() {
            if let ti = project.tabs.firstIndex(where: { $0.id == surfaceId }) {
                let tab = project.tabs[ti]
                tab.surfaceView.destroySurface()
                tab.surfaceView.removeFromSuperview()
                project.tabs.remove(at: ti)

                if project.tabs.isEmpty {
                    closeProject(at: pi)
                } else if pi == selectedProjectIndex {
                    project.selectedTabIndex = min(project.selectedTabIndex, project.tabs.count - 1)
                    rebuildTabBar()
                    rebuildSidebar()
                    showTab(project.tabs[project.selectedTabIndex])
                } else {
                    rebuildSidebar()
                }
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
            saveState()
        }
    }

    func updateBadge(forSurfaceId surfaceIdStr: String, state: TabItem.BadgeState) {
        guard let tab = tabForSurfaceId(surfaceIdStr) else { return }
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
            return  // Nothing to restore — user will use Cmd+T to open projects
        }

        isRestoring = true

        for ps in projectStates {
            let project = ProjectItem(path: ps.path)
            project.name = ps.name  // restore custom name if renamed

            for ts in ps.tabs {
                createTabInProject(project, isClaude: ts.isClaude, name: ts.name,
                                   sessionIdToResume: ts.isClaude ? ts.sessionId : nil)
            }

            if project.tabs.isEmpty {
                // Restore with defaults if tabs were lost
                let config = DefaultTabConfig.current
                for entry in config.entries {
                    createTabInProject(project, isClaude: entry.isClaude, name: entry.name)
                }
            }

            project.selectedTabIndex = min(ps.selectedTabIndex, project.tabs.count - 1)
            projects.append(project)
        }

        isRestoring = false

        rebuildSidebar()
        let idx = min(state.selectedTabIndex, projects.count - 1)
        if idx >= 0 {
            selectProject(at: idx)
        }
        saveState()
    }

    // MARK: - Sidebar (project list)

    private func rebuildSidebar() {
        sidebarStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (i, project) in projects.enumerated() {
            let row = TabRowView(title: project.name, bold: false, index: i,
                                 target: self, action: #selector(projectRowClicked(_:)))
            row.badgeInfos = project.tabs.filter { $0.isClaude }.map { (state: $0.badgeState, name: $0.name) }
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
            row.onClose = { [weak self] in
                self?.closeProject(at: i)
            }
            row.onReorder = { [weak self] fromIndex, toIndex in
                self?.reorderProject(from: fromIndex, to: toIndex)
            }
            sidebarStackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: sidebarStackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: sidebarStackView.trailingAnchor).isActive = true
        }

        sidebarStackView.registerForDraggedTypes([deckardProjectDragType])
        sidebarView.registerForDraggedTypes([deckardProjectDragType])
        sidebarStackView.onReorder = { [weak self] from, to in
            self?.reorderProject(from: from, to: to)
        }

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

    private func updateSidebarSelection() {
        for (i, view) in sidebarStackView.arrangedSubviews.enumerated() {
            if let row = view as? TabRowView {
                row.isSelected = (i == selectedProjectIndex)
            }
        }
    }

    @objc private func openProjectClicked() {
        AppDelegate.shared?.openProjectPicker()
    }

    @objc private func projectRowClicked(_ sender: TabRowView) {
        selectProject(at: sender.index)
    }

    // MARK: - Tab Bar (horizontal tabs within selected project)

    private func rebuildTabBar() {
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let project = currentProject else { return }

        for (i, tab) in project.tabs.enumerated() {
            let isSelected = (i == project.selectedTabIndex)
            let title = " \(tab.name) "

            let tabView = HorizontalTabView(
                displayTitle: title,
                editableName: tab.name,
                isClaude: tab.isClaude,
                badgeState: tab.isClaude ? tab.badgeState : .none,
                isSelected: isSelected,
                index: i,
                target: self,
                clickAction: #selector(tabBarClicked(_:)),
                closeAction: #selector(tabBarCloseClicked(_:))
            )
            tabView.onRename = { [weak self] newName in
                guard let self = self, let project = self.currentProject,
                      i < project.tabs.count else { return }
                project.tabs[i].name = newName
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
            tabBar.addArrangedSubview(tabView)
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

    @objc private func tabBarClicked(_ sender: HorizontalTabView) {
        selectTabInProject(at: sender.index)
    }

    @objc private func tabBarCloseClicked(_ sender: NSButton) {
        guard let project = currentProject else { return }
        let idx = sender.tag
        guard idx >= 0, idx < project.tabs.count else { return }

        let tab = project.tabs[idx]
        tab.surfaceView.destroySurface()
        tab.surfaceView.removeFromSuperview()
        project.tabs.remove(at: idx)

        if project.tabs.isEmpty {
            if let pi = projects.firstIndex(where: { $0.id == project.id }) {
                closeProject(at: pi)
            }
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

// MARK: - TabRowView

class TabRowView: NSView, NSTextFieldDelegate, NSDraggingSource {
    var title: String {
        didSet { label.stringValue = title }
    }
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    /// Badge info for each Claude tab in this project, shown as right-aligned dots.
    var badgeInfos: [(state: TabItem.BadgeState, name: String)] = [] {
        didSet { updateBadgeDots() }
    }
    var onRename: ((String) -> Void)?
    var onClearName: (() -> Void)?
    var onClose: (() -> Void)?
    var onReorder: ((Int, Int) -> Void)?
    let index: Int
    private let label: NSTextField
    private let badgeContainer: NSStackView
    private let closeButton: NSButton
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
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        badgeContainer = NSStackView()
        badgeContainer.orientation = .horizontal
        badgeContainer.spacing = 3
        badgeContainer.setContentHuggingPriority(.required, for: .horizontal)

        closeButton = NSButton(title: "\u{00D7}", target: nil, action: nil)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 12)
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.toolTip = "Close Folder (\u{21E7}\u{2318}W)"

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        label.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(badgeContainer)
        addSubview(closeButton)
        closeButton.isHidden = true

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.leadingAnchor, constant: -4),
            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).setFill()
            bounds.fill()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
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
            dot.toolTip = "\(info.name): \(Self.tooltipForBadge(info.state))"
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
            ])
            if info.state == .thinking {
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

    static func tooltipForBadge(_ state: TabItem.BadgeState) -> String {
        switch state {
        case .none: return ""
        case .idle: return "Idle"
        case .thinking: return "Thinking..."
        case .waitingForInput: return "Waiting for input"
        case .needsPermission: return "Needs permission"
        case .error: return "Error"
        }
    }

    static func colorForBadge(_ state: TabItem.BadgeState) -> NSColor {
        switch state {
        case .none: return .clear
        case .idle: return .systemGray
        case .thinking: return NSColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1.0)
        case .waitingForInput: return .systemBlue
        case .needsPermission: return .systemOrange
        case .error: return .systemRed
        }
    }

    @objc private func closeClicked() {
        onClose?()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            startEditing()
        } else {
            dragStartPoint = convert(event.locationInWindow, from: nil)
            _ = target?.perform(action, with: self)
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

/// A single tab in the horizontal tab bar, cmux-style.
class HorizontalTabView: NSView, NSTextFieldDelegate {
    let index: Int
    private let label: NSTextField
    private let closeButton: NSButton
    private weak var target: AnyObject?
    private let clickAction: Selector
    private var isSelected: Bool
    var onRename: ((String) -> Void)?
    var onClearName: (() -> Void)?
    private var rawName: String

    private var displayTitle: String
    private var editWidthConstraint: NSLayoutConstraint?

    private var badgeDot: NSView?

    init(displayTitle: String, editableName: String, isClaude: Bool = false,
         badgeState: TabItem.BadgeState = .none, isSelected: Bool, index: Int,
         target: AnyObject, clickAction: Selector, closeAction: Selector) {
        self.index = index
        self.isSelected = isSelected
        self.target = target
        self.clickAction = clickAction
        self.rawName = editableName
        self.displayTitle = displayTitle

        label = NSTextField(labelWithString: displayTitle)
        label.font = .systemFont(ofSize: 12)
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        closeButton = NSButton(title: "\u{00D7}", target: nil, action: nil)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 12)
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.toolTip = "Close Tab (\u{2318}W)"

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        closeButton.target = target
        closeButton.action = closeAction
        closeButton.tag = index

        // Badge dot for Claude tabs — positioned on the right by layout constraints below
        if isClaude {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = TabRowView.colorForBadge(badgeState).cgColor
            dot.toolTip = TabRowView.tooltipForBadge(badgeState)
            dot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            if badgeState == .thinking {
                TabRowView.addPulseAnimation(to: dot)
            }
            badgeDot = dot
        }

        label.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(closeButton)
        closeButton.isHidden = true

        // Layout: [close] [label] [badge]  — close on left, badge on right
        let labelLeading = closeButton.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -2)

        var constraints = [
            heightAnchor.constraint(equalToConstant: 28),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
            labelLeading,
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
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.2).cgColor
        }

        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            startEditing()
        } else {
            _ = target?.perform(clickAction, with: self)
        }
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

    private var isEditing = false

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
            label.stringValue = displayTitle
            label.isEditable = false
            label.isSelectable = false
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

// MARK: - AddTabButton

/// + button: left-click adds Claude tab, right-click adds terminal tab.
class AddTabButton: NSView {
    private let leftClickAction: () -> Void
    private let rightClickAction: () -> Void
    private let label: NSTextField

    init(leftClickAction: @escaping () -> Void, rightClickAction: @escaping () -> Void) {
        self.leftClickAction = leftClickAction
        self.rightClickAction = rightClickAction
        label = NSTextField(labelWithString: "  +")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "New Claude tab (\u{2318}T)\nRight-click: new Terminal (\u{21E7}\u{2318}T)"
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
        leftClickAction()
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
        v.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.6).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()
    private var dropIndicatorConstraint: NSLayoutConstraint?
    private var currentDropIndex: Int = -1

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if dropIndicator.superview == nil, let sv = superview {
            sv.addSubview(dropIndicator)
            NSLayoutConstraint.activate([
                dropIndicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                dropIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                dropIndicator.heightAnchor.constraint(equalToConstant: 2),
            ])
        }
    }

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
        guard index != currentDropIndex, let sv = superview else { return }
        currentDropIndex = index
        dropIndicator.isHidden = false

        dropIndicatorConstraint?.isActive = false

        // Position indicator at the insertion point between rows
        if index < arrangedSubviews.count {
            let targetView = arrangedSubviews[index]
            let topY = convert(NSPoint(x: 0, y: targetView.frame.maxY), to: sv).y
            dropIndicatorConstraint = dropIndicator.bottomAnchor.constraint(equalTo: sv.topAnchor, constant: topY)
        } else if let last = arrangedSubviews.last {
            let bottomY = convert(NSPoint(x: 0, y: last.frame.minY), to: sv).y
            dropIndicatorConstraint = dropIndicator.bottomAnchor.constraint(equalTo: sv.topAnchor, constant: bottomY)
        } else {
            dropIndicatorConstraint = dropIndicator.topAnchor.constraint(equalTo: sv.topAnchor)
        }
        dropIndicatorConstraint?.isActive = true
    }

    private func hideIndicator() {
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

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

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

    // UI
    private let splitView = CollapsibleSplitView()
    private let sidebarView = NSView()
    private let sidebarStackView = ReorderableStackView()
    private let rightPane = NSView()
    private let tabBar = ReorderableHStackView()  // horizontal tab bar
    private var isRebuildingTabBar = false
    private var needsTabBarRebuild = false
    private let terminalContainerView = NSView()
    private let contextProgressBar = NSView()
    private var contextProgressFill = NSView()
    private var contextTimer: Timer?
    private var currentTerminalView: TerminalNSView?
    private var welcomeLabel: NSTextField?

    private let sidebarDropZone = SidebarDropZone()
    private let sidebarWidth: CGFloat = 210
    private var sidebarInitialized = false
    private var sidebarWidthBeforeCollapse: CGFloat = 210
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

        // Drop zone covers the entire sidebar area below the stack
        sidebarDropZone.translatesAutoresizingMaskIntoConstraints = false
        sidebarDropZone.registerForDraggedTypes([deckardProjectDragType])
        sidebarView.addSubview(sidebarDropZone)

        sidebarStackView.orientation = .vertical
        sidebarStackView.alignment = .leading
        sidebarStackView.spacing = 1
        sidebarStackView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(sidebarStackView)

        // Open folder button in title bar (right side)
        let openButton = NSButton(image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Open Folder")!, target: self, action: #selector(openProjectClicked))
        openButton.bezelStyle = .recessed
        openButton.isBordered = false
        openButton.contentTintColor = .secondaryLabelColor
        openButton.toolTip = shortcutTooltip("Open Folder", for: .openFolder)
        openButton.translatesAutoresizingMaskIntoConstraints = false

        let accessoryVC = NSTitlebarAccessoryViewController()
        accessoryVC.layoutAttribute = .right
        accessoryVC.view = openButton
        window?.addTitlebarAccessoryViewController(accessoryVC)

        NSLayoutConstraint.activate([
            sidebarStackView.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 4),
            sidebarStackView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarStackView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),

            sidebarDropZone.topAnchor.constraint(equalTo: sidebarStackView.bottomAnchor),
            sidebarDropZone.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor),
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
        tabBar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.8).cgColor
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
                // Verify the session JSONL file still exists before attempting resume.
                // The session ID may be orphaned if Claude exited before writing the file.
                let encoded = project.path.replacingOccurrences(of: "/", with: "-")
                let jsonlPath = NSHomeDirectory() + "/.claude/projects/\(encoded)/\(sid).jsonl"
                if FileManager.default.fileExists(atPath: jsonlPath) {
                    initialInput = "\(prefix)claude --resume \(sid)\(extraArgsSuffix)\n"
                } else {
                    tab.sessionId = nil
                    initialInput = "\(prefix)claude\(extraArgsSuffix)\n"
                }
            } else {
                initialInput = "\(prefix)claude\(extraArgsSuffix)\n"
            }
        } else {
            initialInput = nil
        }

        // Only Claude tabs need the overlay (hides stty/clear setup until CLI sets title).
        // Non-Claude terminals never emit a title OSC, so the overlay would just block for 3s.
        surfaceView.needsOverlay = isClaude

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

        let view = tab.surfaceView

        // Hide the previous surface instead of removing it (avoids Metal context teardown)
        currentOverlay?.removeFromSuperview()
        currentOverlay = nil
        currentTerminalView?.isHidden = true

        // Add to container only once; subsequent switches just unhide
        if view.superview !== terminalContainerView {
            view.translatesAutoresizingMaskIntoConstraints = false
            terminalContainerView.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: terminalContainerView.topAnchor),
                view.bottomAnchor.constraint(equalTo: terminalContainerView.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: terminalContainerView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: terminalContainerView.trailingAnchor),
            ])
        }
        view.isHidden = false
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self, weak overlay, weak view] in
                view?.needsOverlay = false
                overlay?.removeFromSuperview()
                if self?.currentOverlay === overlay { self?.currentOverlay = nil }
            }
        }

        window?.makeFirstResponder(view)

        // Show context bar for Claude tabs
        refreshContextBar(for: tab)
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
            let row = VerticalTabRowView(title: project.name, bold: false, index: i,
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

        return menu
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

    private func rebuildTabBar() {
        guard !isRebuildingTabBar else { return }
        if isTabEditing {
            needsTabBarRebuild = true
            return
        }
        isRebuildingTabBar = true
        defer { isRebuildingTabBar = false }

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

// MARK: - VerticalTabRowView

class VerticalTabRowView: NSView, NSTextFieldDelegate, NSDraggingSource {
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
        label.textColor = .labelColor
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
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).setFill()
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

/// A single tab in the horizontal tab bar, cmux-style.
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
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Badge dot for Claude tabs — positioned on the right by layout constraints below
        if isClaude {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = VerticalTabRowView.colorForBadge(badgeState).cgColor
            dot.toolTip = VerticalTabRowView.tooltipForBadge(badgeState)
            dot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            if badgeState == .thinking {
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
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.2).cgColor
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
        label.textColor = .secondaryLabelColor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = shortcutTooltip("New Claude tab", for: .newClaudeTab)
            + "\nRight-click: " + shortcutTooltip("new Terminal", for: .newTerminalTab)
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
        v.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.6).cgColor
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

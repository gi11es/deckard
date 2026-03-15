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
        // TODO: Make configurable via settings
        return DefaultTabConfig(entries: [
            (isClaude: true, name: "Claude"),
            (isClaude: false, name: "Terminal"),
        ])
    }
}

// MARK: - Window Controller

class DeckardWindowController: NSWindowController, NSSplitViewDelegate {
    private let ghosttyApp: DeckardGhosttyApp
    private var projects: [ProjectItem] = []
    private var selectedProjectIndex: Int = -1

    // UI
    private let splitView = NSSplitView()
    private let sidebarView = NSView()
    private let sidebarStackView = NSStackView()
    private let rightPane = NSView()
    private let tabBar = NSStackView()          // horizontal tab bar
    private let terminalContainerView = NSView()
    private var currentTerminalView: TerminalNSView?
    private var welcomeLabel: NSTextField?

    private let sidebarWidth: CGFloat = 210
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

        // Hint at bottom of sidebar
        let hint = NSTextField(labelWithString: "\u{2318}O Open Project")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(hint)

        NSLayoutConstraint.activate([
            sidebarStackView.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 0),
            sidebarStackView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarStackView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),

            hint.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor, constant: -6),
            hint.centerXAnchor.constraint(equalTo: sidebarView.centerXAnchor),
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

        sidebarView.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        DispatchQueue.main.async { [self] in
            splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        }

        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { 80 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { min(300, splitView.bounds.width * 0.3) }
    func splitView(_ splitView: NSSplitView, canCollapseSubview s: NSView) -> Bool { false }

    // MARK: - Project Management

    func openProject(path: String) {
        // Check if project already open
        if let idx = projects.firstIndex(where: { $0.path == path }) {
            selectProject(at: idx)
            return
        }

        let project = ProjectItem(path: path)

        // Create default tabs
        let config = DefaultTabConfig.current
        for entry in config.entries {
            createTabInProject(project, isClaude: entry.isClaude)
        }

        projects.append(project)
        rebuildSidebar()
        selectProject(at: projects.count - 1)
        if !isRestoring { saveState() }
    }

    func closeProject(at index: Int) {
        guard index >= 0, index < projects.count else { return }
        let project = projects[index]

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
        // Name tabs — only number if there will be more than one of the same type
        let tabName: String
        if let name = name {
            tabName = name
        } else {
            let sameType = project.tabs.filter { $0.isClaude == isClaude }
            let base = isClaude ? "Claude" : "Terminal"
            if sameType.isEmpty {
                tabName = base
            } else {
                // Rename the first unnumbered one to #1
                if sameType.count == 1, sameType[0].name == base {
                    sameType[0].name = "\(base) #1"
                }
                tabName = "\(base) #\(sameType.count + 1)"
            }
        }
        let tab = TabItem(surfaceView: surfaceView, name: tabName, isClaude: isClaude)

        var envVars: [String: String] = [:]
        if isClaude {
            tab.sessionId = sessionIdToResume
            envVars["DECKARD_SESSION_TYPE"] = "claude"
        }

        let initialInput: String?
        if isClaude {
            let pathPrefix = "export PATH=\"$DECKARD_BIN_DIR:$PATH\"; "
            if let sid = sessionIdToResume {
                initialInput = "\(pathPrefix)clear; claude --resume \(sid)\n"
            } else {
                initialInput = "\(pathPrefix)clear; claude\n"
            }
        } else {
            initialInput = "clear\n"
        }

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

    private func showTab(_ tab: TabItem) {
        welcomeLabel?.isHidden = true
        currentTerminalView?.removeFromSuperview()

        let view = tab.surfaceView
        view.translatesAutoresizingMaskIntoConstraints = false
        terminalContainerView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: terminalContainerView.topAnchor),
            view.bottomAnchor.constraint(equalTo: terminalContainerView.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: terminalContainerView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: terminalContainerView.trailingAnchor),
        ])
        currentTerminalView = view
        window?.makeFirstResponder(view)
    }

    func focusedSurface() -> ghostty_surface_t? {
        guard let project = currentProject else { return nil }
        let idx = project.selectedTabIndex
        guard idx >= 0, idx < project.tabs.count else { return nil }
        return project.tabs[idx].surfaceView.surface
    }

    // MARK: - Surface Callbacks

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
                tab.surfaceView.removeFromSuperview()
                project.tabs.remove(at: ti)

                if project.tabs.isEmpty {
                    closeProject(at: pi)
                } else if pi == selectedProjectIndex {
                    project.selectedTabIndex = min(project.selectedTabIndex, project.tabs.count - 1)
                    rebuildTabBar()
                    showTab(project.tabs[project.selectedTabIndex])
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
        if tab.sessionId != sessionId {
            tab.sessionId = sessionId
            saveState()
        }
    }

    func updateBadge(forSurfaceId surfaceIdStr: String, state: TabItem.BadgeState) {
        guard let tab = tabForSurfaceId(surfaceIdStr) else { return }
        tab.badgeState = state
        // Update tab bar button if this is the current project
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
            row.badgeState = worstBadge(in: project)
            row.onRename = { [weak self] newName in
                guard let self = self, i < self.projects.count else { return }
                self.projects[i].name = newName
                self.saveState()
            }
            sidebarStackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: sidebarStackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: sidebarStackView.trailingAnchor).isActive = true
        }

        updateSidebarSelection()
    }

    private func worstBadge(in project: ProjectItem) -> TabItem.BadgeState {
        var worst: TabItem.BadgeState = .none
        for tab in project.tabs {
            switch tab.badgeState {
            case .needsPermission: return .needsPermission
            case .waitingForInput: worst = .waitingForInput
            case .thinking where worst == .none: worst = .thinking
            default: break
            }
        }
        return worst
    }

    private func updateSidebarSelection() {
        for (i, view) in sidebarStackView.arrangedSubviews.enumerated() {
            if let row = view as? TabRowView {
                row.isSelected = (i == selectedProjectIndex)
            }
        }
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
            let icon = tab.isClaude ? "\u{2726}" : "$"  // ✦ for Claude, $ for terminal
            let title = " \(icon) \(tab.name) "

            let tabView = HorizontalTabView(
                displayTitle: title,
                editableName: tab.name,
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
            tabBar.addArrangedSubview(tabView)
        }

        // Add "+" button
        let addButton = NSButton(title: "+", target: self, action: #selector(addTabClicked))
        addButton.bezelStyle = .recessed
        addButton.font = .systemFont(ofSize: 13, weight: .medium)
        addButton.isBordered = false
        addButton.contentTintColor = .secondaryLabelColor
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
            showTab(project.tabs[project.selectedTabIndex])
        }
        saveState()
    }

    @objc private func addTabClicked() {
        addTabToCurrentProject(isClaude: true)
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

class TabRowView: NSView, NSTextFieldDelegate {
    var title: String {
        didSet { label.stringValue = title }
    }
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var badgeState: TabItem.BadgeState = .none {
        didSet {
            badgeDot.layer?.backgroundColor = badgeColor.cgColor
            badgeDot.needsDisplay = true
        }
    }
    var onRename: ((String) -> Void)?
    let index: Int
    private let label: NSTextField
    private let badgeDot: NSView
    private weak var target: AnyObject?
    private let action: Selector

    private var badgeColor: NSColor {
        switch badgeState {
        case .none: return .clear
        case .thinking: return NSColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1.0)
        case .waitingForInput: return .systemBlue
        case .needsPermission: return .systemOrange
        case .error: return .systemRed
        }
    }

    init(title: String, bold: Bool, index: Int, target: AnyObject, action: Selector) {
        self.title = title
        self.index = index
        self.target = target
        self.action = action

        badgeDot = NSView()
        badgeDot.wantsLayer = true
        badgeDot.layer?.cornerRadius = 3.5
        badgeDot.layer?.backgroundColor = NSColor.clear.cgColor

        label = NSTextField(labelWithString: title)
        label.font = bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        badgeDot.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeDot)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            badgeDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badgeDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeDot.widthAnchor.constraint(equalToConstant: 7),
            badgeDot.heightAnchor.constraint(equalToConstant: 7),
            label.leadingAnchor.constraint(equalTo: badgeDot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).setFill()
            bounds.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            startEditing()
        } else {
            _ = target?.perform(action, with: self)
        }
    }

    private func startEditing() {
        label.isEditable = true
        label.isSelectable = true
        label.delegate = self
        label.becomeFirstResponder()
        label.currentEditor()?.selectAll(nil)
    }

    private func finishEditing() {
        label.isEditable = false
        label.isSelectable = false
        let newName = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty && newName != title {
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
    private var rawName: String  // name without icon prefix

    private var displayTitle: String

    init(displayTitle: String, editableName: String, isSelected: Bool, index: Int, target: AnyObject,
         clickAction: Selector, closeAction: Selector) {
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

        closeButton = NSButton(title: "\u{00D7}", target: nil, action: nil)  // ×
        closeButton.bezelStyle = .recessed
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 13)
        closeButton.contentTintColor = .tertiaryLabelColor

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        closeButton.target = target
        closeButton.action = closeAction
        // Store index on close button via tag
        closeButton.tag = index

        label.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 2),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
        ])

        if isSelected {
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.2).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            startEditing()
        } else {
            _ = target?.perform(clickAction, with: self)
        }
    }

    private func startEditing() {
        label.isEditable = true
        label.isSelectable = true
        label.stringValue = rawName
        label.delegate = self
        label.becomeFirstResponder()
        label.currentEditor()?.selectAll(nil)
    }

    private func finishEditing() {
        label.isEditable = false
        label.isSelectable = false
        let newName = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty && newName != rawName {
            rawName = newName
            onRename?(newName)
            // rebuild will be triggered by onRename which calls rebuildTabBar
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

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

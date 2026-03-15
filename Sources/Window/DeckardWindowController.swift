import AppKit
import GhosttyKit

/// Represents a single tab in the sidebar.
class TabItem {
    let id: UUID
    var surfaceView: TerminalNSView
    var name: String
    var nameOverride: Bool = false
    var isMaster: Bool = false
    var isClaude: Bool = true
    var sessionId: String?
    var workingDirectory: String?
    var badgeState: BadgeState = .none

    enum BadgeState {
        case none
        case active
        case waitingForInput
        case needsPermission
        case error
    }

    init(surfaceView: TerminalNSView, name: String, isClaude: Bool = true) {
        self.id = surfaceView.surfaceId
        self.surfaceView = surfaceView
        self.name = name
        self.isClaude = isClaude
    }
}

/// The main window controller with a vertical tab sidebar on the left.
class DeckardWindowController: NSWindowController, NSSplitViewDelegate {
    private let ghosttyApp: DeckardGhosttyApp
    private var tabs: [TabItem] = []
    private var selectedTabIndex: Int = -1

    // UI components
    private let splitView = NSSplitView()
    private let sidebarView = NSView()
    private let sidebarScrollView = NSScrollView()
    private let sidebarStackView = NSStackView()
    private let terminalContainerView = NSView()
    private var currentTerminalView: TerminalNSView?

    private let sidebarWidth: CGFloat = 210

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

        // Disable macOS's own tab bar system
        window.tabbingMode = .disallowed

        super.init(window: window)

        // Restore saved frame or center
        window.setFrameAutosaveName("DeckardMainWindow")
        if !window.setFrameUsingName("DeckardMainWindow") {
            window.center()
        }

        setupUI()
        createTab(claude: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Main split: sidebar | terminal
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

        // Sidebar container
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.wantsLayer = true
        sidebarView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor

        // Stack view for tab buttons (vertical list)
        sidebarStackView.orientation = .vertical
        sidebarStackView.alignment = .width
        sidebarStackView.spacing = 2
        sidebarStackView.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        sidebarStackView.translatesAutoresizingMaskIntoConstraints = false

        sidebarScrollView.documentView = sidebarStackView
        sidebarScrollView.hasVerticalScroller = true
        sidebarScrollView.autohidesScrollers = true
        sidebarScrollView.scrollerStyle = .overlay
        sidebarScrollView.drawsBackground = false
        sidebarScrollView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(sidebarScrollView)

        NSLayoutConstraint.activate([
            sidebarScrollView.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 8),
            sidebarScrollView.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor, constant: -8),
            sidebarScrollView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarScrollView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            sidebarStackView.widthAnchor.constraint(equalTo: sidebarScrollView.widthAnchor),
        ])

        // Terminal container
        terminalContainerView.translatesAutoresizingMaskIntoConstraints = false

        // Add to split view
        splitView.addArrangedSubview(sidebarView)
        splitView.addArrangedSubview(terminalContainerView)

        // Set initial sidebar width after layout
        DispatchQueue.main.async { [self] in
            splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 80  // minimum sidebar width
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return min(300, splitView.bounds.width * 0.3)  // max 30% of window
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return false  // don't allow sidebar to collapse
    }

    // MARK: - Tab Management

    func createTab(claude: Bool, workingDirectory: String? = nil, name: String? = nil) {
        guard let app = ghosttyApp.app else { return }

        let surfaceView = TerminalNSView()
        let tabName = name ?? (claude ? "New Session" : "Terminal")
        let tab = TabItem(surfaceView: surfaceView, name: tabName, isClaude: claude)
        tab.workingDirectory = workingDirectory

        // For Claude tabs, start a normal shell and use initial_input
        // to launch claude. This way the shell is fully set up (PATH, etc.)
        // before claude runs, and our wrapper in Resources/bin/ intercepts it.
        var extraEnvVars: [String: String] = [:]
        if claude {
            extraEnvVars["DECKARD_SESSION_TYPE"] = "claude"
        }

        surfaceView.createSurface(
            app: app,
            tabId: tab.id,
            workingDirectory: workingDirectory,
            command: nil,
            envVars: extraEnvVars,
            initialInput: claude ? "claude\n" : nil
        )

        tabs.append(tab)
        rebuildSidebar()
        selectTab(at: tabs.count - 1)
    }

    func closeCurrentTab() {
        guard selectedTabIndex >= 0, selectedTabIndex < tabs.count else { return }
        closeTab(at: selectedTabIndex)
    }

    func closeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }

        let tab = tabs[index]
        tab.surfaceView.destroySurface()
        tab.surfaceView.removeFromSuperview()
        tabs.remove(at: index)

        rebuildSidebar()

        if tabs.isEmpty {
            selectedTabIndex = -1
            currentTerminalView = nil
            createTab(claude: false)
        } else {
            let newIndex = min(index, tabs.count - 1)
            selectTab(at: newIndex)
        }
    }

    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }

        // Unfocus old
        if selectedTabIndex >= 0, selectedTabIndex < tabs.count {
            tabs[selectedTabIndex].surfaceView.surface.map { ghostty_surface_set_focus($0, false) }
        }

        selectedTabIndex = index

        // Swap terminal views
        currentTerminalView?.removeFromSuperview()

        let newView = tabs[index].surfaceView
        newView.translatesAutoresizingMaskIntoConstraints = false
        terminalContainerView.addSubview(newView)
        NSLayoutConstraint.activate([
            newView.topAnchor.constraint(equalTo: terminalContainerView.topAnchor),
            newView.bottomAnchor.constraint(equalTo: terminalContainerView.bottomAnchor),
            newView.leadingAnchor.constraint(equalTo: terminalContainerView.leadingAnchor),
            newView.trailingAnchor.constraint(equalTo: terminalContainerView.trailingAnchor),
        ])
        currentTerminalView = newView

        // Focus the terminal
        window?.makeFirstResponder(newView)

        // Update sidebar highlight
        updateSidebarSelection()
    }

    func focusMasterSession() {
        if let masterIndex = tabs.firstIndex(where: { $0.isMaster }) {
            selectTab(at: masterIndex)
        }
    }

    func focusedSurface() -> ghostty_surface_t? {
        guard selectedTabIndex >= 0, selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex].surfaceView.surface
    }

    // MARK: - Surface Callbacks

    func setTitle(_ title: String, forSurface surface: ghostty_surface_t?) {
        guard let surface = surface else { return }
        for (i, tab) in tabs.enumerated() {
            if tab.surfaceView.surface == surface {
                tab.surfaceView.title = title
                if !tab.nameOverride && !title.isEmpty {
                    tab.name = title
                    updateSidebarItem(at: i)
                }
                break
            }
        }
    }

    func setPwd(_ pwd: String, forSurface surface: ghostty_surface_t?) {
        guard let surface = surface else { return }
        for tab in tabs {
            if tab.surfaceView.surface == surface {
                tab.surfaceView.pwd = pwd
                break
            }
        }
    }

    func handleSurfaceClosedById(_ surfaceId: UUID) {
        if let index = tabs.firstIndex(where: { $0.id == surfaceId }) {
            closeTab(at: index)
        }
    }

    // MARK: - Sidebar Rendering

    private func rebuildSidebar() {
        // Remove all existing tab buttons
        sidebarStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (i, tab) in tabs.enumerated() {
            let button = makeTabButton(for: tab, at: i)
            sidebarStackView.addArrangedSubview(button)
        }

        updateSidebarSelection()
    }

    private func makeTabButton(for tab: TabItem, at index: Int) -> NSView {
        let title = tab.isMaster ? "  \u{2605} \(tab.name)" : "  \(tab.name)"
        let button = NSButton(title: title, target: self, action: #selector(tabButtonClicked(_:)))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .recessed
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.alignment = .left
        button.font = tab.isMaster ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        button.contentTintColor = .labelColor
        button.tag = index

        button.wantsLayer = true
        button.layer?.cornerRadius = 4

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 28),
        ])

        return button
    }

    private func updateSidebarSelection() {
        for (i, view) in sidebarStackView.arrangedSubviews.enumerated() {
            if i == selectedTabIndex {
                view.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).cgColor
            } else {
                view.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }

    private func updateSidebarItem(at index: Int) {
        guard index >= 0, index < sidebarStackView.arrangedSubviews.count else { return }
        let tab = tabs[index]
        if let button = sidebarStackView.arrangedSubviews[index] as? NSButton {
            button.title = tab.isMaster ? "\u{2605} \(tab.name)" : tab.name
        }
    }

    private func badgeColor(for state: TabItem.BadgeState) -> NSColor {
        switch state {
        case .none: return .clear
        case .active: return .systemGreen
        case .waitingForInput: return .systemBlue
        case .needsPermission: return .systemOrange
        case .error: return .systemRed
        }
    }

    // MARK: - Sidebar Actions

    @objc private func tabButtonClicked(_ sender: NSButton) {
        let index = sender.tag
        if index >= 0, index < tabs.count {
            selectTab(at: index)
        }
    }

    private func renameTabAtIndex(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let tab = tabs[index]

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a new name for this tab:"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.stringValue = tab.name
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty {
                tab.name = newName
                tab.nameOverride = true
                updateSidebarItem(at: index)
            }
        }
    }
}

// Store tab index on views via associated objects
private var tabIndexKey: UInt8 = 0

private func setTabIndex(_ index: Int, on view: NSView) {
    objc_setAssociatedObject(view, &tabIndexKey, index, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

private func getTabIndex(from view: NSView) -> Int {
    objc_getAssociatedObject(view, &tabIndexKey) as? Int ?? -1
}

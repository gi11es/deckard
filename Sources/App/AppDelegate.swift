import AppKit
import GhosttyKit

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private(set) var ghosttyApp: DeckardGhosttyApp!
    var windowController: DeckardWindowController?
    private let hookHandler = HookHandler()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        // Set up the Ghostty app wrapper (creates ghostty_app_t with callbacks).
        ghosttyApp = DeckardGhosttyApp()
        guard ghosttyApp.app != nil else {
            let alert = NSAlert()
            alert.messageText = "Failed to Initialize Terminal"
            alert.informativeText = "Could not create the Ghostty terminal engine. The app cannot continue."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Set the GHOSTTY_RESOURCES_DIR so shell integration and terminfo work.
        // Use ghostty's own resources directory from the submodule build.
        let ghosttyResources = Bundle.main.bundlePath + "/../ghostty/zig-out/share/ghostty"
        if FileManager.default.fileExists(atPath: ghosttyResources) {
            setenv("GHOSTTY_RESOURCES_DIR", ghosttyResources, 1)
        }

        // Set up the main menu.
        setupMainMenu()

        // Listen for notifications from ghostty callbacks.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleSurfaceClosed(_:)), name: .deckardSurfaceClosed, object: nil)
        nc.addObserver(self, selector: #selector(handleTitleChanged(_:)), name: .deckardSurfaceTitleChanged, object: nil)
        nc.addObserver(self, selector: #selector(handleNewTab), name: .deckardNewTab, object: nil)
        nc.addObserver(self, selector: #selector(handleCloseTab), name: .deckardCloseTab, object: nil)

        // Request notification permissions.
        NotificationManager.shared.setup()

        // Start the control socket for hook communication.
        ControlSocket.shared.start()
        ControlSocket.shared.onMessage = { [weak self] message, reply in
            self?.hookHandler.handle(message, reply: reply)
        }

        // Set socket path in environment for child processes.
        setenv("DECKARD_SOCKET_PATH", ControlSocket.shared.path, 1)

        // Create and show the main window.
        windowController = DeckardWindowController(ghosttyApp: ghosttyApp)
        hookHandler.windowController = windowController
        windowController?.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.saveState()
        ControlSocket.shared.stop()
    }

    // MARK: - Notification Handlers

    @objc private func handleSurfaceClosed(_ notification: Notification) {
        guard let surfaceId = notification.userInfo?["surfaceId"] as? UUID else { return }
        windowController?.handleSurfaceClosedById(surfaceId)
    }

    @objc private func handleTitleChanged(_ notification: Notification) {
        guard let surface = notification.userInfo?["surface"] as? ghostty_surface_t,
              let title = notification.userInfo?["title"] as? String else { return }
        windowController?.setTitle(title, forSurface: surface)
    }

    @objc private func handleNewTab() {
        windowController?.addTabToCurrentProject(isClaude: true)
    }

    @objc private func handleCloseTab() {
        windowController?.closeCurrentTab()
    }

    // MARK: - Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Deckard", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Deckard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Project...", action: #selector(openProject), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "New Claude Tab", action: #selector(newClaudeTab), keyEquivalent: "t")
        let termItem = NSMenuItem(title: "New Terminal Tab", action: #selector(newTerminalTab), keyEquivalent: "t")
        termItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(termItem)
        fileMenu.addItem(withTitle: "Duplicate Tab", action: #selector(duplicateTab), keyEquivalent: "d")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeCurrentTab), keyEquivalent: "w")
        let closeProjectItem = NSMenuItem(title: "Close Project", action: #selector(closeCurrentProject), keyEquivalent: "w")
        closeProjectItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeProjectItem)
        fileMenu.addItem(.separator())

        // Tab navigation — standard macOS shortcuts
        let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(selectNextTab), keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(nextTabItem)
        let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(selectPrevTab), keyEquivalent: "[")
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(prevTabItem)
        fileMenu.addItem(.separator())

        // Cmd+1-9 for direct tab access
        for i in 1...9 {
            let item = NSMenuItem(title: "Tab \(i)", action: #selector(selectTabByNumber(_:)), keyEquivalent: "\(i)")
            item.tag = i - 1
            fileMenu.addItem(item)
        }

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Actions

    private let projectPicker = ProjectPicker()

    func openProjectPicker() {
        openProject()
    }

    @objc private func openProject() {
        projectPicker.show(relativeTo: windowController?.window) { [weak self] path in
            guard let path = path else { return }
            self?.windowController?.openProject(path: path)
        }
    }

    @objc private func newClaudeTab() {
        windowController?.addTabToCurrentProject(isClaude: true)
    }

    @objc private func newTerminalTab() {
        windowController?.addTabToCurrentProject(isClaude: false)
    }

    @objc private func closeCurrentTab() {
        windowController?.closeCurrentTab()
    }

    @objc private func closeCurrentProject() {
        windowController?.closeCurrentProject()
    }

    @objc private func duplicateTab() {
        windowController?.duplicateCurrentTab()
    }

    @objc private func selectNextTab() {
        windowController?.selectNextTab()
    }

    @objc private func selectPrevTab() {
        windowController?.selectPrevTab()
    }

    @objc private func selectTabByNumber(_ sender: NSMenuItem) {
        windowController?.selectProject(byNumber: sender.tag)
    }

    @objc private func showSettings() {
        // TODO: Settings for default tab configuration
        let alert = NSAlert()
        alert.messageText = "Deckard Settings"
        alert.informativeText = "Settings will be available in a future update."
        alert.runModal()
    }
}

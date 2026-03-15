import AppKit
import GhosttyKit

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private(set) var ghosttyApp: DeckardGhosttyApp!
    var windowController: DeckardWindowController?

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

        // Create and show the main window.
        windowController = DeckardWindowController(ghosttyApp: ghosttyApp)
        windowController?.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // TODO: Save session state for resumption
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
        windowController?.createTab(claude: true)
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
        appMenu.addItem(withTitle: "Quit Deckard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Claude Session", action: #selector(newClaudeSession), keyEquivalent: "t")
        let termItem = NSMenuItem(title: "New Terminal", action: #selector(newTerminal), keyEquivalent: "t")
        termItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(termItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeCurrentTab), keyEquivalent: "w")
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
        let masterItem = NSMenuItem(title: "Focus Master Session", action: #selector(focusMasterSession), keyEquivalent: "m")
        masterItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(masterItem)
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

    @objc private func newClaudeSession() {
        windowController?.createTab(claude: true)
    }

    @objc private func newTerminal() {
        windowController?.createTab(claude: false)
    }

    @objc private func closeCurrentTab() {
        windowController?.closeCurrentTab()
    }

    @objc private func focusMasterSession() {
        windowController?.focusMasterSession()
    }
}

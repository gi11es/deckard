import AppKit
import GhosttyKit
import KeyboardShortcuts

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private(set) var ghosttyApp: DeckardGhosttyApp!
    var windowController: DeckardWindowController?
    private let hookHandler = HookHandler()


    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        // Set the GHOSTTY_RESOURCES_DIR BEFORE creating the Ghostty app, so theme
        // resolution works during initial config loading.
        let devResources = Bundle.main.bundlePath + "/../ghostty/zig-out/share/ghostty"
        let bundleResources = Bundle.main.resourcePath ?? ""
        if FileManager.default.fileExists(atPath: devResources) {
            setenv("GHOSTTY_RESOURCES_DIR", devResources, 1)
        } else if FileManager.default.fileExists(atPath: bundleResources + "/themes") {
            setenv("GHOSTTY_RESOURCES_DIR", bundleResources, 1)
        }

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

        // Initialize theme manager and compute initial theme colors.
        // Note: no notification is posted here — the window controller doesn't exist yet.
        // It reads ThemeManager.shared.currentColors directly during its init.
        ThemeManager.shared.loadAvailableThemes()
        if let savedTheme = ThemeManager.shared.currentThemeName,
           let themeInfo = ThemeManager.shared.availableThemes.first(where: { $0.name == savedTheme }),
           let colors = ThemeManager.parseThemeColors(at: themeInfo.path) {
            ThemeManager.shared.currentColors = ThemeColors(background: colors.background, foreground: colors.foreground)
        } else {
            ThemeManager.shared.currentColors = ThemeColors(
                background: ghosttyApp.defaultBackgroundColor,
                foreground: ghosttyApp.defaultForegroundColor
            )
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

        // Install the /deckard feedback skill if gh CLI is available.
        installDeckardSkill()

        // Create and show the main window.
        windowController = DeckardWindowController(ghosttyApp: ghosttyApp)
        hookHandler.windowController = windowController
        windowController?.showWindow(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
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

    @MainActor private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Deckard", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: "")
        settingsItem.setShortcut(for: .settings)
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Deckard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")

        let openItem = NSMenuItem(title: "Open Folder...", action: #selector(openProject), keyEquivalent: "")
        openItem.setShortcut(for: .openFolder)
        fileMenu.addItem(openItem)
        fileMenu.addItem(.separator())

        let claudeItem = NSMenuItem(title: "New Claude Tab", action: #selector(newClaudeTab), keyEquivalent: "")
        claudeItem.setShortcut(for: .newClaudeTab)
        fileMenu.addItem(claudeItem)

        let termItem = NSMenuItem(title: "New Terminal Tab", action: #selector(newTerminalTab), keyEquivalent: "")
        termItem.setShortcut(for: .newTerminalTab)
        fileMenu.addItem(termItem)

        fileMenu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(closeCurrentTab), keyEquivalent: "")
        closeItem.setShortcut(for: .closeTab)
        fileMenu.addItem(closeItem)

        let closeProjectItem = NSMenuItem(title: "Close Folder", action: #selector(closeCurrentProject), keyEquivalent: "")
        closeProjectItem.setShortcut(for: .closeFolder)
        fileMenu.addItem(closeProjectItem)
        fileMenu.addItem(.separator())

        let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(selectNextTab), keyEquivalent: "")
        nextTabItem.setShortcut(for: .nextTab)
        fileMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(selectPrevTab), keyEquivalent: "")
        prevTabItem.setShortcut(for: .previousTab)
        fileMenu.addItem(prevTabItem)
        fileMenu.addItem(.separator())

        // Cmd+1-9 for direct tab access
        for i in 1...9 {
            let item = NSMenuItem(title: "Tab \(i)", action: #selector(selectTabByNumber(_:)), keyEquivalent: "")
            item.tag = i - 1
            item.setShortcut(for: tabShortcutNames[i - 1])
            fileMenu.addItem(item)
        }

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu (system standard — not configurable)
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
        let toggleSidebarItem = NSMenuItem(title: "Hide Sidebar", action: #selector(toggleSidebar), keyEquivalent: "")
        toggleSidebarItem.setShortcut(for: .toggleSidebar)
        toggleSidebarItem.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
        viewMenu.addItem(toggleSidebarItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu (system standard — not configurable)
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
        // If a secondary window (e.g. Settings) is key, close it instead of
        // closing a terminal tab in the main window.
        if let keyWindow = NSApp.keyWindow,
           keyWindow != windowController?.window {
            keyWindow.performClose(nil)
            return
        }
        windowController?.closeCurrentTab()
    }

    @objc private func closeCurrentProject() {
        if let keyWindow = NSApp.keyWindow,
           keyWindow != windowController?.window {
            keyWindow.performClose(nil)
            return
        }
        windowController?.closeCurrentProject()
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

    @objc private func toggleSidebar() {
        windowController?.toggleSidebar()
    }

    @objc private func showSettings() {
        SettingsWindowController.shared.show()
    }

    // MARK: - Deckard Skill

    private func installDeckardSkill() {
        DispatchQueue.global(qos: .utility).async {
            // Only install if gh CLI is available
            guard FileManager.default.isExecutableFile(atPath: "/usr/local/bin/gh")
                    || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/gh")
                    || Self.whichGh() != nil else { return }

            let commandsDir = NSHomeDirectory() + "/.claude/commands"
            let skillPath = commandsDir + "/deckard.md"

            try? FileManager.default.createDirectory(
                atPath: commandsDir,
                withIntermediateDirectories: true)

            let content = """
            File a bug report or feature request for Deckard.

            Ask the user to describe the issue or feature. Then use `gh issue create` to file it:

            ```
            gh issue create --repo gi11es/deckard --title "<concise title>" --body "<structured body>"
            ```

            Format the body as:

            - **Bug reports:** `## Bug` heading, reproduction steps, expected vs actual behavior.
            - **Feature requests:** `## Feature request` heading, description of the desired behavior.

            Before filing, show the user the title and body and ask for confirmation. Offer to anonymize repo names, file paths, and other potentially sensitive details.

            After filing, show the issue URL.
            """

            // Only write if the file doesn't exist or was written by Deckard
            let marker = "gh issue create --repo gi11es/deckard"
            if let existing = try? String(contentsOfFile: skillPath, encoding: .utf8),
               !existing.contains(marker) {
                return  // User has a custom /deckard command, don't overwrite
            }

            try? content.write(toFile: skillPath, atomically: true, encoding: .utf8)
        }
    }

    private static func whichGh() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["gh"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }
}

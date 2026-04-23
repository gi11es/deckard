import AppKit
import KeyboardShortcuts
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    var windowController: DeckardWindowController?
    private let hookHandler = HookHandler()
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    /// True when launched as a test host by xctest.
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let log = DiagnosticLog.shared
        log.log("startup", "applicationDidFinishLaunching entered")
        Self.shared = self

        // When running as a test host, skip all UI/socket setup.
        if Self.isRunningTests {
            log.log("startup", "Running as test host — skipping UI setup")
            return
        }

        // Load themes and apply saved selection.
        log.log("startup", "Loading themes...")
        ThemeManager.shared.loadAvailableThemes()
        ThemeManager.shared.applySavedTheme()
        log.log("startup", "Loaded \(ThemeManager.shared.availableThemes.count) themes, current: \(ThemeManager.shared.currentThemeName ?? "default")")

        // Set up the main menu.
        log.log("startup", "Setting up main menu...")
        setupMainMenu()

        // Listen for notifications.
        log.log("startup", "Registering notification observers...")
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleSurfaceClosed(_:)), name: .deckardSurfaceClosed, object: nil)
        nc.addObserver(self, selector: #selector(handleTitleChanged(_:)), name: .deckardSurfaceTitleChanged, object: nil)
        nc.addObserver(self, selector: #selector(handleNewTab), name: .deckardNewTab, object: nil)
        nc.addObserver(self, selector: #selector(handleCloseTab), name: .deckardCloseTab, object: nil)

        // Start the control socket for hook communication.
        log.log("startup", "Starting control socket...")
        ControlSocket.shared.start()
        ControlSocket.shared.onMessage = { [weak self] message, reply in
            self?.hookHandler.handle(message, reply: reply)
        }
        setenv("DECKARD_SOCKET_PATH", ControlSocket.shared.path, 1)
        log.log("startup", "Control socket at: \(ControlSocket.shared.path ?? "(nil)")")

        // Install the /deckard feedback skill if gh CLI is available.
        log.log("startup", "Installing Deckard skill...")
        installDeckardSkill()

        // Install Claude Code hooks so Deckard receives session events.
        log.log("startup", "Installing Claude Code hooks...")
        DeckardHooksInstaller.installIfNeeded()

        // Parse Claude CLI flags for autocomplete in settings.
        log.log("startup", "Loading Claude CLI flags...")
        ClaudeCLIFlags.shared.load()

        // Clean up orphaned tmux sessions from previous runs
        if TerminalSurface.tmuxAvailable {
            let savedState = SessionManager.shared.load()
            let activeSessions = Set(
                (savedState?.projects ?? []).flatMap(\.tabs).compactMap(\.tmuxSessionName)
            )
            DispatchQueue.global(qos: .utility).async {
                TerminalSurface.cleanupOrphanedTmuxSessions(activeSessions: activeSessions)
            }
            log.log("startup", "tmux available, \(activeSessions.count) saved sessions")
        } else {
            log.log("startup", "tmux not available")
        }

        // Create and show the main window.
        log.log("startup", "Creating window controller...")
        windowController = DeckardWindowController()
        hookHandler.windowController = windowController
        log.log("startup", "Showing main window...")
        windowController?.showWindow(nil)
        log.log("startup", "=== Startup complete ===")

        // Check Full Disk Access and prompt if needed.
        // Run the probe on a background thread to avoid blocking the main
        // thread with Process.waitUntilExit(), then show the alert on main.
        DispatchQueue.global(qos: .utility).async {
            let hasFDA = FullDiskAccessChecker.hasFullDiskAccess()
            guard !hasFDA else { return }
            guard !UserDefaults.standard.bool(forKey: "suppressFullDiskAccessPrompt") else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let window = self?.windowController?.window else { return }

                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "Full Disk Access"
                alert.informativeText = "Deckard is a terminal emulator. Like Terminal and iTerm2, it needs Full Disk Access so that commands running inside it can access all of your files.\n\nClick \"Open System Settings\" below, then use the \"+\" button to add Deckard (it will also be revealed in Finder so you can find it easily)."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Not Now")
                alert.addButton(withTitle: "Don't Ask Again")

                alert.beginSheetModal(for: window) { response in
                    switch response {
                    case .alertFirstButtonReturn:
                        FullDiskAccessChecker.openSettings()
                    case .alertThirdButtonReturn:
                        UserDefaults.standard.set(true, forKey: "suppressFullDiskAccessPrompt")
                    default:
                        break
                    }
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wc = windowController {
            SessionManager.shared.save(wc.captureState())
        }
        ControlSocket.shared.stop()
    }

    // MARK: - Notification Handlers

    @objc private func handleSurfaceClosed(_ notification: Notification) {
        guard let surfaceId = notification.userInfo?["surfaceId"] as? UUID else { return }
        windowController?.handleSurfaceClosedById(surfaceId)
    }

    @objc private func handleTitleChanged(_ notification: Notification) {
        guard let surfaceId = notification.userInfo?["surfaceId"] as? UUID,
              let title = notification.userInfo?["title"] as? String else { return }
        windowController?.setTitle(title, forSurfaceId: surfaceId)
    }

    @objc private func handleNewTab() {
        windowController?.addTabToCurrentProject(isClaude: true)
    }

    @objc private func handleCloseTab() {
        windowController?.closeCurrentTab()
    }

    @objc private func showAbout() {
        SettingsWindowController.shared.showAboutPane()
    }

    // MARK: - Menu

    @MainActor private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Deckard", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: "")
        settingsItem.setShortcut(for: .settings)
        appMenu.addItem(settingsItem)
        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdatesItem.target = updaterController
        appMenu.addItem(checkForUpdatesItem)
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

        let yoloItem = NSMenuItem(title: "New Claude Yolo Tab", action: #selector(newClaudeYoloTab), keyEquivalent: "")
        yoloItem.setShortcut(for: .newClaudeYoloTab)
        fileMenu.addItem(yoloItem)

        let termItem = NSMenuItem(title: "New Terminal Tab", action: #selector(newTerminalTab), keyEquivalent: "")
        termItem.setShortcut(for: .newTerminalTab)
        fileMenu.addItem(termItem)

        fileMenu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(closeCurrentTab), keyEquivalent: "")
        closeItem.setShortcut(for: .closeTab)
        fileMenu.addItem(closeItem)

        let newFolderItem = NSMenuItem(title: "New Sidebar Folder", action: #selector(createNewSidebarFolder), keyEquivalent: "")
        newFolderItem.setShortcut(for: .newSidebarFolder)
        newFolderItem.target = self
        fileMenu.addItem(newFolderItem)

        let moveOutItem = NSMenuItem(title: "Move Out of Folder", action: #selector(moveCurrentProjectOutOfFolder), keyEquivalent: "")
        moveOutItem.setShortcut(for: .moveOutOfFolder)
        moveOutItem.target = self
        fileMenu.addItem(moveOutItem)

        let exploreSessionsItem = NSMenuItem(title: "Explore Sessions", action: #selector(exploreSessions), keyEquivalent: "")
        exploreSessionsItem.setShortcut(for: .exploreSessions)
        fileMenu.addItem(exploreSessionsItem)

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

        let nextProjectItem = NSMenuItem(title: "Next Project", action: #selector(selectNextProject), keyEquivalent: "")
        nextProjectItem.setShortcut(for: .nextProject)
        fileMenu.addItem(nextProjectItem)

        let prevProjectItem = NSMenuItem(title: "Previous Project", action: #selector(selectPrevProject), keyEquivalent: "")
        prevProjectItem.setShortcut(for: .previousProject)
        fileMenu.addItem(prevProjectItem)
        fileMenu.addItem(.separator())

        // Cmd+1-9, Cmd+0 for direct project access
        for i in 0..<tabShortcutNames.count {
            let displayNum = i + 1
            let item = NSMenuItem(title: "Project \(displayNum)", action: #selector(selectTabByNumber(_:)), keyEquivalent: "")
            item.tag = i
            item.setShortcut(for: tabShortcutNames[i])
            fileMenu.addItem(item)
        }

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu (system standard)
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

        // Window menu (system standard)
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

    @objc private func newClaudeYoloTab() {
        windowController?.addYoloTabToCurrentProject()
    }

    @objc private func newTerminalTab() {
        windowController?.addTabToCurrentProject(isClaude: false)
    }

    @objc private func closeCurrentTab() {
        if let keyWindow = NSApp.keyWindow,
           keyWindow != windowController?.window {
            keyWindow.performClose(nil)
            return
        }
        windowController?.closeCurrentTab()
    }

    @objc private func exploreSessions() {
        windowController?.exploreCurrentProjectSessions()
    }

    @objc private func moveCurrentProjectOutOfFolder() {
        windowController?.moveCurrentProjectOutOfFolder()
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

    @objc private func selectNextProject() {
        windowController?.selectNextProject()
    }

    @objc private func selectPrevProject() {
        windowController?.selectPrevProject()
    }

    @objc private func selectTabByNumber(_ sender: NSMenuItem) {
        windowController?.selectProject(byNumber: sender.tag)
    }

    @objc private func createNewSidebarFolder() {
        windowController?.createSidebarFolder()
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

            let marker = "gh issue create --repo gi11es/deckard"
            if let existing = try? String(contentsOfFile: skillPath, encoding: .utf8),
               !existing.contains(marker) {
                return
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

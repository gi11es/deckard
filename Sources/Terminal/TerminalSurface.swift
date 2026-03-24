import AppKit
import SwiftTerm

// MARK: - File Drag-and-Drop Terminal View

/// LocalProcessTerminalView subclass that accepts file drags from Finder
/// and pastes shell-escaped paths into the terminal.
private class DeckardTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return super.performDragOperation(sender)
        }

        let escaped = urls.map { Self.shellEscape($0.path) }
        send(txt: escaped.joined(separator: " "))
        return true
    }

    /// Escape a file path for safe pasting into a shell.
    private static func shellEscape(_ path: String) -> String {
        let special: Set<Character> = [" ", "'", "\"", "\\", "(", ")", "[", "]",
                                        "{", "}", "$", "`", "!", "&", "|", ";",
                                        "<", ">", "?", "*", "#", "~"]
        var result = ""
        for ch in path {
            if special.contains(ch) {
                result.append("\\")
            }
            result.append(ch)
        }
        return result
    }
}

/// Wraps a SwiftTerm LocalProcessTerminalView for use in Deckard's tab system.
/// This is the ONLY file that imports SwiftTerm — the rest of Deckard talks
/// to TerminalSurface through its public interface.
class TerminalSurface: NSObject, LocalProcessTerminalViewDelegate {
    let surfaceId: UUID
    var tabId: UUID?
    var title: String = ""
    var pwd: String?
    var isAlive: Bool { !processExited }
    var onProcessExit: ((TerminalSurface) -> Void)?
    /// The tmux session name, if this terminal is wrapped in tmux.
    var tmuxSessionName: String?

    private let terminalView: DeckardTerminalView
    private var processExited = false
    private var pendingInitialInput: String?

    // MARK: - tmux Detection

    /// Whether tmux is available on this system (cached).
    static let tmuxPath: String? = {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Search PATH
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let full = "\(dir)/tmux"
                if FileManager.default.isExecutableFile(atPath: full) { return full }
            }
        }
        return nil
    }()

    static var tmuxAvailable: Bool { tmuxPath != nil }

    /// The NSView to add to the view hierarchy.
    var view: NSView { terminalView }

    init(surfaceId: UUID = UUID()) {
        self.surfaceId = surfaceId
        self.terminalView = DeckardTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        terminalView.processDelegate = self
        // Apply current theme colors
        ThemeManager.shared.currentScheme.apply(to: terminalView)
        // Apply saved font and scrollback
        applySavedFont()
        applySavedScrollback()
        // Observe settings changes
        NotificationCenter.default.addObserver(self, selector: #selector(fontDidChange(_:)),
                                               name: .deckardFontChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollbackDidChange(_:)),
                                               name: .deckardScrollbackChanged, object: nil)
    }

    /// Apply a color scheme to this terminal.
    func applyColorScheme(_ scheme: TerminalColorScheme) {
        scheme.apply(to: terminalView)
    }

    /// Exit tmux copy mode if active. Call when switching back to this tab
    /// so arrow keys go to the shell instead of navigating the buffer.
    func exitTmuxCopyMode() {
        guard let name = tmuxSessionName, let path = Self.tmuxPath else { return }
        DispatchQueue.global(qos: .userInteractive).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = ["send-keys", "-t", name, "-X", "cancel"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            // Ignore errors — if not in copy mode, the command is a no-op
        }
    }

    /// Start a shell process in the terminal.
    /// - Parameter tmuxSession: If set, attach to this tmux session (resume). If nil and tmux is
    ///   available and no initialInput (not a Claude tab), create a new tmux session.
    func startShell(workingDirectory: String? = nil, command: String? = nil,
                    envVars: [String: String] = [:], initialInput: String? = nil,
                    tmuxSession: String? = nil) {
        let shell = command ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // Build environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        // Ensure UTF-8 locale for proper emoji/wide character handling in tmux
        if env["LANG"] == nil && env["LC_ALL"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        env["DECKARD_SURFACE_ID"] = surfaceId.uuidString
        if let tabId { env["DECKARD_TAB_ID"] = tabId.uuidString }
        env["DECKARD_SOCKET_PATH"] = ControlSocket.shared.path
        for (k, v) in envVars { env[k] = v }

        let envPairs = env.map { "\($0.key)=\($0.value)" }

        // Decide whether to use tmux:
        // - tmux must be available
        // - No initialInput (Claude tabs use their own resume mechanism)
        // - Either resuming an existing session or creating a new terminal tab
        let tmuxSettingEnabled = UserDefaults.standard.object(forKey: "useTmux") as? Bool ?? true
        let useTmux = Self.tmuxAvailable && tmuxSettingEnabled && initialInput == nil
        let tmuxPath = Self.tmuxPath ?? "tmux"

        if useTmux {
            let sessionName = tmuxSession ?? "deckard-\(surfaceId.uuidString.prefix(8))"
            self.tmuxSessionName = sessionName

            // tmux new-session -A: attach if exists, create if not
            // -s: session name, -c: starting directory (only for new sessions)
            // -u: force UTF-8 mode for proper emoji/wide character handling
            var args = ["-u", "new-session", "-A", "-s", sessionName]
            if let cwd = workingDirectory { args += ["-c", cwd] }

            terminalView.startProcess(
                executable: tmuxPath,
                args: args,
                environment: envPairs,
                currentDirectory: workingDirectory
            )

            // Hide the tmux status bar after attaching. The -f config only
            // applies on server start; this covers reattach to existing servers.
            let tmux = tmuxPath
            let session = sessionName
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
                let commands: [[String]] = [
                    ["set-option", "-t", session, "status", "off"],
                    ["set-option", "-t", session, "-g", "mouse", "on"],
                    ["set-option", "-t", session, "-g", "default-terminal", "xterm-256color"],
                    ["set-option", "-t", session, "-g", "allow-passthrough", "on"],
                    // Use OSC 52 to copy to system clipboard
                    ["set-option", "-t", session, "-s", "set-clipboard", "on"],
                    // Mouse drag end: copy to clipboard but KEEP selection visible.
                    // copy-pipe-no-clear copies without clearing the highlight.
                    // User sees the selection, can Cmd+C or click to dismiss.
                    ["bind-key", "-T", "copy-mode", "MouseDragEnd1Pane",
                     "send-keys", "-X", "copy-pipe-no-clear", "pbcopy"],
                    ["bind-key", "-T", "copy-mode-vi", "MouseDragEnd1Pane",
                     "send-keys", "-X", "copy-pipe-no-clear", "pbcopy"],
                ]
                for args in commands {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: tmux)
                    task.arguments = args
                    task.standardOutput = FileHandle.nullDevice
                    task.standardError = FileHandle.nullDevice
                    try? task.run()
                    task.waitUntilExit()
                }
            }
        } else {
            self.tmuxSessionName = nil
            terminalView.startProcess(
                executable: shell,
                args: ["-l"],
                environment: envPairs,
                execName: "-" + (shell as NSString).lastPathComponent,
                currentDirectory: workingDirectory
            )
        }

        // Register shell PID with ProcessMonitor.
        // For tmux sessions, the client PID isn't useful — query tmux for the
        // actual shell PID inside the session after it starts.
        let clientPid = terminalView.process.shellPid
        if useTmux, let sessionName = self.tmuxSessionName {
            let sid = surfaceId.uuidString
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if let shellPid = Self.tmuxSessionPid(sessionName: sessionName) {
                    ProcessMonitor.shared.registerShellPid(shellPid, forSurface: sid)
                    DiagnosticLog.shared.log("surface", "tmux shell pid: \(shellPid) for session \(sessionName)")
                }
            }
        } else if clientPid > 0 {
            ProcessMonitor.shared.registerShellPid(clientPid, forSurface: surfaceId.uuidString)
        }

        DiagnosticLog.shared.log("surface",
            "startShell: surfaceId=\(surfaceId) shell=\(shell) pid=\(clientPid) tmux=\(useTmux) cwd=\(workingDirectory ?? "(nil)")")

        // Send initial input after a short delay for shell readline to be ready
        if let initialInput {
            pendingInitialInput = initialInput
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let input = self.pendingInitialInput else { return }
                self.pendingInitialInput = nil
                self.sendInput(input)
            }
        }
    }

    /// Send text to the terminal (for initial input, paste, etc.)
    func sendInput(_ text: String) {
        terminalView.send(txt: text)
    }

    /// Terminate the shell process.
    /// When closing a tab, also kill the tmux session so it doesn't orphan.
    /// On app quit, call `detach()` instead to keep the session alive.
    func terminate() {
        guard !processExited else { return }
        processExited = true
        terminalView.process?.terminate()
        // Kill the tmux session when tab is explicitly closed
        killTmuxSession()
    }

    /// Detach from the tmux session without killing it (for app quit).
    func detach() {
        guard !processExited else { return }
        processExited = true
        // Just kill the local process — tmux session survives
        terminalView.process?.terminate()
    }

    private func killTmuxSession() {
        guard let name = tmuxSessionName, let path = Self.tmuxPath else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["kill-session", "-t", name]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    /// Get the shell PID running inside a tmux session.
    private static func tmuxSessionPid(sessionName: String) -> pid_t? {
        guard let path = tmuxPath else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["list-panes", "-t", sessionName, "-F", "#{pane_pid}"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let firstLine = output.split(separator: "\n").first, let pid = pid_t(firstLine) {
            return pid
        }
        return nil
    }

    /// Clean up orphaned deckard tmux sessions that aren't in the saved state.
    static func cleanupOrphanedTmuxSessions(activeSessions: Set<String>) {
        guard let path = tmuxPath else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["list-sessions", "-F", "#{session_name}"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") {
            let name = String(line)
            if name.hasPrefix("deckard-") && !activeSessions.contains(name) {
                let kill = Process()
                kill.executableURL = URL(fileURLWithPath: path)
                kill.arguments = ["kill-session", "-t", name]
                kill.standardOutput = FileHandle.nullDevice
                kill.standardError = FileHandle.nullDevice
                try? kill.run()
                kill.waitUntilExit()
                DiagnosticLog.shared.log("tmux", "cleaned up orphaned session: \(name)")
            }
        }
    }

    // MARK: - Font

    private func applySavedFont() {
        let name = UserDefaults.standard.string(forKey: "terminalFontName") ?? "SF Mono"
        let size = UserDefaults.standard.double(forKey: "terminalFontSize")
        let fontSize = size > 0 ? CGFloat(size) : 13.0
        if let font = NSFont(name: name, size: fontSize) {
            terminalView.font = font
        }
    }

    @objc private func fontDidChange(_ notification: Notification) {
        if let font = notification.userInfo?["font"] as? NSFont {
            terminalView.font = font
        }
    }

    // MARK: - Scrollback

    static let defaultScrollback = 10_000

    private func applySavedScrollback() {
        let saved = UserDefaults.standard.integer(forKey: "terminalScrollback")
        let scrollback = saved > 0 ? saved : Self.defaultScrollback
        terminalView.getTerminal().buffer.changeHistorySize(scrollback)
    }

    @objc private func scrollbackDidChange(_ notification: Notification) {
        if let lines = notification.userInfo?["lines"] as? Int {
            terminalView.getTerminal().buffer.changeHistorySize(lines)
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Size changes handled internally by SwiftTerm
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title
        NotificationCenter.default.post(
            name: .deckardSurfaceTitleChanged,
            object: nil,
            userInfo: ["surfaceId": surfaceId, "title": title]
        )
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        self.pwd = directory
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        processExited = true
        DiagnosticLog.shared.log("surface",
            "processTerminated: surfaceId=\(surfaceId) exitCode=\(exitCode ?? -1)")
        onProcessExit?(self)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let deckardSurfaceTitleChanged = Notification.Name("deckardSurfaceTitleChanged")
    static let deckardSurfaceClosed = Notification.Name("deckardSurfaceClosed")
    static let deckardNewTab = Notification.Name("deckardNewTab")
    static let deckardCloseTab = Notification.Name("deckardCloseTab")
    static let deckardFontChanged = Notification.Name("deckardFontChanged")
    static let deckardScrollbackChanged = Notification.Name("deckardScrollbackChanged")
}

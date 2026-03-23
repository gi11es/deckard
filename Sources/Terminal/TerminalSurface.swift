import AppKit
import SwiftTerm

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

    private let terminalView: LocalProcessTerminalView
    private var processExited = false
    private var pendingInitialInput: String?

    /// The NSView to add to the view hierarchy.
    var view: NSView { terminalView }

    init(surfaceId: UUID = UUID()) {
        self.surfaceId = surfaceId
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        terminalView.processDelegate = self
        // Apply current theme colors
        ThemeManager.shared.currentScheme.apply(to: terminalView)
    }

    /// Apply a color scheme to this terminal.
    func applyColorScheme(_ scheme: TerminalColorScheme) {
        scheme.apply(to: terminalView)
    }

    /// Start a shell process in the terminal.
    func startShell(workingDirectory: String? = nil, command: String? = nil,
                    envVars: [String: String] = [:], initialInput: String? = nil) {
        let shell = command ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // Build environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["DECKARD_SURFACE_ID"] = surfaceId.uuidString
        if let tabId { env["DECKARD_TAB_ID"] = tabId.uuidString }
        env["DECKARD_SOCKET_PATH"] = ControlSocket.shared.path
        for (k, v) in envVars { env[k] = v }

        let envPairs = env.map { "\($0.key)=\($0.value)" }

        terminalView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: envPairs,
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: workingDirectory
        )

        // Register shell PID with ProcessMonitor directly
        let pid = terminalView.process.shellPid
        if pid > 0 {
            ProcessMonitor.shared.registerShellPid(pid, forSurface: surfaceId.uuidString)
        }

        DiagnosticLog.shared.log("surface",
            "startShell: surfaceId=\(surfaceId) shell=\(shell) pid=\(pid) cwd=\(workingDirectory ?? "(nil)")")

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
    func terminate() {
        guard !processExited else { return }
        processExited = true
        terminalView.process?.terminate()
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
}

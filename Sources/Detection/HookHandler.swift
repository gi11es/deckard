import Foundation

/// Processes hook events from Claude Code and updates tab state accordingly.
class HookHandler {
    weak var windowController: DeckardWindowController?

    func handle(_ message: ControlMessage, reply: @escaping (ControlResponse) -> Void) {
        switch message.command {

        // --- Hook events from Claude Code ---

        case "hook.session-start":
            if let surfaceId = message.surfaceId {
                windowController?.updateBadge(forSurfaceId: surfaceId, state: .thinking)
                // Capture the real session ID from Claude Code
                if let sessionId = message.sessionId {
                    windowController?.updateSessionId(forSurfaceId: surfaceId, sessionId: sessionId)
                }
            }
            reply(ControlResponse(ok: true))

        case "hook.stop":
            // Claude finished responding — waiting for user input
            if let surfaceId = message.surfaceId {
                windowController?.updateBadge(forSurfaceId: surfaceId, state: .waitingForInput)
                // Notify if this tab is not focused
                notifyIfNotFocused(surfaceId: surfaceId, reason: .waitingForInput)
            }
            reply(ControlResponse(ok: true))

        case "hook.notification":
            if let surfaceId = message.surfaceId {
                let type = message.notificationType ?? ""
                if type.contains("permission") {
                    windowController?.updateBadge(forSurfaceId: surfaceId, state: .needsPermission)
                    notifyIfNotFocused(surfaceId: surfaceId, reason: .needsPermission)
                } else {
                    windowController?.updateBadge(forSurfaceId: surfaceId, state: .waitingForInput)
                    notifyIfNotFocused(surfaceId: surfaceId, reason: .waitingForInput)
                }
            }
            reply(ControlResponse(ok: true))

        case "hook.user-prompt-submit":
            // User typed something — Claude is thinking
            if let surfaceId = message.surfaceId {
                windowController?.updateBadge(forSurfaceId: surfaceId, state: .thinking)
            }
            reply(ControlResponse(ok: true))

        case "hook.pre-tool-use":
            // Tool starting — Claude is thinking/working
            if let surfaceId = message.surfaceId {
                windowController?.updateBadge(forSurfaceId: surfaceId, state: .thinking)
            }
            reply(ControlResponse(ok: true))

        // --- Query commands ---

        case "list-tabs":
            let tabs = windowController?.listTabInfo() ?? []
            reply(ControlResponse(ok: true, tabs: tabs))

        case "create-tab":
            let isClaude = message.value != "terminal"
            windowController?.createTab(
                claude: isClaude,
                workingDirectory: message.workingDirectory,
                name: message.name
            )
            reply(ControlResponse(ok: true))

        case "ping":
            reply(ControlResponse(ok: true, message: "pong"))

        default:
            reply(ControlResponse(ok: false, error: "unknown command: \(message.command)"))
        }
    }

    /// Send a macOS notification if the tab is not currently focused.
    private func notifyIfNotFocused(surfaceId: String, reason: TabItem.BadgeState) {
        guard let wc = windowController,
              let tab = wc.tabForSurfaceId(surfaceId),
              !wc.isTabFocused(surfaceId) else { return }

        NotificationManager.shared.notifyTabNeedsAttention(
            tabName: tab.name,
            reason: reason,
            tabId: tab.id
        )
    }
}

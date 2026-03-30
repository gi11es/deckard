import Foundation

/// Processes hook events from Claude Code and updates tab state accordingly.
class HookHandler {
    weak var windowController: DeckardWindowController?

    func handle(_ message: ControlMessage, reply: @escaping (ControlResponse) -> Void) {
        switch message.command {

        // --- Hook events from Claude Code ---

        case "hook.session-start":
            if let surfaceId = message.surfaceId {
                windowController?.updateBadge(forSurfaceId: surfaceId, state: .waitingForInput)
                windowController?.revealClaudeTab(surfaceId: surfaceId)
                // Capture the real session ID from Claude Code
                if let sessionId = message.sessionId {
                    windowController?.updateSessionId(forSurfaceId: surfaceId, sessionId: sessionId)
                }
            }
            forwardRateLimits(from: message)
            reply(ControlResponse(ok: true))

        case "hook.stop", "hook.stop-failure":
            // Claude finished responding — mark as unseen if tab isn't focused
            if let surfaceId = message.surfaceId {
                windowController?.updateBadgeToIdleOrUnseen(forSurfaceId: surfaceId, isClaude: true)
            }
            forwardRateLimits(from: message)
            reply(ControlResponse(ok: true))

        case "hook.notification":
            if let surfaceId = message.surfaceId {
                let type = message.notificationType ?? ""
                if type.contains("permission") {
                    windowController?.updateBadge(forSurfaceId: surfaceId, state: .needsPermission)
                } else {
                    windowController?.updateBadge(forSurfaceId: surfaceId, state: .waitingForInput)
                }
            }
            reply(ControlResponse(ok: true))

        case "hook.user-prompt-submit":
            // User typed something — Claude is thinking
            if let surfaceId = message.surfaceId {
                windowController?.updateBadge(forSurfaceId: surfaceId, state: .thinking)
            }
            forwardRateLimits(from: message)
            reply(ControlResponse(ok: true))

        case "hook.pre-tool-use":
            // Tool starting — Claude is thinking/working
            if let surfaceId = message.surfaceId {
                windowController?.updateBadge(forSurfaceId: surfaceId, state: .thinking)
            }
            forwardRateLimits(from: message)
            reply(ControlResponse(ok: true))

        case "hook.post-tool-use":
            forwardRateLimits(from: message)
            reply(ControlResponse(ok: true))

        // --- Process registration ---

        case "register-pid":
            if let surfaceId = message.surfaceId, let pid = message.pid {
                ProcessMonitor.shared.registerShellPid(pid, forSurface: surfaceId)
            }
            reply(ControlResponse(ok: true))

        // --- Query commands ---

        case "list-tabs":
            let tabs = windowController?.listTabInfo() ?? []
            reply(ControlResponse(ok: true, tabs: tabs))

        case "create-tab":
            if let dir = message.workingDirectory {
                windowController?.openProject(path: dir)
            }
            reply(ControlResponse(ok: true))

        case "rename-tab":
            if let tabId = message.tabId, let name = message.name {
                windowController?.renameTab(id: tabId, name: name)
            }
            reply(ControlResponse(ok: true))

        case "close-tab":
            if let tabId = message.tabId {
                windowController?.closeTabById(tabId)
            }
            reply(ControlResponse(ok: true))

        case "focus-tab":
            if let tabId = message.tabId {
                if let uuid = UUID(uuidString: tabId) {
                    windowController?.focusTabById(uuid)
                }
            }
            reply(ControlResponse(ok: true))

        // --- Quota update from StatusLine command ---

        case "quota-update":
            forwardRateLimits(from: message)
            reply(ControlResponse(ok: true))

        case "ping":
            reply(ControlResponse(ok: true, message: "pong"))

        default:
            reply(ControlResponse(ok: false, error: "unknown command: \(message.command)"))
        }
    }

    private func forwardRateLimits(from message: ControlMessage) {
        DiagnosticLog.shared.log("quota",
            "hook=\(message.command) 5h=\(message.fiveHourUsed.map { String($0) } ?? "nil") 7d=\(message.sevenDayUsed.map { String($0) } ?? "nil")")
        if message.fiveHourUsed != nil || message.sevenDayUsed != nil {
            QuotaMonitor.shared.update(
                fiveHourUsed: message.fiveHourUsed,
                fiveHourResetsAt: message.fiveHourResetsAt,
                sevenDayUsed: message.sevenDayUsed,
                sevenDayResetsAt: message.sevenDayResetsAt)
        }
    }

}

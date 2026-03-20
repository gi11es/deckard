import Foundation

/// Installs a static Claude Code hooks configuration so Deckard receives
/// session events (start, stop, notification, etc.) without needing a
/// wrapper script. The hook script reads $DECKARD_SURFACE_ID and
/// $DECKARD_SOCKET_PATH from the environment, so it's harmless when
/// claude runs outside of Deckard.
enum DeckardHooksInstaller {

    private static let hookScript = """
        #!/bin/sh
        # Deckard hook handler — routes Claude Code events to Deckard's control socket.
        # Exits silently when not running inside Deckard.
        [ -z "$DECKARD_SOCKET_PATH" ] && exit 0

        EVENT="$1"
        EXTRA=""

        # For session-start, walk parent PIDs to find the Claude session ID
        if [ "$EVENT" = "session-start" ]; then
            PID=$$
            CWD="$(pwd)"
            for _ in 1 2 3 4 5; do
                PID=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
                [ -z "$PID" ] || [ "$PID" = "1" ] && break
                SESSION_FILE="$HOME/.claude/sessions/${PID}.json"
                if [ -f "$SESSION_FILE" ]; then
                    FILE_CWD=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('cwd',''))" "$SESSION_FILE" 2>/dev/null)
                    if [ "$FILE_CWD" = "$CWD" ]; then
                        SID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['sessionId'])" "$SESSION_FILE" 2>/dev/null)
                        [ -n "$SID" ] && EXTRA=",\\"sessionId\\":\\"$SID\\"" && break
                    fi
                fi
            done
        fi

        printf '{"command":"hook.%s","surfaceId":"%s"%s}\\n' "$EVENT" "$DECKARD_SURFACE_ID" "$EXTRA" \\
          | nc -U "$DECKARD_SOCKET_PATH" -w 1 2>/dev/null
        """

    private static let hookScriptPath: String = {
        NSHomeDirectory() + "/.deckard/hooks/notify.sh"
    }()

    private static let settingsPath: String = {
        NSHomeDirectory() + "/.claude/settings.local.json"
    }()

    private static let hookEvents = [
        "SessionStart": "session-start",
        "Stop": "stop",
        "PreToolUse": "pre-tool-use",
        "Notification": "notification",
        "UserPromptSubmit": "user-prompt-submit",
    ]

    /// Install the hook script and merge hooks into Claude Code's settings.
    /// Idempotent — safe to call on every launch.
    static func installIfNeeded() {
        installHookScript()
        mergeHooksIntoSettings()
    }

    private static func installHookScript() {
        let dir = (hookScriptPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Always overwrite to keep the script up to date.
        try? hookScript.write(toFile: hookScriptPath, atomically: true, encoding: .utf8)

        // Make executable
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hookScriptPath)
    }

    private static func mergeHooksIntoSettings() {
        let fm = FileManager.default

        // Ensure ~/.claude/ exists
        let claudeDir = NSHomeDirectory() + "/.claude"
        if !fm.fileExists(atPath: claudeDir) {
            try? fm.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        }

        // Read existing settings (or start fresh)
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        // Build or merge hooks
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for (eventName, eventArg) in hookEvents {
            let command = "\(hookScriptPath) \(eventArg)"
            let deckardHook: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": 10,
            ]
            let deckardEntry: [String: Any] = [
                "matcher": "",
                "hooks": [deckardHook],
            ]

            var entries = hooks[eventName] as? [[String: Any]] ?? []

            // Check if Deckard's hook is already present
            let alreadyInstalled = entries.contains { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { hook in
                    (hook["command"] as? String)?.contains(".deckard/hooks/") == true
                }
            }

            if !alreadyInstalled {
                entries.append(deckardEntry)
            }

            hooks[eventName] = entries
        }

        settings["hooks"] = hooks

        // Write back
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
        }
    }
}

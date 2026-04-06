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
        INPUT=$(cat)
        EXTRA=""

        # For session-start, extract the session ID so Deckard can find the JSONL transcript.
        # Primary: read session_id from stdin JSON (works for both new and resumed sessions).
        # Fallback: walk parent PIDs to find ~/.claude/sessions/<pid>.json (original method,
        #           unreliable for resumed sessions but better than nothing if stdin is empty).
        if [ "$EVENT" = "session-start" ]; then
            SID=$(printf '%s' "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
            if [ -z "$SID" ]; then
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
                            break
                        fi
                    fi
                done
            fi
            [ -n "$SID" ] && EXTRA=",\\"sessionId\\":\\"$SID\\""
        fi

        printf '{"command":"hook.%s","surfaceId":"%s"%s}\\n' "$EVENT" "$DECKARD_SURFACE_ID" "$EXTRA" \\
          | nc -U "$DECKARD_SOCKET_PATH" -w 1 2>/dev/null
        """

    /// StatusLine script — receives the full /status JSON on stdin (which includes
    /// rate_limits), extracts the quota data, sends it to Deckard's control socket,
    /// then delegates to the user's original statusline command (if any).
    private static let statusLineScript = """
        #!/bin/sh
        # Deckard statusline wrapper — extracts quota data for Deckard,
        # then delegates to the user's original statusline command (if any).

        # Read stdin into a variable (the /status JSON from Claude Code)
        INPUT=$(cat)

        # --- Deckard quota extraction (silent no-op if Deckard isn't running) ---
        if [ -n "$DECKARD_SOCKET_PATH" ]; then
            _PY=$(mktemp)
            cat > "$_PY" << 'PYEOF'
        import json,sys,socket,os
        try:
            d=json.loads(sys.stdin.read());rl=d.get("rate_limits",{})
            fh=rl.get("five_hour",{});sd=rl.get("seven_day",{})
            if not fh and not sd: sys.exit(0)
            q=chr(34);p=[]
            if "used_percentage" in fh:p.append(q+"fiveHourUsed"+q+":"+str(fh["used_percentage"]))
            if "resets_at" in fh:p.append(q+"fiveHourResetsAt"+q+":"+str(fh["resets_at"]))
            if "used_percentage" in sd:p.append(q+"sevenDayUsed"+q+":"+str(sd["used_percentage"]))
            if "resets_at" in sd:p.append(q+"sevenDayResetsAt"+q+":"+str(sd["resets_at"]))
            if not p: sys.exit(0)
            msg="{"+q+"command"+q+":"+q+"quota-update"+q+","+",".join(p)+"}"
            sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
            sock.settimeout(1)
            sock.connect(os.environ["DECKARD_SOCKET_PATH"])
            sock.sendall((msg+"\\n").encode())
            sock.recv(256)
            sock.close()
        except:pass
        PYEOF
            printf '%s' "$INPUT" | python3 "$_PY"
            rm -f "$_PY"
        fi

        # --- Delegate to user's original statusline (if saved) ---
        ORIG_CFG="$HOME/.deckard/original-statusline.json"
        if [ -f "$ORIG_CFG" ]; then
            ORIG_CMD=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('command',''))" "$ORIG_CFG" 2>/dev/null)
            if [ -n "$ORIG_CMD" ]; then
                printf '%s' "$INPUT" | eval "$ORIG_CMD"
                exit $?
            fi
        fi
        """

    private static let hookScriptPath: String = {
        NSHomeDirectory() + "/.deckard/hooks/notify.sh"
    }()

    private static let statusLineScriptPath: String = {
        NSHomeDirectory() + "/.deckard/hooks/statusline.sh"
    }()

    private static let settingsPath: String = {
        NSHomeDirectory() + "/.claude/settings.json"
    }()

    private static let originalStatusLinePath: String = {
        NSHomeDirectory() + "/.deckard/original-statusline.json"
    }()

    private static let hooksDirPath: String = {
        NSHomeDirectory() + "/.deckard/hooks"
    }()

    private static let hookEvents: [(key: String, arg: String)] = [
        ("SessionStart", "session-start"),
        ("Stop", "stop"),
        ("StopFailure", "stop-failure"),
        ("PreToolUse", "pre-tool-use"),
        ("Notification", "notification"),
        ("UserPromptSubmit", "user-prompt-submit"),
    ]

    /// Install the hook script and merge hooks into Claude Code's settings.
    /// Idempotent — safe to call on every launch.
    static func installIfNeeded() {
        installHookScript()
        mergeHooksIntoSettings()
    }

    static func installHookScript(
        hookScriptPath: String? = nil,
        statusLineScriptPath: String? = nil
    ) {
        let effectiveHookPath = hookScriptPath ?? Self.hookScriptPath
        let effectiveStatusLinePath = statusLineScriptPath ?? Self.statusLineScriptPath

        let dir = (effectiveHookPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Also ensure statusline script dir exists (may differ from hook dir)
        let statusLineDir = (effectiveStatusLinePath as NSString).deletingLastPathComponent
        if statusLineDir != dir {
            try? FileManager.default.createDirectory(atPath: statusLineDir, withIntermediateDirectories: true)
        }

        // Always overwrite to keep the scripts up to date.
        for (script, path) in [(hookScript, effectiveHookPath), (statusLineScript, effectiveStatusLinePath)] {
            try? script.write(toFile: path, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    static func mergeHooksIntoSettings(settingsPath: String? = nil, originalStatusLinePath: String? = nil) {
        let effectiveSettingsPath = settingsPath ?? Self.settingsPath
        let effectiveOriginalPath = originalStatusLinePath ?? Self.originalStatusLinePath
        let fm = FileManager.default

        // Ensure ~/.claude/ exists
        let claudeDir = (effectiveSettingsPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: claudeDir) {
            try? fm.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        }

        // Read existing settings (or start fresh)
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: effectiveSettingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        // Build or merge hooks
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let scriptPath = hookScriptPath

        for (eventName, eventArg) in hookEvents {
            let command = "\(scriptPath) \(eventArg)"
            var entries = hooks[eventName] as? [[String: Any]] ?? []

            // Remove any existing Deckard hook (so we always update to latest)
            entries.removeAll { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { hook in
                    (hook["command"] as? String)?.contains(".deckard/hooks/") == true
                }
            }

            // Add our hook
            entries.append([
                "matcher": "",
                "hooks": [
                    [
                        "type": "command",
                        "command": command,
                        "timeout": 10,
                    ] as [String: Any],
                ],
            ] as [String: Any])

            hooks[eventName] = entries
        }

        settings["hooks"] = hooks

        // Save original statusLine if it's not ours
        if let statusLine = settings["statusLine"] as? [String: Any],
           let cmd = statusLine["command"] as? String,
           !cmd.contains(".deckard/hooks/") {
            saveOriginalStatusLine(statusLine, to: effectiveOriginalPath)
        }

        // Configure statusLine command to receive rate_limits from Claude Code.
        // The statusLine receives the full /status JSON on stdin (which includes
        // rate_limits) — unlike regular hooks which only get event-specific data.
        settings["statusLine"] = [
            "type": "command",
            "command": statusLineScriptPath,
        ] as [String: Any]

        // Write back — use .withoutEscapingSlashes to avoid \/ in paths
        if let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) {
            try? data.write(to: URL(fileURLWithPath: effectiveSettingsPath))
        }
    }

    /// Remove all Deckard hooks from Claude Code settings and restore the original statusLine.
    /// Parameters are injectable for testing.
    static func uninstall(
        settingsPath: String? = nil,
        originalStatusLinePath: String? = nil,
        hooksDirPath: String? = nil
    ) {
        let effectiveSettingsPath = settingsPath ?? Self.settingsPath
        let effectiveOriginalPath = originalStatusLinePath ?? Self.originalStatusLinePath
        let effectiveHooksDir = hooksDirPath ?? Self.hooksDirPath
        let fm = FileManager.default

        // Read current settings
        guard let data = fm.contents(atPath: effectiveSettingsPath),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Restore or remove statusLine
        if let origData = fm.contents(atPath: effectiveOriginalPath),
           let original = try? JSONSerialization.jsonObject(with: origData) as? [String: Any] {
            settings["statusLine"] = original
        } else {
            settings.removeValue(forKey: "statusLine")
        }

        // Remove Deckard hook entries from all events, preserving non-Deckard hooks
        if var hooks = settings["hooks"] as? [String: Any] {
            for (eventName, value) in hooks {
                guard var entries = value as? [[String: Any]] else { continue }
                entries.removeAll { entry in
                    guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                    return entryHooks.contains { hook in
                        (hook["command"] as? String)?.contains(".deckard/hooks/") == true
                    }
                }
                if entries.isEmpty {
                    hooks.removeValue(forKey: eventName)
                } else {
                    hooks[eventName] = entries
                }
            }
            if hooks.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = hooks
            }
        }

        // Write back
        if let writeData = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) {
            try? writeData.write(to: URL(fileURLWithPath: effectiveSettingsPath))
        }

        // Clean up hooks directory and saved original
        try? fm.removeItem(atPath: effectiveHooksDir)
        try? fm.removeItem(atPath: effectiveOriginalPath)
    }

    private static func saveOriginalStatusLine(_ config: [String: Any], to path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

import AppKit
import GhosttyKit

/// Wraps the ghostty_app_t singleton with runtime callbacks.
class DeckardGhosttyApp {
    static var instance: DeckardGhosttyApp?

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var defaultBackgroundColor: NSColor = .windowBackgroundColor
    private(set) var defaultForegroundColor: NSColor = .labelColor
    /// Coalesces rapid wakeup signals from libghostty's I/O thread into a single
    /// tick() call on the main thread, preventing main queue starvation during
    /// heavy terminal output.
    private let tickSource: DispatchSourceUserDataAdd = {
        let source = DispatchSource.makeUserDataAddSource(queue: .main)
        source.setEventHandler {
            DeckardGhosttyApp.instance?.tick()
        }
        source.resume()
        return source
    }()

    init() {
        Self.instance = self
        initializeGhostty()
    }

    deinit {
        if let app = app {
            ghostty_app_free(app)
        }
        if let config = config {
            ghostty_config_free(config)
        }
    }

    private func initializeGhostty() {
        // Create and load config
        guard let primaryConfig = ghostty_config_new() else {
            print("Failed to create ghostty config")
            return
        }
        ghostty_config_load_default_files(primaryConfig)
        ghostty_config_load_recursive_files(primaryConfig)

        // Load theme override (persisted from Settings → Appearance)
        let overridePath = ThemeManager.shared.overrideConfigPath
        if FileManager.default.fileExists(atPath: overridePath) {
            overridePath.withCString { ptr in
                ghostty_config_load_file(primaryConfig, ptr)
            }
        }

        ghostty_config_finalize(primaryConfig)

        // Extract colors from config
        updateDefaultBackground(from: primaryConfig)
        updateDefaultForeground(from: primaryConfig)

        // Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true

        runtimeConfig.wakeup_cb = { _ in
            DeckardGhosttyApp.instance?.tickSource.add(data: 1)
        }

        runtimeConfig.action_cb = { app, target, action in
            return DeckardGhosttyApp.instance?.handleAction(target: target, action: action) ?? false
        }

        runtimeConfig.read_clipboard_cb = { userdata, location, state -> Bool in
            guard let userdata, let state else { return false }
            let ctx = Unmanaged<SurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
            guard let view = ctx.view, let surface = view.surface else { return false }

            let pasteboard: NSPasteboard? = (location == GHOSTTY_CLIPBOARD_STANDARD) ? .general : nil
            guard let pasteboard else { return false }

            // Try text first
            var value = pasteboard.string(forType: .string) ?? ""

            // If no text, check for image data and save as temp file
            if value.isEmpty {
                if let imagePath = DeckardGhosttyApp.saveClipboardImage(from: pasteboard) {
                    value = imagePath
                }
            }

            value.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
            return true
        }

        runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let content, let userdata, let state else { return }
            let ctx = Unmanaged<SurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
            guard let view = ctx.view, let surface = view.surface else { return }
            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }

        runtimeConfig.write_clipboard_cb = { _, location, content, len, _ in
            guard let content, len > 0 else { return }
            guard location == GHOSTTY_CLIPBOARD_STANDARD else { return }

            let buffer = UnsafeBufferPointer(start: content, count: Int(len))
            var fallback: String?
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)
                if let mimePtr = item.mime {
                    let mime = String(cString: mimePtr)
                    if mime.hasPrefix("text/plain") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                        return
                    }
                }
                if fallback == nil {
                    fallback = value
                }
            }
            if let fallback {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fallback, forType: .string)
            }
        }

        runtimeConfig.close_surface_cb = { userdata, needsConfirmClose in
            DispatchQueue.main.async {
                guard let userdata else { return }
                let ctx = Unmanaged<SurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
                NotificationCenter.default.post(
                    name: .deckardSurfaceClosed,
                    object: nil,
                    userInfo: ["surfaceId": ctx.surfaceId]
                )
            }
        }

        // Create the app
        if let created = ghostty_app_new(&runtimeConfig, primaryConfig) {
            self.app = created
            self.config = primaryConfig
        } else {
            ghostty_config_free(primaryConfig)
            guard let fallbackConfig = ghostty_config_new() else {
                print("Failed to create ghostty fallback config")
                return
            }
            ghostty_config_finalize(fallbackConfig)

            guard let created = ghostty_app_new(&runtimeConfig, fallbackConfig) else {
                print("Failed to create ghostty app with fallback config")
                ghostty_config_free(fallbackConfig)
                return
            }
            self.app = created
            self.config = fallbackConfig
        }

        // Set initial focus state
        if let app = self.app {
            ghostty_app_set_focus(app, NSApp.isActive)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            DiagnosticLog.shared.log("focus", "app didBecomeActive")
            ghostty_app_set_focus(app, true)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            DiagnosticLog.shared.log("focus", "app didResignActive")
            ghostty_app_set_focus(app, false)
        }

        // Sleep/wake observers for diagnostics
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { _ in
            DiagnosticLog.shared.log("sleep", "system willSleep")
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in
            DiagnosticLog.shared.log("sleep", "system didWake")
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { _ in
            DiagnosticLog.shared.log("sleep", "screens didWake")
        }
    }

    func tick() {
        guard let app = self.app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Focused Surface

    /// Returns the ghostty_surface_t for the currently focused tab.
    /// Save clipboard image data to a temp PNG file and return the path.
    static func saveClipboardImage(from pasteboard: NSPasteboard) -> String? {
        // Check for image types
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        for type in imageTypes {
            if let data = pasteboard.data(forType: type) {
                guard let image = NSImage(data: data),
                      let tiffData = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmap.representation(using: .png, properties: [:]) else { continue }

                let tmpDir = NSTemporaryDirectory()
                let filename = "deckard-clipboard-\(UUID().uuidString.prefix(8)).png"
                let path = (tmpDir as NSString).appendingPathComponent(filename)
                do {
                    try pngData.write(to: URL(fileURLWithPath: path))
                    return path
                } catch {
                    return nil
                }
            }
        }

        // Also check if there are file URLs pointing to images
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"])
            let imageURLs = urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            if !imageURLs.isEmpty {
                return imageURLs.map { $0.path }.joined(separator: " ")
            }
        }

        return nil
    }

    func focusedSurface() -> ghostty_surface_t? {
        return AppDelegate.shared?.windowController?.focusedSurface()
    }

    // MARK: - Theme Colors

    private func updateDefaultBackground(from config: ghostty_config_t) {
        var color = ghostty_config_color_s()
        if ghostty_config_get(config, &color, "background", 10) {
            defaultBackgroundColor = NSColor(
                red: CGFloat(color.r) / 255.0,
                green: CGFloat(color.g) / 255.0,
                blue: CGFloat(color.b) / 255.0,
                alpha: 1.0
            )
        }
    }

    private func updateDefaultForeground(from config: ghostty_config_t) {
        var color = ghostty_config_color_s()
        if ghostty_config_get(config, &color, "foreground", 10) {
            defaultForegroundColor = NSColor(
                red: CGFloat(color.r) / 255.0,
                green: CGFloat(color.g) / 255.0,
                blue: CGFloat(color.b) / 255.0,
                alpha: 1.0
            )
        }
    }

    /// Reloads the Ghostty config with the current theme override applied.
    func reloadConfigWithTheme() {
        guard let app = self.app else { return }

        guard let newConfig = ghostty_config_new() else { return }
        ghostty_config_load_default_files(newConfig)
        ghostty_config_load_recursive_files(newConfig)

        let overridePath = ThemeManager.shared.overrideConfigPath
        if FileManager.default.fileExists(atPath: overridePath) {
            overridePath.withCString { ptr in
                ghostty_config_load_file(newConfig, ptr)
            }
        }

        ghostty_config_finalize(newConfig)

        // Read colors on main thread (safe, just reads config values)
        updateDefaultBackground(from: newConfig)
        updateDefaultForeground(from: newConfig)

        // Collect surface pointers on main thread (must access UI state on main)
        var surfaces: [ghostty_surface_t] = []
        if let wc = AppDelegate.shared?.windowController {
            wc.forEachSurface { surfaces.append($0) }
        }

        // Swap config reference immediately so new surfaces use the new config
        let oldConfig = self.config
        self.config = newConfig

        // Apply config updates on a background queue to avoid deadlocking
        // with libghostty's renderer/IO thread locks (same pattern as issue #5).
        DispatchQueue.global(qos: .userInitiated).async {
            ghostty_app_update_config(app, newConfig)
            for surface in surfaces {
                ghostty_surface_update_config(surface, newConfig)
            }
            if let oldConfig { ghostty_config_free(oldConfig) }
        }
    }

    // MARK: - Action Handling

    func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if target.tag == GHOSTTY_TARGET_SURFACE {
                let surface = target.target.surface
                if let titlePtr = action.action.set_title.title {
                    let title = String(cString: titlePtr)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .deckardSurfaceTitleChanged,
                            object: nil,
                            userInfo: ["surface": surface as Any, "title": title]
                        )
                    }
                }
            }
            return true

        case GHOSTTY_ACTION_PWD:
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            DispatchQueue.main.async {
                switch shape {
                case GHOSTTY_MOUSE_SHAPE_POINTER:
                    NSCursor.pointingHand.set()
                case GHOSTTY_MOUSE_SHAPE_TEXT:
                    NSCursor.iBeam.set()
                case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
                    NSCursor.crosshair.set()
                case GHOSTTY_MOUSE_SHAPE_GRAB:
                    NSCursor.openHand.set()
                case GHOSTTY_MOUSE_SHAPE_GRABBING:
                    NSCursor.closedHand.set()
                case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
                    NSCursor.operationNotAllowed.set()
                case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
                    NSCursor.resizeLeftRight.set()
                case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
                    NSCursor.resizeUpDown.set()
                default:
                    NSCursor.arrow.set()
                }
            }
            return true

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let link = action.action.mouse_over_link
            if link.len > 0, let urlPtr = link.url {
                let data = Data(bytes: urlPtr, count: Int(link.len))
                if let url = String(data: data, encoding: .utf8) {
                    DiagnosticLog.shared.log("link", "MOUSE_OVER_LINK: \(url)")
                }
            }
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let visibility = action.action.mouse_visibility
            DispatchQueue.main.async {
                NSCursor.setHiddenUntilMouseMoves(visibility == GHOSTTY_MOUSE_HIDDEN)
            }
            return true

        case GHOSTTY_ACTION_RENDERER_HEALTH,
             GHOSTTY_ACTION_CELL_SIZE,
             GHOSTTY_ACTION_RENDER,
             GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_CONFIG_CHANGE,
             GHOSTTY_ACTION_RELOAD_CONFIG,
             GHOSTTY_ACTION_SHOW_CHILD_EXITED,
             GHOSTTY_ACTION_SCROLLBAR,
             GHOSTTY_ACTION_SIZE_LIMIT,
             GHOSTTY_ACTION_INITIAL_SIZE,
             GHOSTTY_ACTION_KEY_SEQUENCE,
             GHOSTTY_ACTION_COMMAND_FINISHED,
             GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            return true

        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let openUrl = action.action.open_url
            if let urlPtr = openUrl.url {
                // Use explicit length (matching Ghostty) instead of cString
                // to avoid reading past the buffer if not null-terminated.
                let data = Data(bytes: urlPtr, count: Int(openUrl.len))
                guard let urlString = String(data: data, encoding: .utf8), !urlString.isEmpty else {
                    return true
                }
                DiagnosticLog.shared.log("link", "OPEN_URL: \(urlString)")

                // If the URL has a valid scheme, use it directly. Otherwise treat
                // it as a file path (matching Ghostty's handling).
                let url: URL
                if let candidate = URL(string: urlString), candidate.scheme != nil {
                    url = candidate
                } else {
                    let expanded = NSString(string: urlString).standardizingPath
                    url = URL(filePath: expanded)
                }

                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url)
                }
            }
            return true

        case GHOSTTY_ACTION_NEW_TAB:
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .deckardNewTab, object: nil)
            }
            return true

        case GHOSTTY_ACTION_CLOSE_TAB:
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .deckardCloseTab, object: nil)
            }
            return true

        default:
            return false
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let deckardSurfaceClosed = Notification.Name("deckardSurfaceClosed")
    static let deckardSurfaceTitleChanged = Notification.Name("deckardSurfaceTitleChanged")
    static let deckardNewTab = Notification.Name("deckardNewTab")
    static let deckardCloseTab = Notification.Name("deckardCloseTab")
}

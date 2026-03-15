import AppKit
import GhosttyKit

/// Callback context stored as the surface's userdata.
/// Lets us route callbacks back to the right tab/surface.
final class SurfaceCallbackContext {
    weak var view: TerminalNSView?
    let surfaceId: UUID
    var tabId: UUID

    init(view: TerminalNSView, surfaceId: UUID, tabId: UUID) {
        self.view = view
        self.surfaceId = surfaceId
        self.tabId = tabId
    }
}

/// The NSView that hosts a single libghostty terminal surface.
/// This view is passed to ghostty which sets up Metal rendering on it.
class TerminalNSView: NSView {
    let surfaceId: UUID
    var tabId: UUID?

    private(set) var surface: ghostty_surface_t?
    private var callbackContext: Unmanaged<SurfaceCallbackContext>?
    private var eventMonitor: Any?
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?

    var title: String = ""
    var pwd: String?

    override var acceptsFirstResponder: Bool { true }

    init(surfaceId: UUID = UUID()) {
        self.surfaceId = surfaceId
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        wantsLayer = true
        layer?.masksToBounds = true

        // Listen for key-up events that may not reach us through the normal responder chain
        // (e.g., Cmd+key combos where keyUp goes to the window).
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            self?.keyUp(with: event)
            return event
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        callbackContext?.release()
    }

    // MARK: - Surface Lifecycle

    func createSurface(app: ghostty_app_t, tabId: UUID, workingDirectory: String? = nil, command: String? = nil, envVars: [String: String] = [:]) {
        self.tabId = tabId

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))

        let ctx = SurfaceCallbackContext(view: self, surfaceId: surfaceId, tabId: tabId)
        let unmanagedCtx = Unmanaged.passRetained(ctx)
        surfaceConfig.userdata = unmanagedCtx.toOpaque()
        callbackContext?.release()
        callbackContext = unmanagedCtx

        surfaceConfig.scale_factor = Double(window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_TAB

        // Build environment variables
        var allEnvVars = envVars
        allEnvVars["DECKARD_SURFACE_ID"] = surfaceId.uuidString
        allEnvVars["DECKARD_TAB_ID"] = tabId.uuidString

        // Prepend our bin/ directory to PATH so our claude wrapper is found first.
        if let binPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
            if !currentPath.split(separator: ":").contains(Substring(binPath)) {
                allEnvVars["PATH"] = "\(binPath):\(currentPath)"
            }
        }

        // Convert env vars to C representation
        var cEnvVars: [ghostty_env_var_s] = []
        var cEnvStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []

        for (key, value) in allEnvVars {
            guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
            cEnvStorage.append((keyPtr, valuePtr))
            cEnvVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
        }

        let envCount = cEnvVars.count
        let createSurfaceCall = { [self] in
            if !cEnvVars.isEmpty {
                cEnvVars.withUnsafeMutableBufferPointer { buffer in
                    surfaceConfig.env_vars = buffer.baseAddress
                    surfaceConfig.env_var_count = envCount
                    self.surface = ghostty_surface_new(app, &surfaceConfig)
                }
            } else {
                self.surface = ghostty_surface_new(app, &surfaceConfig)
            }
        }

        // Set working directory and command if provided
        if let workingDirectory, !workingDirectory.isEmpty {
            workingDirectory.withCString { cwd in
                surfaceConfig.working_directory = cwd
                if let command, !command.isEmpty {
                    command.withCString { cmd in
                        surfaceConfig.command = cmd
                        createSurfaceCall()
                    }
                } else {
                    createSurfaceCall()
                }
            }
        } else if let command, !command.isEmpty {
            command.withCString { cmd in
                surfaceConfig.command = cmd
                createSurfaceCall()
            }
        } else {
            createSurfaceCall()
        }

        // Clean up C strings
        for (key, value) in cEnvStorage {
            free(key)
            free(value)
        }

        if surface == nil {
            callbackContext?.release()
            callbackContext = nil
            print("Failed to create ghostty surface for tab \(tabId)")
        }

        updateTrackingAreas()
        registerForDraggedTypes([.string, .fileURL])
    }

    func destroySurface() {
        if let surface = self.surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
        callbackContext?.release()
        callbackContext = nil
    }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        updateSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface = self.surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(surface, scale, scale)
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface = self.surface else { return }
        let scaledSize = convertToBacking(bounds.size)
        guard scaledSize.width > 0 && scaledSize.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            surface.map { ghostty_surface_set_focus($0, true) }
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            surface.map { ghostty_surface_set_focus($0, false) }
        }
        return result
    }

    // MARK: - Mouse Events

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let mods = Self.ghosttyMods(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let mods = Self.ghosttyMods(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let mods = Self.ghosttyMods(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let mods = Self.ghosttyMods(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = Self.ghosttyMods(from: event)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, mods)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = Self.ghosttyMods(from: event)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, mods)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = self.surface else { return }
        var mods: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas {
            mods |= 1 // precision bit
        }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, mods)
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        guard let surface = self.surface else { return }

        let mods = Self.ghosttyMods(from: event)

        // Build the key input. We pass the text from the event for character translation.
        var input = ghostty_input_key_s()
        input.action = GHOSTTY_ACTION_PRESS
        input.mods = mods
        input.keycode = UInt32(event.keyCode)
        input.composing = false

        // Set text from the event characters for key translation
        if let characters = event.characters, !characters.isEmpty {
            characters.withCString { ptr in
                input.text = ptr
                let codepoints = characters.unicodeScalars
                if let first = codepoints.first {
                    input.unshifted_codepoint = first.value
                }
                _ = ghostty_surface_key(surface, input)
            }
        } else {
            _ = ghostty_surface_key(surface, input)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let mods = Self.ghosttyMods(from: event)

        var input = ghostty_input_key_s()
        input.action = GHOSTTY_ACTION_RELEASE
        input.mods = mods
        input.keycode = UInt32(event.keyCode)
        _ = ghostty_surface_key(surface, input)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let mods = Self.ghosttyMods(from: event)

        var input = ghostty_input_key_s()
        input.action = GHOSTTY_ACTION_PRESS
        input.mods = mods
        input.keycode = UInt32(event.keyCode)
        _ = ghostty_surface_key(surface, input)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let surface = self.surface else { return false }
        let mods = Self.ghosttyMods(from: event)

        var input = ghostty_input_key_s()
        input.action = GHOSTTY_ACTION_PRESS
        input.mods = mods
        input.keycode = UInt32(event.keyCode)

        var flags: ghostty_binding_flags_e = ghostty_binding_flags_e(rawValue: 0)
        if ghostty_surface_key_is_binding(surface, input, &flags) {
            return ghostty_surface_key(surface, input)
        }

        return false
    }

    // MARK: - Text Input

    func insertText(_ string: String) {
        keyTextAccumulator?.append(string)
    }

    // MARK: - Drag and Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let surface = self.surface else { return false }
        let pasteboard = sender.draggingPasteboard

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let text = urls.map { $0.isFileURL ? shellEscape($0.path) : $0.absoluteString }.joined(separator: " ")
            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
            }
            return true
        }

        if let text = pasteboard.string(forType: .string) {
            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
            }
            return true
        }

        return false
    }

    // MARK: - Reading Terminal Content

    /// Read the visible terminal content (for input detection / tab naming).
    func readVisibleContent() -> String? {
        guard let surface = self.surface else { return nil }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0, y: 0),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    // MARK: - Helpers

    private func shellEscape(_ value: String) -> String {
        let special = "\\ ()[]{}<>\"'`!#$&;|*?\t"
        var result = value
        for char in special {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    /// Convert NSEvent modifier flags to Ghostty modifier flags.
    static func ghosttyMods(from event: NSEvent) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SHIFT.rawValue) }
        if flags.contains(.control) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_CTRL.rawValue) }
        if flags.contains(.option) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_ALT.rawValue) }
        if flags.contains(.command) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SUPER.rawValue) }
        if flags.contains(.capsLock) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_CAPS.rawValue) }
        return mods
    }

    /// Convert NSEvent keyCode to Ghostty key enum.
    /// Note: ghostty uses the keycode directly (not a translated key), so we just pass keyCode.
    static func ghosttyKey(from event: NSEvent) -> ghostty_input_key_e {
        // libghostty handles keycode-to-key translation internally
        return GHOSTTY_KEY_UNIDENTIFIED
    }
}
